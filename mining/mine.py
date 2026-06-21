#!/usr/bin/env python3
"""VoiceDrop server-side miner (v2).

For every VoiceDrop-*.m4a in R2 (jianshuo.dev/files) that has no matching
article yet:  download -> Volcano ASR (-> SRT) -> Claude (owner voice, split
into 1+ standalone articles) -> write the result JSON back under the user's
own prefix at  <prefix>/articles/<stem>.json  (+ a <stem>.srt sidecar) so the
app can pull it. No WeChat. Idempotent: audio that already has an article JSON
is skipped, so re-runs are safe and cheap.

Output JSON schema (v2):
  { "id", "sourceAudio", "createdAt", "transcript", "srt",
    "articles": [ {"title", "body"}, ... ], "status": "ready", "model",
    "schema": 2 }

Env:
  FILES_TOKEN            master/admin token for jianshuo.dev/files
  CLAUDE_API_KEY         Anthropic API key (ANTHROPIC_API_KEY also accepted)
  VOLC_ASR_APPID         huo shan ASR app id
  VOLC_ASR_ACCESS_TOKEN  huo shan ASR access token
  MINE_MODEL             optional, default claude-sonnet-4-6
  MINE_DRY               if set, list what WOULD be mined and exit (no ASR/LLM)
"""
import os, re, sys, json, time, subprocess, tempfile, urllib.request
from urllib.parse import quote


def log(msg):
    """Wall-clock-stamped progress line, flushed so CI logs stream live."""
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)

BASE = "https://jianshuo.dev/files/api"
TOKEN = os.environ["FILES_TOKEN"]
CLAUDE_KEY = os.environ.get("CLAUDE_API_KEY") or os.environ.get("ANTHROPIC_API_KEY", "")
MODEL = os.environ.get("MINE_MODEL", "claude-sonnet-4-6")
DRY = bool(os.environ.get("MINE_DRY"))
# Transcripts shorter than this are noise (a 1–2s tap, a cough): too thin to
# become an article without fabrication, and the model replies with prose
# instead of JSON when fed them. Guard before the LLM so they're marked empty
# (not retried forever). Env-overridable.
MIN_CHARS = int(os.environ.get("MINE_MIN_CHARS", "20"))
HERE = os.path.dirname(os.path.abspath(__file__))

# Balanced split: 1+ standalone articles, one per *clearly distinct* topic,
# leaning to fewer/meatier pieces — not one-per-paragraph. Each article obeys
# the owner's voice DNA in full.
SYSTEM = """你是这段录音的录制者，在写自己的公众号文章。下面给你一段你自己的口述录音转写。把它挖成一篇或多篇可以各自独立发布的公众号文章。

拆分规则（重要）：
- 默认尽量合并。只有当转写里明显包含几个互不相关的主题时，才拆成多篇。
- 倾向「少而厚」：宁可一篇 1000 字讲透，也不要拆成三篇各 300 字的碎片。
- 一段口述大多只产出 1 篇；只有真的跳了好几个不相干的话题，才产出 2–3 篇。
- 每一篇都必须能独立成立：有自己的标题、自己的开头结尾，不依赖其它篇。

每一篇都遵守的语气 DNA：
- 胸有成竹地下断言，不绕弯、不加「我觉得可能也许」的缓冲。
- 不讲故事、不铺垫，直接给结论再给理由；开头一句就立住，绝不用小白式提问钩子。
- 第一人称用「我」，绝不用「笔者」。称呼 AI / Claude 一律用「他」，不用「它」。
- 多用「我 / 他」起句，少用「这里会有…」这类无人称、物称句。
- 细节能列就用表格 / 列表，不在叙述句里堆细节。
- 保留口语词（吧 / 呢 / 啊 / 了）、自造词、家常比喻——这是你的声音，别改成书面语。
- 不加 AI 味连接词（首先 / 其次 / 综上所述 / 值得注意的是），不加 emoji。
- 每篇 800–1000 字。中英文之间留一个空格（盘古之白）。
- 只用转写里出现的事实，绝不编造。不提任何公司具体名字，需要时用「我们公司」。

只输出一个 JSON 对象：{"articles": [{"title": "标题", "body": "正文 markdown"}, ...]}，不要输出任何其它文字。"""


# Always go direct (no proxy) with a normal UA: Cloudflare 403s the default
# python-urllib UA, and a local clash/VPN proxy breaks jianshuo.dev. CI has no
# proxy, so this is correct everywhere.
_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def _req(method, url, data=None, headers=None):
    h = dict(headers or {})
    h.setdefault("User-Agent", "voicedrop-miner/2")
    req = urllib.request.Request(url, data=data, method=method, headers=h)
    with _OPENER.open(req, timeout=300) as r:
        return r.read()


