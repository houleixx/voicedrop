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
import os, re, sys, json, time, struct, zlib, subprocess, tempfile, urllib.request, hashlib, base64
from urllib.parse import quote


def log(msg):
    """Wall-clock-stamped progress line, flushed so CI logs stream live."""
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)

BASE = "https://jianshuo.dev/files/api"
NOTIFY_URL = "https://jianshuo.dev/agent/notify"
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
# HTTP proxy for WeChat API calls — must be the Tokyo VPS whitelisted on the
# WeChat account (66.42.45.128). GitHub Actions IPs are not in the whitelist
# and get errcode 40164 without this. Set WECHAT_PROXY in repo secrets.
WECHAT_PROXY = os.environ.get("WECHAT_PROXY", "")

# Added to the system prompt when the session has photos. Appended BEFORE
# CLAUDE.md so user's style card overrides tone but not the visual instruction.
_PHOTO_INSTR = """
另外附上了几张照片，每张标了编号和拍摄时刻。照片是作者一边说一边拍的，拍摄时刻能帮你判断这张照片对应口述里的哪一段。要求：
- 把照片的场景自然融进叙述，就像亲眼看到一样直接写进去，不要机械地写「照片里是…」。
- 在正文里、口述提到这个场景的那个位置，单独起一行插入照片标记 `[[photo:N]]`（N 是照片编号）。标记必须独占一行，前后空行。
- 每张照片在全文里只插入一次，按拍摄时刻对应到合适的段落附近。
- 如果某张照片实在和口述对不上，就放在最相关的那段后面。"""

# Balanced split: 1+ standalone articles, one per *clearly distinct* topic,
# leaning to fewer/meatier pieces — not one-per-paragraph. Each article obeys
# the owner's voice DNA in full.
SYSTEM = """你是这段录音的录制者，在写自己的公众号文章。下面给你一段你自己的口述录音转写。把它挖成一篇或多篇可以各自独立发布的公众号文章。

拆分规则（重要）：
- 默认尽量合并。只有当转写里明显包含几个互不相关的主题时，才拆成多篇。
- 倾向「少而厚」：宁可一篇讲透，也不要拆成几篇互相重复的碎片。
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
- 篇幅完全顺着内容走：转写里有多少东西就写多少，长就长、短就短，三五句话也能成篇——绝不为凑字数注水或编造，也不设字数下限或上限。中英文之间留一个空格（盘古之白）。
- 只用转写里出现的事实，绝不编造。不提任何公司具体名字，需要时用「我们公司」。

只输出一个 JSON 对象：{"articles": [{"title": "标题", "body": "正文 markdown"}, ...]}，不要输出任何其它文字。只要转写里有哪怕一两句有意义的话，就要成文（可以很短）；只有完全没有可写内容时（纯噪音、半句没说完、纯口误）才输出 {"articles": []}。"""

# Appended AFTER user's CLAUDE.md so that an elaborate style card cannot raise the
# "should I write at all?" bar — style is HOW, not WHETHER.
_FORCE_SUFFIX = """

---

【成文底线 — 优先级高于以上所有风格要求】
以上是「怎么写」的风格指南。不管内容是否完全符合上述风格，只要转写里有人在说话，就必须产出至少一篇文章。「内容不够精彩」「风格要求难以达到」均不是返回空数组的理由。短则短写，口语则口语，两三句也能成篇。"""

# Stripped-down system used only as a last-resort retry when the style-laden first
# pass returns no articles — removes all style constraints so output is guaranteed.
SYSTEM_FORCE = """把下面的口述转写整理成一篇短文，保留说话人的意思和语气。直接输出 JSON：{"articles": [{"title": "标题", "body": "正文"}]}。只要有人在说话就必须成文，不能返回空数组。"""


# Structured-outputs schema: makes the API *constrain* the reply to valid JSON,
# so a large prose-heavy CLAUDE.md can't pull the model off clean JSON (the cause
# of the old "LLM did not return parseable JSON" failures). GA on sonnet-4-6.
ARTICLES_SCHEMA = {
    "type": "object",
    "properties": {
        "articles": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {"title": {"type": "string"}, "body": {"type": "string"}},
                "required": ["title", "body"],
                "additionalProperties": False,
            },
        }
    },
    "required": ["articles"],
    "additionalProperties": False,
}


