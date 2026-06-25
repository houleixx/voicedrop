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
  4  → deterministic ASR failure (ASR_FAIL_EXIT): Volcano returned a business
       error code for THIS audio — re-running gets the same code, so the caller
       should mark it processed and stop retrying. The code is written to
       <out.json> as {"asr_error_code": "..."} so the miner can record it.
  1  → other / transient failure (network, timeout) — safe to retry

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
"""
import sys, os, json, uuid, time
import boto3
from botocore.config import Config
import requests

APPID  = os.environ.get("VOLC_ASR_APPID") or os.environ["VOLC_APPID"]
TOKEN  = os.environ.get("VOLC_ASR_ACCESS_TOKEN") or os.environ["VOLC_TOKEN"]
R2_ACCOUNT_ID        = os.environ["R2_ACCOUNT_ID"]
R2_ACCESS_KEY_ID     = os.environ["R2_ACCESS_KEY_ID"]
R2_SECRET_ACCESS_KEY = os.environ["R2_SECRET_ACCESS_KEY"]
R2_BUCKET = os.environ.get("R2_BUCKET", "jianshuo-dev-files")

SUBMIT_URL   = "https://openspeech.bytedance.com/api/v3/auc/bigmodel/submit"
QUERY_URL    = "https://openspeech.bytedance.com/api/v3/auc/bigmodel/query"
EMPTY_ASR_EXIT = 3
ASR_FAIL_EXIT  = 4   # deterministic ASR business error → don't retry

STATUS_DONE       = 20000000
STATUS_QUEUED     = 20000001
STATUS_PROCESSING = 20000002


class AsrFail(Exception):
    """Volcano returned a deterministic business error for this audio — re-running
    yields the same code. Carries the code so the miner can stop retrying."""
    def __init__(self, code):
        super().__init__(f"deterministic ASR failure: {code}")
        self.code = str(code)


def presign(key, expires=3600):
    s3 = boto3.client(
        "s3",
        endpoint_url=f"https://{R2_ACCOUNT_ID}.r2.cloudflarestorage.com",
        aws_access_key_id=R2_ACCESS_KEY_ID,
        aws_secret_access_key=R2_SECRET_ACCESS_KEY,
        config=Config(signature_version="s3v4"),
        region_name="auto",
    )
    return s3.generate_presigned_url(
        "get_object",
        Params={"Bucket": R2_BUCKET, "Key": key},
        ExpiresIn=expires,
    )


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
    r = requests.post(SUBMIT_URL, json=body, headers=hdrs, timeout=30)
    r.raise_for_status()
    status_code = r.headers.get("X-Api-Status-Code", "")
    if status_code != str(STATUS_DONE):
        print(f"Submit: HTTP {r.status_code} status={status_code} body={r.text[:200]}",
              file=sys.stderr)
        raise AsrFail(status_code or f"submit-http-{r.status_code}")
    logid = r.headers.get("X-Tt-Logid", "")
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
        r = requests.post(QUERY_URL, json={"task_id": task_id},
                          headers=hdrs, timeout=30)
        r.raise_for_status()
        status = r.headers.get("X-Api-Status-Code", "")
        res = json.loads(r.text) if r.text.strip() else {}
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
        # This is deterministic for the audio (same code on every re-run).
        if status and status not in (str(STATUS_QUEUED), str(STATUS_PROCESSING)):
            print(f"ASR error status={status} body={r.text[:200]}", file=sys.stderr)
            raise AsrFail(status)
        time.sleep(2)
    print("ASR timed out", file=sys.stderr)
    sys.exit(1)


def main():
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <r2-key> <out.json>", file=sys.stderr)
        sys.exit(1)

    key, out_path = sys.argv[1], sys.argv[2]

    url = presign(key)
    try:
        task_id, logid = submit(url)
        res = poll(task_id, logid, time.time() + 600)
    except AsrFail as e:
        # Deterministic failure: hand the code back to the miner so it can mark
        # the recording processed (no-retry) instead of failing forever.
        try:
            with open(out_path, "w", encoding="utf-8") as f:
                json.dump({"asr_error_code": e.code}, f)
        except Exception:
            pass
        print(f"ASR deterministic failure code={e.code}", file=sys.stderr)
        sys.exit(ASR_FAIL_EXIT)

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