def api_list():
    raw = _req("GET", f"{BASE}/list", headers={"Authorization": f"Bearer {TOKEN}"})
    return json.loads(raw).get("files", [])


def api_download(key, dest):
    raw = _req("GET", f"{BASE}/download/{quote(key)}",
               headers={"Authorization": f"Bearer {TOKEN}"})
    with open(dest, "wb") as f:
        f.write(raw)


def api_put(key, body_bytes, content_type):
    _req("PUT", f"{BASE}/upload/{quote(key)}", data=body_bytes,
         headers={"Authorization": f"Bearer {TOKEN}", "Content-Type": content_type})


def _stem_keys(audio_key):
    # users/anon-x/VoiceDrop-Y.m4a -> (users/anon-x/articles/VoiceDrop-Y.json,
    #                                  users/anon-x/articles/VoiceDrop-Y.srt)
    # VoiceDrop-Y.m4a (flat)       -> (articles/VoiceDrop-Y.json, articles/VoiceDrop-Y.srt)
    parts = audio_key.rsplit("/", 1)
    stem = parts[-1][:-4]  # strip .m4a
    prefix = parts[0] + "/" if len(parts) == 2 else ""
    return f"{prefix}articles/{stem}.json", f"{prefix}articles/{stem}.srt"


def article_key_for(audio_key):
    return _stem_keys(audio_key)[0]


def empty_key_for(audio_key):
    # sidecar marking "processed, but no usable speech": articles/<stem>.empty
    parts = audio_key.rsplit("/", 1)
    stem = parts[-1][:-4]
    prefix = parts[0] + "/" if len(parts) == 2 else ""
    return f"{prefix}articles/{stem}.empty"


def fetch_wechat_config(audio_key):
    """Returns {'appid': ..., 'secret': ...} from the user's WECHAT.json, or None."""
    parts = audio_key.rsplit("/", 1)
    prefix = parts[0] + "/" if len(parts) == 2 else ""
    try:
        raw = _req("GET", f"{BASE}/download/{quote(prefix + 'WECHAT.json')}",
                   headers={"Authorization": f"Bearer {TOKEN}"})
        cfg = json.loads(raw)
        if cfg.get("appid") and cfg.get("secret"):
            return cfg
    except Exception:
        pass
    return None


def wechat_access_token(appid, secret):
    raw = _req("GET",
               f"https://api.weixin.qq.com/cgi-bin/token"
               f"?grant_type=client_credential&appid={appid}&secret={secret}")
    data = json.loads(raw)
    if "access_token" not in data:
        raise RuntimeError(f"WeChat token error: {data}")
    return data["access_token"]


def _inline_md(text):
    text = re.sub(r'\*\*(.+?)\*\*', r'<strong>\1</strong>', text)
    text = re.sub(r'__(.+?)__', r'<strong>\1</strong>', text)
    text = re.sub(r'\*(.+?)\*', r'<em>\1</em>', text)
    text = re.sub(r'`(.+?)`',
                  r'<code style="background:#f5f5f5;padding:.1em .3em;border-radius:3px">\1</code>', text)
    return text


def md_to_wechat_html(md):
    """Convert markdown to basic WeChat-compatible HTML with inline styles."""
    lines = md.split('\n')
    parts = []
    list_tag = None  # 'ul' or 'ol'
    for line in lines:
        if re.match(r'^#{1,6}\s', line):
            if list_tag:
                parts.append(f'</{list_tag}>')
                list_tag = None
            level = len(line) - len(line.lstrip('#'))
            text = _inline_md(line.lstrip('#').strip())
            size = {1: '1.5em', 2: '1.3em', 3: '1.1em'}.get(level, '1em')
            parts.append(f'<h{level} style="font-size:{size};font-weight:bold;margin:1em 0 .5em">{text}</h{level}>')
        elif re.match(r'^[-*]\s', line):
            if list_tag != 'ul':
                if list_tag:
                    parts.append(f'</{list_tag}>')
                parts.append('<ul style="padding-left:2em;margin:.5em 0">')
                list_tag = 'ul'
            parts.append(f'<li style="margin:.3em 0">{_inline_md(line[2:].strip())}</li>')
        elif re.match(r'^\d+\.\s', line):
            if list_tag != 'ol':
                if list_tag:
                    parts.append(f'</{list_tag}>')
                parts.append('<ol style="padding-left:2em;margin:.5em 0">')
                list_tag = 'ol'
            parts.append(f'<li style="margin:.3em 0">{_inline_md(re.sub(r"^\d+\.\s*", "", line).strip())}</li>')
        elif not line.strip():
            if list_tag:
                parts.append(f'</{list_tag}>')
                list_tag = None
        else:
            if list_tag:
                parts.append(f'</{list_tag}>')
                list_tag = None
            parts.append(f'<p style="margin:.8em 0;line-height:1.8">{_inline_md(line)}</p>')
    if list_tag:
        parts.append(f'</{list_tag}>')
    return '\n'.join(parts)