# Always go direct (no proxy) with a normal UA: Cloudflare 403s the default
# python-urllib UA, and a local clash/VPN proxy breaks jianshuo.dev. CI has no
# proxy, so this is correct everywhere.
_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))

# Separate opener for WeChat API — must route through the Tokyo VPS whose IP
# is whitelisted on the WeChat account. WECHAT_PROXY must be set as a GitHub
# Actions secret (e.g. http://user:pass@66.42.45.128:8888).
if WECHAT_PROXY:
    _WECHAT_OPENER = urllib.request.build_opener(
        urllib.request.ProxyHandler({"http": WECHAT_PROXY, "https": WECHAT_PROXY})
    )
else:
    _WECHAT_OPENER = _OPENER  # no proxy — will hit 40164 if IP not whitelisted


def _req(method, url, data=None, headers=None):
    h = dict(headers or {})
    h.setdefault("User-Agent", "voicedrop-miner/2")
    req = urllib.request.Request(url, data=data, method=method, headers=h)
    with _OPENER.open(req, timeout=300) as r:
        return r.read()


def _wechat_req(method, url, data=None, headers=None):
    h = dict(headers or {})
    h.setdefault("User-Agent", "voicedrop-miner/2")
    req = urllib.request.Request(url, data=data, method=method, headers=h)
    with _WECHAT_OPENER.open(req, timeout=60) as r:
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


def _article_stem(json_key):
    """Extract "<sub>/<stem>" from "users/<sub>/articles/<stem>.json" for the article API."""
    # "users/<sub>/articles/<stem>.json" → "<sub>/<stem>"
    without_users = json_key.removeprefix("users/")          # "<sub>/articles/<stem>.json"
    sub, rest = without_users.split("/articles/", 1)          # sub, "<stem>.json"
    stem = rest.removesuffix(".json")
    return f"{sub}/{stem}"


def api_article_write(json_key, doc):
    """Write an article JSON through the high-level article API (versioned)."""
    stem = _article_stem(json_key)
    _req("PUT", f"{BASE}/articles/{quote(stem, safe='/')}",
         data=json.dumps(doc, ensure_ascii=False).encode(),
         headers={"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"})


def api_article_srt(srt_key, content):
    """Write an SRT sidecar through the article API."""
    stem = _article_stem(srt_key.replace(".srt", ".json"))
    _req("PUT", f"{BASE}/articles/{quote(stem, safe='/')}/srt",
         data=content if isinstance(content, bytes) else content.encode(),
         headers={"Authorization": f"Bearer {TOKEN}", "Content-Type": "text/plain"})


def api_article_empty(empty_key, reason="no-speech"):
    """Mark a recording as no-speech through the article API."""
    stem = _article_stem(empty_key.replace(".empty", ".json"))
    _req("PUT", f"{BASE}/articles/{quote(stem, safe='/')}/empty",
         data=json.dumps({"reason": reason}).encode(),
         headers={"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"})


def api_exists(key):
    # R2 list is eventually consistent — a just-written object may not yet appear
    # in list results. Single-key HEAD is always strongly consistent.
    try:
        _req("HEAD", f"{BASE}/download/{quote(key)}",
             headers={"Authorization": f"Bearer {TOKEN}"})
        return True
    except Exception:
        return False


def llmlog(request, *, response=None, error=None, ok, status, latency, step, turn_id, meta=None):
    """Record one Anthropic call to R2 under llmlogs/ so the admin console
    (voicedrop/admin/llm.html) can replay exactly what was sent & received.
    Admin-only (outside users/). Best-effort: never let logging break mining."""
    try:
        meta = meta or {}
        ts = int(time.time() * 1000)
        rid = f"{ts}-{os.urandom(3).hex()}"
        date = time.strftime("%Y-%m-%d", time.gmtime(ts / 1000))  # UTC, matches worker
        rec = {
            "id": rid, "ts": ts, "source": "mine",
            "user_scope": meta.get("user_scope", ""), "model": MODEL,
            "latency_ms": int(latency * 1000), "http_status": status, "ok": ok,
            "turn_id": turn_id, "step": step, "request": request,
        }
        if response is not None:
            rec["response"] = response
        if error is not None:
            rec["error"] = error
        rec["meta"] = {"stem": meta.get("stem", "")}
        api_put(f"llmlogs/{date}/{rid}.json",
                json.dumps(rec, ensure_ascii=False).encode(), "application/json")
    except Exception:
        pass  # logging must never interrupt the actual work


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


