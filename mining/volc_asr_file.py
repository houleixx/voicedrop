#!/usr/bin/env python3
"""火山引擎 大模型录音文件识别 (bigmodel file ASR).

Takes an R2 object key, generates a presigned URL, submits to the async file
recognition API, polls until done, and writes the result JSON to an output file.

Protocol notes (different from what the docs describe):
- submit body: audio URL + format; success = HTTP 200 with X-Api-Status-Code:
  20000000 in HEADERS and {} in body (no task_id in body!)
- task_id is the X-Api-Request-Id UUID WE sent; use it for all subsequent polls
- poll body: {"task_id": <our-uuid>}; result comes back in body JSON once done
- {} in poll response means still queued/processing

Same exit-code contract as the old volc_asr_stream.py:
  0  → success, result written to <out.json>
  3  → empty / silent audio (EMPTY_ASR_EXIT)
  1  → other failure

Usage:
  volc_asr_file.py <r2-key> <out.json>

Credentials (env):
  VOLC_ASR_APPID / VOLC_APPID
  VOLC_ASR_ACCESS_TOKEN / VOLC_TOKEN
  R2_ACCOUNT_ID
  R2_ACCESS_KEY_ID
  R2_SECRET_ACCESS_KEY

Optional:
  R2_BUCKET  (default: jianshuo-dev-files)

No third-party deps: the R2 presign is a hand-rolled AWS SigV4 query signature
and the HTTP calls go through urllib — so CI needs no boto3/requests install.
"""
import sys, os, json, uuid, time, hmac, hashlib, datetime
import urllib.request, urllib.error, urllib.parse

APPID  = os.environ.get("VOLC_ASR_APPID") or os.environ["VOLC_APPID"]
TOKEN  = os.environ.get("VOLC_ASR_ACCESS_TOKEN") or os.environ["VOLC_TOKEN"]
R2_ACCOUNT_ID        = os.environ["R2_ACCOUNT_ID"]
R2_ACCESS_KEY_ID     = os.environ["R2_ACCESS_KEY_ID"]
R2_SECRET_ACCESS_KEY = os.environ["R2_SECRET_ACCESS_KEY"]
R2_BUCKET = os.environ.get("R2_BUCKET", "jianshuo-dev-files")

SUBMIT_URL   = "https://openspeech.bytedance.com/api/v3/auc/bigmodel/submit"
QUERY_URL    = "https://openspeech.bytedance.com/api/v3/auc/bigmodel/query"
EMPTY_ASR_EXIT = 3

STATUS_DONE       = 20000000
STATUS_QUEUED     = 20000001
STATUS_PROCESSING = 20000002


def _sign(key, msg):
    return hmac.new(key, msg.encode("utf-8"), hashlib.sha256).digest()


def presign(key, expires=3600):
    """Hand-rolled AWS SigV4 presigned GET URL for an R2 (path-style) object.
    Equivalent to boto3 generate_presigned_url('get_object', ...)."""
    host    = f"{R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
    region  = "auto"
    service = "s3"
    now = datetime.datetime.now(datetime.timezone.utc)
    amz_date  = now.strftime("%Y%m%dT%H%M%SZ")
    datestamp = now.strftime("%Y%m%d")

    # path-style: host has no bucket, the path carries bucket + key
    canonical_uri = "/" + R2_BUCKET + "/" + urllib.parse.quote(key, safe="/")
    credential_scope = f"{datestamp}/{region}/{service}/aws4_request"

    query = {
        "X-Amz-Algorithm":     "AWS4-HMAC-SHA256",
        "X-Amz-Credential":    f"{R2_ACCESS_KEY_ID}/{credential_scope}",
        "X-Amz-Date":          amz_date,
        "X-Amz-Expires":       str(expires),
        "X-Amz-SignedHeaders": "host",
    }
    canonical_qs = "&".join(
        f"{urllib.parse.quote(k, safe='')}={urllib.parse.quote(v, safe='')}"
        for k, v in sorted(query.items())
    )
    canonical_request = "\n".join([
        "GET", canonical_uri, canonical_qs,
        f"host:{host}\n", "host", "UNSIGNED-PAYLOAD",
    ])
    string_to_sign = "\n".join([
        "AWS4-HMAC-SHA256", amz_date, credential_scope,
        hashlib.sha256(canonical_request.encode("utf-8")).hexdigest(),
    ])
    k_date    = _sign(("AWS4" + R2_SECRET_ACCESS_KEY).encode("utf-8"), datestamp)
    k_region  = _sign(k_date, region)
    k_service = _sign(k_region, service)
    k_signing = _sign(k_service, "aws4_request")
    signature = hmac.new(k_signing, string_to_sign.encode("utf-8"),
                         hashlib.sha256).hexdigest()
    return f"https://{host}{canonical_uri}?{canonical_qs}&X-Amz-Signature={signature}"