def create_wechat_draft(access_token, title, body_md):
    """Create a WeChat draft and return its media_id."""
    content_html = md_to_wechat_html(body_md)
    payload = {
        "articles": [{
            "title": title,
            "content": content_html,
            "need_open_comment": 0,
            "only_fans_can_comment": 0,
        }]
    }
    raw = _req("POST",
               f"https://api.weixin.qq.com/cgi-bin/draft/add?access_token={access_token}",
               data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
               headers={"Content-Type": "application/json; charset=utf-8"})
    data = json.loads(raw)
    if data.get("errcode") and data["errcode"] != 0:
        raise RuntimeError(f"WeChat draft error: {data}")
    return data.get("media_id", "")


def fetch_claude_md(audio_key):
    """The recording owner's per-user CLAUDE.md (<prefix>CLAUDE.md), set in the
    app's Settings tab — name + style. Appended to the mining prompt. '' if none."""
    parts = audio_key.rsplit("/", 1)
    prefix = parts[0] + "/" if len(parts) == 2 else ""
    try:
        raw = _req("GET", f"{BASE}/download/{quote(prefix + 'CLAUDE.md')}",
                   headers={"Authorization": f"Bearer {TOKEN}"})
        return raw.decode("utf-8", "replace").strip()
    except Exception:
        return ""


def probe_duration(path):
    """Seconds of decodable audio, or None if the file won't probe (corrupt /
    missing moov atom / 0-byte)."""
    try:
        out = subprocess.run(
            ["ffprobe", "-v", "error", "-show_entries", "format=duration",
             "-of", "csv=p=0", path],
            capture_output=True, text=True, timeout=30)
        return float(out.stdout.strip())
    except Exception:
        return None


def write_empty(audio, reason):
    """Mark a recording processed-but-empty so it's never re-mined and the app
    can show a 无语音 badge. reason ∈ {corrupt, silent, no-speech, no-article}."""
    key = empty_key_for(audio)
    body = {"schema": 2, "status": "empty", "reason": reason,
            "id": os.path.basename(audio)[:-4],
            "sourceAudio": os.path.basename(audio)}
    api_put(key, json.dumps(body, ensure_ascii=False).encode(), "application/json")
    return key


def _ms_to_ts(ms):
    ms = max(0, int(ms))
    h, ms = divmod(ms, 3600000)
    m, ms = divmod(ms, 60000)
    s, ms = divmod(ms, 1000)
    return f"{h:02d}:{m:02d}:{s:02d},{ms:03d}"


def build_srt(utterances):
    """One SRT cue per ASR utterance, using its ms start/end timestamps.
    A missing/zero start falls back to the previous cue's end; a non-positive
    span is padded to 2s so players don't choke."""
    out, idx, prev_end = [], 1, 0
    for u in utterances:
        text = (u.get("text") or "").strip()
        if not text:
            continue
        start = u.get("start_time") or prev_end
        end = u.get("end_time") or (start + 2000)
        if end <= start:
            end = start + 2000
        out += [str(idx), f"{_ms_to_ts(start)} --> {_ms_to_ts(end)}", text, ""]
        prev_end, idx = end, idx + 1
    return ("\n".join(out).strip() + "\n") if out else ""


EMPTY_ASR_EXIT = 3   # volc_asr_stream.py: ffmpeg decoded no audio (corrupt/silent)


def transcribe(audio_path, timeout_s):
    """Return (plain_transcript, srt). srt may be '' if the ASR returned no
    per-utterance timestamps; transcript is '' if the file decoded to no audio.
    Bounded by timeout_s so a wedged ASR connection can't stall the whole run."""
    out = audio_path + ".asr.json"
    try:
        p = subprocess.run([sys.executable, os.path.join(HERE, "volc_asr_stream.py"),
                            audio_path, out], timeout=timeout_s)
    except subprocess.TimeoutExpired:
        raise RuntimeError(f"ASR timed out after {timeout_s}s")
    if p.returncode == EMPTY_ASR_EXIT:        # decoded to no audio → treat as empty
        return "", ""
    if p.returncode != 0:
        raise RuntimeError(f"ASR failed (exit {p.returncode})")
    res = json.load(open(out)).get("result", {})
    utts = res.get("utterances", [])
    text = res.get("text") or "".join(u.get("text", "") for u in utts)
    return text.strip(), build_srt(utts)