def _user_prefix(key):
    """The user's own prefix (users/<sub>/) for any key beneath it, where
    WECHAT.json / CLAUDE.md live. Works for an audio key
    (users/<sub>/VoiceDrop-*.m4a) and an article key
    (users/<sub>/articles/<stem>.json). Flat (un-prefixed) keys → ''."""
    if "/articles/" in key:
        return key.split("/articles/")[0] + "/"
    parts = key.rsplit("/", 1)
    return parts[0] + "/" if len(parts) == 2 else ""


def _session_ts(audio_key):
    """Extract 'yyyy-MM-dd-HHmmss' from a VoiceDrop-... filename.
    VoiceDrop-2026-06-24-131500-2m33s-... → '2026-06-24-131500'."""
    leaf = os.path.basename(audio_key)
    if leaf.endswith(".m4a"): leaf = leaf[:-4]
    parts = leaf.split("-")
    if len(parts) >= 5 and parts[0] == "VoiceDrop":
        return "-".join(parts[1:5])
    return None


def find_session_photos(audio_key, all_names):
    """Return sorted list of full R2 photo keys for this audio session.
    Photos live at users/<sub>/photos/<sessionTs>/<captureTs>.jpg, uploaded while
    the user speaks. The folder ts equals the audio's session ts exactly — both
    derive from the recorder's single start instant (see AudioRecorder.startDate),
    so a plain prefix match is reliable."""
    prefix = _user_prefix(audio_key)
    ts = _session_ts(audio_key)
    if not ts:
        return []
    folder = f"{prefix}photos/{ts}/"
    return sorted(n for n in all_names if n.startswith(folder) and n.lower().endswith(".jpg"))


# Vision input is downscaled to this — a small thumbnail is plenty for the model
# to describe a scene, and it cuts image tokens ~10× vs the stored 1080px photo
# (≈137 tok at 320² vs ≈1555 tok at 1080²). The R2 photo stays full-size for the
# app/web to display; only the copy SENT to Claude is shrunk.
LLM_PHOTO_SIDE = int(os.environ.get("MINE_PHOTO_SIDE", "320"))


def _downscale_jpeg(raw, max_side):
    """Shrink JPEG bytes so the longest side ≤ max_side. Best-effort: if Pillow
    isn't installed (e.g. the VPS relay, which never calls this), return as-is."""
    try:
        import io
        from PIL import Image
        im = Image.open(io.BytesIO(raw))
        im.load()
        if im.mode != "RGB":
            im = im.convert("RGB")
        if max(im.size) <= max_side:
            return raw
        im.thumbnail((max_side, max_side))
        buf = io.BytesIO()
        im.save(buf, format="JPEG", quality=80)
        return buf.getvalue()
    except Exception:
        return raw


def load_photo_b64(photo_key):
    """Download a photo from R2, downscale it for vision, and return
    (base64_jpeg, human_time_label). The label is from the capture timestamp."""
    raw = _req("GET", f"{BASE}/download/{quote(photo_key)}",
               headers={"Authorization": f"Bearer {TOKEN}"})
    raw = _downscale_jpeg(raw, LLM_PHOTO_SIDE)
    b64 = base64.standard_b64encode(raw).decode("ascii")
    capture = os.path.basename(photo_key)[:-4]   # e.g. "2026-06-24-131523"
    parts = capture.split("-")
    if len(parts) >= 4 and len(parts[3]) == 6:
        t = parts[3]
        label = f"{t[:2]}:{t[2:4]}:{t[4:]}"
    else:
        label = capture
    return b64, label


def fetch_wechat_config(key, require_enabled=True):
    """Returns the user's WECHAT.json dict, or None if absent / incomplete (or,
    when require_enabled, if the 自动推草稿 toggle is off). On-demand publishing
    from the app passes require_enabled=False — a manual tap should push even
    when auto-push is disabled. `key` may be an audio or an article key."""
    prefix = _user_prefix(key)
    try:
        raw = _req("GET", f"{BASE}/download/{quote(prefix + 'WECHAT.json')}",
                   headers={"Authorization": f"Bearer {TOKEN}"})
        cfg = json.loads(raw)
        if not cfg.get("appid") or not cfg.get("secret"):
            return None
        # enabled defaults to True for backwards compat (old JSON had no field)
        if require_enabled and cfg.get("enabled") is False:
            return None
        return cfg
    except Exception:
        pass
    return None