def _post(url, body, headers):
    """POST JSON via urllib; returns (http_status, response_headers, text).
    Never raises on 4xx/5xx — the body/headers carry the API's own status."""
    data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers=headers, method="POST")
    try:
        resp = urllib.request.urlopen(req, timeout=30)
        return resp.status, resp.headers, resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.headers, e.read().decode("utf-8", "replace")


def submit(audio_url):
    """Submit an audio URL for recognition.
    Returns (task_id, logid): task_id is the request UUID we sent."""
    task_id = str(uuid.uuid4())
    hdrs = {
        "X-Api-App-Key":     APPID,
        "X-Api-Access-Key":  TOKEN,
        "X-Api-Resource-Id": "volc.bigasr.auc",
        "X-Api-Request-Id":  task_id,
        "X-Api-Sequence":    "-1",
        "Content-Type":      "application/json",
    }
    body = {
        "user":    {"uid": "wjs-asr"},
        "audio":   {"format": "m4a", "url": audio_url, "codec": "raw"},
        "request": {
            "model_name":      "bigmodel",
            "enable_itn":      True,
            "enable_punc":     True,
            "show_utterances": True,
        },
    }
    http_status, resp_headers, text = _post(SUBMIT_URL, body, hdrs)
    status_code = resp_headers.get("X-Api-Status-Code", "")
    if status_code != str(STATUS_DONE):
        print(f"Submit: HTTP {http_status} status={status_code} body={text[:200]}",
              file=sys.stderr)
        sys.exit(1)
    logid = resp_headers.get("X-Tt-Logid", "")
    print(f"[asr] submitted task={task_id[:8]}…", file=sys.stderr)
    return task_id, logid


def poll(task_id, logid, deadline):
    """Poll until the task finishes; returns the full response dict."""
    hdrs = {
        "X-Api-App-Key":     APPID,
        "X-Api-Access-Key":  TOKEN,
        "X-Api-Resource-Id": "volc.bigasr.auc",
        "X-Api-Request-Id":  task_id,
        "X-Tt-Logid":        logid,
        "X-Api-Sequence":    "-1",
        "Content-Type":      "application/json",
    }
    while time.time() < deadline:
        http_status, resp_headers, text = _post(QUERY_URL, {"task_id": task_id}, hdrs)
        status = resp_headers.get("X-Api-Status-Code", "")
        res = json.loads(text) if text.strip() else {}
        # Done detection (observed body shapes, captured from live runs):
        #   processing → {"audio_info":{}, "result":{"text":""}}   (empty audio_info)
        #   done       → {"audio_info":{"duration":N}, "result":{...}}
        # The body carries NO `code` field, so we key off audio_info being
        # populated — this fires even for SILENT clips (which finish with empty
        # text). Relying on result.text hangs forever on silent audio.
        if (status == str(STATUS_DONE)
                or res.get("audio_info", {})
                or res.get("result", {}).get("text", "").strip()):
            return res
        # Hard error: status header present and not a known in-progress code.
        if status and status not in (str(STATUS_QUEUED), str(STATUS_PROCESSING)):
            print(f"ASR error status={status} body={text[:200]}", file=sys.stderr)
            sys.exit(1)
        time.sleep(2)
    print("ASR timed out", file=sys.stderr)
    sys.exit(1)


def main():
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <r2-key> <out.json>", file=sys.stderr)
        sys.exit(1)

    key, out_path = sys.argv[1], sys.argv[2]

    url = presign(key)
    task_id, logid = submit(url)
    res = poll(task_id, logid, time.time() + 600)

    result = res.get("result", {})
    utts = result.get("utterances", [])
    text = result.get("text", "") or "".join(u.get("text", "") for u in utts)

    if not text.strip():
        sys.exit(EMPTY_ASR_EXIT)

    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(res, f, ensure_ascii=False)
    sys.exit(0)


if __name__ == "__main__":
    main()