def _parse_llm_json(text):
    """Extract a JSON object however the model wrapped it: strip ``` / ```json
    fences, drop a stray leading 'json' token, then take the outermost {...}."""
    t = text.strip()
    if t.startswith("```"):
        t = t.strip("`").strip()
        if t[:4].lower() == "json":
            t = t[4:].lstrip()
    i, j = t.find("{"), t.rfind("}")
    if i != -1 and j > i:
        t = t[i:j + 1]
    return json.loads(t)


class NoArticleError(RuntimeError):
    """LLM returned valid JSON with an empty articles array — content not article-worthy."""


def _articles_from(text):
    """Parse + clean the articles array from a model reply.
    Returns a list (possibly empty when parsed OK but no usable articles),
    or None when the JSON itself couldn't be parsed."""
    try:
        obj = _parse_llm_json(text)
    except Exception:
        return None  # parse failure — caller should retry
    arts = obj.get("articles") if isinstance(obj, dict) else obj
    return [
        {"title": (a.get("title") or "(无题)").strip(), "body": (a.get("body") or "").strip()}
        for a in (arts or []) if isinstance(a, dict) and (a.get("body") or "").strip()
    ]  # empty list = parsed OK, LLM decided no article possible


def generate_articles(transcript, claude_md=""):
    """Return a list of {title, body}. Balanced split: usually 1, more only on
    clearly distinct topics. Falls back to a single article on parse failure.
    The owner's CLAUDE.md (name + style), if any, is appended after the system
    prompt so the articles come out in their own voice."""
    # NB: claude-sonnet-4-6 rejects assistant-message prefill, so we force valid
    # JSON purely by robust extraction of the reply (handles ``` fences + a stray
    # leading 'json'), and never store raw text as a body.
    system = SYSTEM if not claude_md else f"{SYSTEM}\n\n---\n\n{claude_md}"
    payload = {
        "model": MODEL, "max_tokens": 8000, "system": system,
        "messages": [{"role": "user", "content": f"口述转写：\n\n{transcript}"}],
    }
    arts = None
    for attempt in range(2):  # one retry: a single malformed reply self-heals
        raw = _req("POST", "https://api.anthropic.com/v1/messages",
                   data=json.dumps(payload).encode(),
                   headers={"x-api-key": CLAUDE_KEY, "anthropic-version": "2023-06-01",
                            "content-type": "application/json"})
        resp = json.loads(raw)
        text = "".join(b.get("text", "") for b in resp.get("content", [])
                       if b.get("type") == "text")
        arts = _articles_from(text)
        if arts is not None:
            break
    if arts is None:
        raise RuntimeError("LLM did not return parseable JSON")
    if not arts:
        raise NoArticleError("LLM returned empty articles array")
    return arts