def wechat_access_token(appid, secret):
    raw = _wechat_req("GET",
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
    """Convert markdown to basic WeChat-compatible HTML with inline styles.
    [[photo:N]] markers (in-app inline photos) are stripped — WeChat drafts
    don't carry the session photos, so the markers must not leak as text."""
    md = re.sub(r'\[\[photo:\d+\]\]', '', md)
    md = re.sub(r'\n{3,}', '\n\n', md)
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


def _make_placeholder_png(width=500, height=280):
    """Pure-stdlib grayscale PNG — used as a placeholder cover image."""
    def _chunk(tag, data):
        crc = zlib.crc32(tag + data) & 0xffffffff
        return struct.pack('>I', len(data)) + tag + data + struct.pack('>I', crc)
    row = b'\x00' + bytes([0x80] * width)   # filter-byte 0 + gray(128) pixels
    compressed = zlib.compress(row * height, level=1)
    ihdr = _chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 0, 0, 0, 0))
    idat = _chunk(b'IDAT', compressed)
    iend = _chunk(b'IEND', b'')
    return b'\x89PNG\r\n\x1a\n' + ihdr + idat + iend


def _upload_cover_material(access_token, png, filename="cover.png", content_type="image/png"):
    """Upload image bytes as a WeChat permanent image material; return the media_id."""
    boundary = b'VoiceDropBoundary42'
    part = (b'--' + boundary + b'\r\n'
            b'Content-Disposition: form-data; name="media"; filename="' + filename.encode("utf-8") + b'"\r\n'
            b'Content-Type: ' + content_type.encode() + b'\r\n\r\n' + png + b'\r\n')
    body = part + b'--' + boundary + b'--\r\n'
    raw = _wechat_req(
        "POST",
        f"https://api.weixin.qq.com/cgi-bin/material/add_material"
        f"?access_token={access_token}&type=image",
        data=body,
        headers={"Content-Type": f"multipart/form-data; boundary={boundary.decode()}"},
    )
    result = json.loads(raw)
    if "media_id" not in result:
        raise RuntimeError(f"WeChat cover upload error: {result}")
    return result["media_id"]


def _upload_wechat_cover(access_token):
    """Fallback cover: upload the generated gray placeholder (used only when the
    assets/wechat-covers/ set is empty or unreachable). Returns the media_id."""
    return _upload_cover_material(access_token, _make_placeholder_png())


# Per-article covers: images in R2 assets/wechat-covers/, served publicly at
# BASE/asset/wechat-covers. Each doc gets one, fixed by a stable hash of its id,
# uploaded to WeChat once and cached per image name so docs sharing a cover reuse
# the material. Used by BOTH the on-demand relay (no R2) and the CI miner.
COVER_PREFIX = "wechat-covers"


def _cover_names():
    """Public list of cover image names in assets/wechat-covers/ (no auth needed)."""
    try:
        raw = _req("GET", f"{BASE}/asset/{COVER_PREFIX}")
        names = (json.loads(raw) or {}).get("covers", [])
        return sorted(n for n in names if n.lower().endswith((".png", ".jpg", ".jpeg")))
    except Exception:
        return []


def _pick_cover(doc_id, names):
    """Deterministically map a doc id to one cover name (stable across runs)."""
    h = int(hashlib.sha256((doc_id or "").encode("utf-8")).hexdigest(), 16)
    return names[h % len(names)]


def resolve_cover_thumb(access_token, doc_id, wechat_cfg, force=False):
    """Return a WeChat thumb_media_id for this doc: pick a cover from
    assets/wechat-covers/ by hash(doc_id), upload it once, and cache the media_id
    under wechat_cfg['coverMediaIds'][name]. Falls back to the gray placeholder if
    the cover set is empty/unreachable. Mutates wechat_cfg; the caller persists it
    (CI: api_put WECHAT.json; relay: the Function persists what we return)."""
    names = _cover_names()
    if not names:
        return _upload_wechat_cover(access_token)
    name = _pick_cover(doc_id, names)
    cache = wechat_cfg.setdefault("coverMediaIds", {})
    if not force and cache.get(name):
        return cache[name]
    png = _req("GET", f"{BASE}/asset/{COVER_PREFIX}/{quote(name)}")
    cache[name] = _upload_cover_material(access_token, png, filename=name)
    return cache[name]


class InvalidMediaIdError(RuntimeError):
    """WeChat errcode 40007 — a media_id (draft or cover) no longer exists, e.g.
    the user deleted the draft / wiped materials. Recoverable: recreate it."""


def _store_thumb(access_token, wechat_cfg, key):
    """Upload a fresh placeholder cover, persist its id into WECHAT.json, and
    return the new thumb_media_id."""
    thumb_id = _upload_wechat_cover(access_token)
    wechat_cfg["thumb_media_id"] = thumb_id
    api_put(_user_prefix(key) + "WECHAT.json",
            json.dumps(wechat_cfg, ensure_ascii=False).encode(), "application/json")
    return thumb_id


def ensure_wechat_thumb(access_token, wechat_cfg, audio_key):
    """Return a permanent thumb_media_id, uploading a cover once if needed.
    Updates WECHAT.json in R2 so the ID is reused on every subsequent draft."""
    return wechat_cfg.get("thumb_media_id") or _store_thumb(access_token, wechat_cfg, audio_key)


def create_wechat_draft(access_token, title, body_md, thumb_media_id):
    """Create a WeChat draft and return its media_id."""
    content_html = md_to_wechat_html(body_md)
    payload = {
        "articles": [{
            "title": title,
            "thumb_media_id": thumb_media_id,
            "content": content_html,
            "need_open_comment": 0,
            "only_fans_can_comment": 0,
        }]
    }
    raw = _wechat_req("POST",
                      f"https://api.weixin.qq.com/cgi-bin/draft/add?access_token={access_token}",
                      data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
                      headers={"Content-Type": "application/json; charset=utf-8"})
    data = json.loads(raw)
    if data.get("errcode") and data["errcode"] != 0:
        if data["errcode"] == 40007:        # stale thumb_media_id
            raise InvalidMediaIdError(f"WeChat draft create: {data}")
        raise RuntimeError(f"WeChat draft error: {data}")
    return data.get("media_id", "")


def update_wechat_draft(access_token, media_id, index, title, body_md, thumb_media_id):
    """Update an existing WeChat draft in place (no new draft). draft/update takes
    a single article object (not a list) at the given index."""
    content_html = md_to_wechat_html(body_md)
    payload = {
        "media_id": media_id,
        "index": index,
        "articles": {
            "title": title,
            "thumb_media_id": thumb_media_id,
            "content": content_html,
            "need_open_comment": 0,
            "only_fans_can_comment": 0,
        },
    }
    raw = _wechat_req("POST",
                      f"https://api.weixin.qq.com/cgi-bin/draft/update?access_token={access_token}",
                      data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
                      headers={"Content-Type": "application/json; charset=utf-8"})
    data = json.loads(raw)
    if data.get("errcode"):
        if data["errcode"] == 40007:        # stale draft media_id (deleted draft)
            raise InvalidMediaIdError(f"WeChat draft update: {data}")
        raise RuntimeError(f"WeChat draft update error: {data}")


def sync_wechat_drafts(access_token, art, thumb_media_id, make_thumb=None):
    """Push one WeChat draft per article in `art`, mutating each in place.
    An article with a still-valid wechatMediaId is updated where it sits (no
    duplicate); a missing OR stale one (the saved draft was deleted → 40007) is
    created fresh and its id stored back. If creating also 40007s — the cover
    material was wiped — and make_thumb is given, a new cover is uploaded and the
    create retried once. Shared by the miner's first pass and the app's on-demand
    发布. Returns (created, updated)."""
    created = updated = 0
    for a in art.get("articles", []):
        mid = a.get("wechatMediaId")
        if mid:
            try:
                update_wechat_draft(access_token, mid, 0, a["title"], a["body"], thumb_media_id)
                updated += 1
                log(f"   ♻ WeChat draft updated: {a['title']} → {mid}")
                continue
            except InvalidMediaIdError:
                log(f"   ⚠ stale draft media_id {mid} → creating a fresh draft")
                a.pop("wechatMediaId", None)
        try:
            new_mid = create_wechat_draft(access_token, a["title"], a["body"], thumb_media_id)
        except InvalidMediaIdError:
            if not make_thumb:
                raise
            log("   ⚠ cover material invalid → re-uploading cover")
            thumb_media_id = make_thumb()
            new_mid = create_wechat_draft(access_token, a["title"], a["body"], thumb_media_id)
        a["wechatMediaId"] = new_mid
        created += 1
        log(f"   📩 WeChat draft: {a['title']} → {new_mid}")
    return created, updated


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