def main():
    t_list = time.time()
    files = api_list()
    names = {f["name"] for f in files}
    uploaded = {f["name"]: f.get("uploaded", "") for f in files}
    audios = [f["name"] for f in files
              if f["name"].rsplit("/", 1)[-1].startswith("VoiceDrop-")
              and f["name"].endswith(".m4a")]
    # "processed" = an article JSON OR an empty marker already exists.
    todo = [a for a in audios
            if article_key_for(a) not in names and empty_key_for(a) not in names]
    log(f"list: {len(audios)} audio · {len(todo)} unprocessed ({time.time()-t_list:.1f}s)")
    if DRY:
        for a in todo:
            log(f"  would mine: {a} -> {article_key_for(a)}")
        return
    if not CLAUDE_KEY:
        sys.exit("CLAUDE_API_KEY not set")

    run_t0 = time.time()
    mined = empty = 0
    tot_net = tot_asr = tot_llm = 0.0   # phase totals for the bottleneck breakdown

    for i, audio in enumerate(todo, 1):
        leaf = os.path.basename(audio)
        rec_t0 = time.time()
        log(f"── {leaf}  ({i}/{len(todo)})")
        try:
            with tempfile.TemporaryDirectory() as td:
                local = os.path.join(td, leaf)

                t = time.time()
                api_download(audio, local)
                dl = time.time() - t; tot_net += dl
                size = os.path.getsize(local)
                log(f"   download {size/1024:.0f}KB ({dl:.1f}s)")

                # Corrupt / silent files never reach ASR — mark and move on.
                dur = probe_duration(local)
                if dur is None or dur < 1.0:
                    reason = "corrupt" if dur is None else "silent"
                    write_empty(audio, reason)
                    empty += 1
                    log(f"   ✗ {reason} → marked 无语音 (total {time.time()-rec_t0:.1f}s)")
                    continue

                # ASR streams at ~realtime (chunked + parallel); bound generously
                # at 2× duration + 2min so a wedged connection fails fast.
                t = time.time()
                transcript, srt = transcribe(local, timeout_s=max(180, int(dur * 2) + 120))
                asr = time.time() - t; tot_asr += asr
                log(f"   ASR → {len(transcript)} chars ({asr:.1f}s)")

                if not transcript:
                    write_empty(audio, "no-speech")
                    empty += 1
                    log(f"   ✗ no-speech → marked 无语音 (total {time.time()-rec_t0:.1f}s)")
                    continue

                # Too thin to be an article — mark empty and skip the LLM, else
                # the model returns prose (not JSON) and the file fails forever.
                if len(transcript.strip()) < MIN_CHARS:
                    write_empty(audio, "too-short")
                    empty += 1
                    log(f"   ✗ too-short ({len(transcript.strip())} chars) → marked 无语音 (total {time.time()-rec_t0:.1f}s)")
                    continue

                claude_md = fetch_claude_md(audio)
                if claude_md:
                    log(f"   + CLAUDE.md ({len(claude_md)} chars)")
                t = time.time()
                try:
                    articles = generate_articles(transcript, claude_md)
                except NoArticleError:
                    llm = time.time() - t; tot_llm += llm
                    write_empty(audio, "no-article")
                    empty += 1
                    log(f"   ✗ no-article → marked 无语音 (total {time.time()-rec_t0:.1f}s)")
                    continue
                llm = time.time() - t; tot_llm += llm
                log(f"   Claude mine → {len(articles)} article(s) ({llm:.1f}s)")

                json_key, srt_key = _stem_keys(audio)
                art = {
                    "schema": 2,
                    "id": leaf[:-4],
                    "sourceAudio": leaf,
                    "createdAt": uploaded.get(audio, ""),
                    "transcript": transcript,
                    "srt": srt,
                    "articles": articles,
                    "status": "ready",
                    "model": MODEL,
                }
                t = time.time()
                api_put(json_key, json.dumps(art, ensure_ascii=False).encode(),
                        "application/json")
                if srt:
                    api_put(srt_key, srt.encode(), "application/x-subrip; charset=utf-8")
                tot_net += time.time() - t
                mined += 1
                titles = " | ".join(a["title"] for a in articles)
                log(f"   ✓ {len(articles)} article(s): {titles} (total {time.time()-rec_t0:.1f}s)")

                # Push WeChat drafts if the user has credentials stored.
                wechat_cfg = fetch_wechat_config(audio)
                if wechat_cfg:
                    try:
                        wx_token = wechat_access_token(wechat_cfg["appid"], wechat_cfg["secret"])
                        media_ids = []
                        for a in articles:
                            mid = create_wechat_draft(wx_token, a["title"], a["body"])
                            media_ids.append(mid)
                            log(f"   📩 WeChat draft: {a['title']} → {mid}")
                        # Persist media_ids back into the article JSON so we don't re-publish.
                        for a, mid in zip(art["articles"], media_ids):
                            a["wechatMediaId"] = mid
                        api_put(json_key, json.dumps(art, ensure_ascii=False).encode(),
                                "application/json")
                    except Exception as wx_err:
                        log(f"   ⚠ WeChat draft failed: {wx_err}")
        except Exception as e:
            log(f"   FAILED {leaf}: {e}")
            print(f"  FAILED {audio}: {e}", file=sys.stderr)

    total = time.time() - run_t0
    if total > 0:
        pct = lambda x: round(100 * x / total)
        other = max(0, total - tot_asr - tot_llm - tot_net)
        log(f"DONE: {mined} mined · {empty} empty · {total:.0f}s total  "
            f"[ASR {pct(tot_asr)}% · LLM {pct(tot_llm)}% · net {pct(tot_net)}% · other {pct(other)}%]")
    else:
        log(f"DONE: {mined} mined · {empty} empty")


if __name__ == "__main__":
    main()