def notify(audio_key, status):
    """Fire-and-forget: push a status change to the user's StatusHub so the app
    can update in real-time without polling. status ∈ {asr, mining, ready, empty}
    → badges 听录音 / 挖文章 / 已成文 / 无语音 (待处理 is the app's pre-pickup state).
    Non-fatal — a failed notify just means the app stays on the old badge until
    the next manual refresh."""
    scope = _user_prefix(audio_key)
    stem = os.path.basename(audio_key)
    if stem.endswith(".m4a"):
        stem = stem[:-4]
    try:
        body = json.dumps({"user_scope": scope, "stem": stem, "status": status}).encode()
        _req("POST", NOTIFY_URL, data=body,
             headers={"Authorization": f"Bearer {TOKEN}",
                      "Content-Type": "application/json"})
    except Exception as e:
        log(f"   notify({status}) failed (non-fatal): {e}")


def write_empty(audio, reason):
    """Mark a recording processed-but-empty so it's never re-mined and the app
    can show a 无语音 badge. reason ∈ {corrupt, silent, no-speech, no-article}."""
    key = empty_key_for(audio)
    api_article_empty(key, reason)
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


EMPTY_ASR_EXIT = 3   # volc_asr_file.py: empty / silent audio
ASR_FAIL_EXIT  = 4   # volc_asr_file.py: deterministic ASR error (don't retry)


class AsrError(RuntimeError):
    """火山在识别阶段返回确定性业务错误码（如 45000151）——这段音频每次重试都是
    同样的码，重试无用。带上错误码，让上层把它标记成已处理、停止重试。"""
    def __init__(self, code):
        super().__init__(f"ASR deterministic error {code}")
        self.code = str(code)


def transcribe(audio_key, timeout_s):
    """Return (plain_transcript, srt_string).
    Submits the R2 key to the file-recognition API (no local download needed).
    Returns ('', '') for empty/silent audio; raises AsrError for a deterministic
    Volcano error (don't retry) and RuntimeError for transient failures (retry)."""
    fd, out = tempfile.mkstemp(suffix=".asr.json")
    os.close(fd)
    try:
        try:
            p = subprocess.run([sys.executable, os.path.join(HERE, "volc_asr_file.py"),
                                audio_key, out], timeout=timeout_s)
        except subprocess.TimeoutExpired:
            raise RuntimeError(f"ASR timed out after {timeout_s}s")
        if p.returncode == EMPTY_ASR_EXIT:
            return "", ""
        if p.returncode == ASR_FAIL_EXIT:
            code = ""
            try:
                code = json.load(open(out)).get("asr_error_code", "")
            except Exception:
                pass
            raise AsrError(code)
        if p.returncode != 0:
            raise RuntimeError(f"ASR failed (exit {p.returncode})")
        res = json.load(open(out)).get("result", {})
        utts = res.get("utterances", [])
        text = res.get("text") or "".join(u.get("text", "") for u in utts)
        return text.strip(), build_srt(utts)
    finally:
        try: os.unlink(out)
        except OSError: pass


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


def _sanitize_for_log(payload):
    """Copy of the API payload with base64 image bytes replaced by a short
    placeholder, so llmlogs don't store hundreds of KB of image data per call."""
    msgs = payload.get("messages")
    if not msgs:
        return payload
    out = dict(payload)
    new_msgs = []
    for m in msgs:
        content = m.get("content")
        if isinstance(content, list):
            blocks = []
            for b in content:
                if isinstance(b, dict) and b.get("type") == "image":
                    src = b.get("source", {})
                    n = len(src.get("data", "")) if isinstance(src, dict) else 0
                    blocks.append({"type": "image", "source": {"type": "base64",
                                   "media_type": src.get("media_type", "image/jpeg"),
                                   "data": f"<{n} b64 chars omitted>"}})
                else:
                    blocks.append(b)
            new_msgs.append({**m, "content": blocks})
        else:
            new_msgs.append(m)
    out["messages"] = new_msgs
    return out


def generate_articles(transcript, claude_md="", force=False, meta=None, photos=None):
    """Return a list of {title, body}. Balanced split: usually 1, more only on
    clearly distinct topics. Falls back to a single article on parse failure.
    The owner's CLAUDE.md (name + style), if any, is appended after the system
    prompt so the articles come out in their own voice.
    photos: optional list of (base64_str, time_label) tuples; if provided the
    API call becomes multimodal (vision) so Claude can describe the scenes.
    force=True uses a minimal system prompt (no style rules) as a last resort."""
    # Structured outputs (output_config.format) constrain the reply to schema-valid
    # JSON, so a big prose-heavy CLAUDE.md can't drift the model off clean JSON.
    # _parse_llm_json stays as a belt-and-suspenders fallback.
    if force:
        system = SYSTEM_FORCE
    elif claude_md:
        # _FORCE_SUFFIX ensures the style card doesn't veto article creation.
        system = f"{SYSTEM}{_PHOTO_INSTR if photos else ''}\n\n---\n\n{claude_md}{_FORCE_SUFFIX}"
    else:
        system = SYSTEM + (_PHOTO_INSTR if photos else "")
    max_tokens = 2000 if force else 8000

    # Build user message: text transcript + optional image blocks
    if photos and not force:
        user_content = [{"type": "text", "text": f"口述转写：\n\n{transcript}"}]
        for i, (b64, label) in enumerate(photos, 1):
            user_content.append({"type": "text", "text": f"\n[照片 {i}，拍摄于 {label}]"})
            user_content.append({
                "type": "image",
                "source": {"type": "base64", "media_type": "image/jpeg", "data": b64}
            })
        user_msg = user_content
    else:
        user_msg = f"口述转写：\n\n{transcript}"

    payload = {
        "model": MODEL, "max_tokens": max_tokens, "system": system,
        "messages": [{"role": "user", "content": user_msg}],
        "output_config": {"format": {"type": "json_schema", "schema": ARTICLES_SCHEMA}},
    }
    log_payload = _sanitize_for_log(payload)   # drop base64 image bytes
    arts = None
    turn_id = f"{int(time.time() * 1000)}-{os.urandom(3).hex()}"
    for attempt in range(2):  # one retry: a single malformed reply self-heals
        t0 = time.time()
        try:
            raw = _req("POST", "https://api.anthropic.com/v1/messages",
                       data=json.dumps(payload).encode(),
                       headers={"x-api-key": CLAUDE_KEY, "anthropic-version": "2023-06-01",
                                "content-type": "application/json"})
            resp = json.loads(raw)
            llmlog(log_payload, response=resp, ok=True, status=200, latency=time.time() - t0,
                   step=attempt, turn_id=turn_id, meta=meta)
        except Exception as e:
            errtext = str(e)
            try:  # urllib HTTPError carries the response body + status code
                errtext = e.read().decode("utf-8", "replace")[:2000]
            except Exception:
                pass
            llmlog(log_payload, error=errtext, ok=False, status=getattr(e, "code", 0),
                   latency=time.time() - t0, step=attempt, turn_id=turn_id, meta=meta)
            raise
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
        # Find photos taken during this recording session.
        photo_keys = find_session_photos(audio, names)   # full R2 keys
        # Guard against R2 list lag: a concurrent run may have written the article
        # JSON just before our list call. Verify with a direct HEAD (strongly consistent).
        if api_exists(article_key_for(audio)) or api_exists(empty_key_for(audio)):
            log(f"   skip (article exists — list was truncated or lagged)")
            continue
        notify(audio, "asr")   # app: 待处理 → 听录音
        try:
            t = time.time()
            try:
                transcript, srt = transcribe(audio, timeout_s=600)
            except AsrError as ae:
                # Deterministic Volcano failure — this audio will never transcribe.
                # Mark it processed (无语音) so it's never re-mined, and move on.
                tot_asr += time.time() - t
                write_empty(audio, f"asr-error:{ae.code}")
                empty += 1
                log(f"   ✗ ASR 确定性失败 {ae.code} → 标记无语音，不再重试 "
                    f"(total {time.time()-rec_t0:.1f}s)")
                notify(audio, "empty")
                continue
            asr = time.time() - t; tot_asr += asr
            log(f"   ASR → {len(transcript)} chars ({asr:.1f}s)")

            if not transcript:
                write_empty(audio, "no-speech")
                empty += 1
                log(f"   ✗ no-speech → marked 无语音 (total {time.time()-rec_t0:.1f}s)")
                notify(audio, "empty")
                continue

            # Too thin to be an article — mark empty and skip the LLM, else
            # the model returns prose (not JSON) and the file fails forever.
            if len(transcript.strip()) < MIN_CHARS:
                write_empty(audio, "too-short")
                empty += 1
                log(f"   ✗ too-short ({len(transcript.strip())} chars) → marked 无语音 (total {time.time()-rec_t0:.1f}s)")
                notify(audio, "empty")
                continue

            notify(audio, "mining")   # app: 听录音 → 挖文章
            claude_md = fetch_claude_md(audio)
            if claude_md:
                log(f"   + CLAUDE.md ({len(claude_md)} chars)")

            # Load photos (if any) for this session.
            photos = []
            if photo_keys:
                log(f"   + {len(photo_keys)} photo(s), loading…")
                for pk in photo_keys:
                    try:
                        b64, label = load_photo_b64(pk)
                        photos.append((b64, label))
                    except Exception as pe:
                        log(f"   ⚠ photo load failed ({pk}): {pe}")

            meta = {"user_scope": _user_prefix(audio), "stem": leaf[:-4]}
            t = time.time()
            try:
                articles = generate_articles(transcript, claude_md, meta=meta,
                                             photos=photos or None)
            except NoArticleError:
                tot_llm += time.time() - t
                # Style-laden pass returned empty — retry with force mode
                # (no style constraints) before giving up.
                log(f"   ⚠ no-article on first pass, retrying (force mode)…")
                t2 = time.time()
                try:
                    articles = generate_articles(transcript, force=True, meta=meta)
                    llm2 = time.time() - t2
                    tot_llm += llm2
                    log(f"   Claude mine (force) → {len(articles)} article(s) ({llm2:.1f}s)")
                except (NoArticleError, Exception) as e2:
                    tot_llm += time.time() - t2
                    write_empty(audio, "no-article")
                    empty += 1
                    log(f"   ✗ no-article (both passes) → marked 无语音 (total {time.time()-rec_t0:.1f}s)")
                    notify(audio, "empty")
                    continue
            else:
                llm = time.time() - t
                tot_llm += llm
                log(f"   Claude mine → {len(articles)} article(s) ({llm:.1f}s)")

            json_key, srt_key = _stem_keys(audio)
            # Store photos as relative keys (strip user scope prefix) so the iOS
            # app can download them through the Files API using the user token.
            prefix = _user_prefix(audio)
            relative_photos = [k[len(prefix):] for k in photo_keys]
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
            if relative_photos:
                art["photos"] = relative_photos
            t = time.time()
            api_article_write(json_key, art)
            if srt:
                api_article_srt(srt_key, srt)
            tot_net += time.time() - t
            notify(audio, "ready")   # app: 处理中 → 已成文
            mined += 1
            titles = " | ".join(a["title"] for a in articles)
            log(f"   ✓ {len(articles)} article(s): {titles} (total {time.time()-rec_t0:.1f}s)")

            # Push WeChat drafts if the user has credentials stored and the
            # 自动推草稿 toggle is on. Persists each article's wechatMediaId so
            # a later on-demand 发布 updates that draft in place, not a dupe.
            wechat_cfg = fetch_wechat_config(audio)
            if wechat_cfg:
                try:
                    wx_token = wechat_access_token(wechat_cfg["appid"], wechat_cfg["secret"])
                    doc_id = art.get("id") or leaf[:-4]
                    thumb_id = resolve_cover_thumb(wx_token, doc_id, wechat_cfg)
                    sync_wechat_drafts(wx_token, art, thumb_id,
                                       make_thumb=lambda: resolve_cover_thumb(wx_token, doc_id, wechat_cfg, force=True))
                    # Persist the cover->media_id cache, then the wechatMediaIds.
                    api_put(_user_prefix(audio) + "WECHAT.json",
                            json.dumps(wechat_cfg, ensure_ascii=False).encode(), "application/json")
                    api_article_write(json_key, art)
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
