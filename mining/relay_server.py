#!/usr/bin/env python3
"""VoiceDrop WeChat publish relay — runs on the Tokyo VPS (66.42.45.128), whose
IP is whitelisted on the 公众号 account, so it calls api.weixin.qq.com DIRECTLY
(no proxy hop). The Cloudflare Function POSTs the article + WeChat creds here and
awaits the REAL result, so the app can finally show success/errcode synchronously
instead of the old fire-and-forget GitHub-Action dispatch.

Self-contained (2026-06-26): the WeChat + cover helpers used to live in
mining/mine.py (the old Python miner), which the relay `import`ed. mine.py is gone
— its mining half was replaced by the Worker miner (agent/src/miner.js) and its
WeChat half is now inlined below. No R2 token, no ASR, no Claude — just WeChat.

Dumb relay by design: it holds NO R2 / FILES_TOKEN, never touches R2. It receives
appid/secret per request (kept in memory, never logged), talks to WeChat, and
returns the mutated article (with wechatMediaId filled) + the final thumb id; the
Function persists those back to R2. The only outbound non-WeChat call is fetching
the public cover images from jianshuo.dev/files (no auth).

Reachable ONLY through a Cloudflare Tunnel (cloudflared → 127.0.0.1:PORT); every
request must carry X-Relay-Secret == $WECHAT_RELAY_SECRET (constant-time check).

  POST /publish  {appid, secret, cover_media_ids?, article:{id?, articles:[{title,body,wechatMediaId?}]}}
       -> 200 {ok:true,  article, cover_media_ids, created, updated}
       -> 200 {ok:false, errcode, errmsg}        (a real WeChat error — relayed verbatim)
       -> 401 wrong/absent secret · 400 bad body · 500 unexpected
  GET  /health   -> 200 ok

Env: WECHAT_RELAY_SECRET (required), PORT (default 8848).
"""
import os, re, json, time, struct, zlib, hmac, hashlib, threading, urllib.request
from urllib.parse import quote
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BASE = "https://jianshuo.dev/files/api"
# The relay runs ON the whitelisted IP, so it reaches WeChat directly. WECHAT_PROXY
# stays unset here (it exists only so the same code could run off-box); when unset,
# the WeChat opener is the plain direct opener.
WECHAT_PROXY = os.environ.get("WECHAT_PROXY", "")
RELAY_SECRET = os.environ.get("WECHAT_RELAY_SECRET", "")
PORT = int(os.environ.get("PORT", "8848"))
MAX_BODY = 4 * 1024 * 1024   # 4 MB cap — articles are small

# Disposable global cache of WeChat content-image URLs (a photo uploaded via
# media/uploadimg → its WeChat URL), so re-publishing/voice-editing an article
# doesn't re-upload every photo each time. NOT in the article JSON — just a local
# scratch file on the relay box. Keyed by appid + full photo key (so the URL is
# only reused for the same WeChat account). Entries older than 30 days are treated
# as misses and re-uploaded; each write prunes expired ones, so it never grows
# unbounded. Losing the file just means a one-time re-upload. Env-overridable path.
IMG_CACHE_PATH = os.environ.get("WECHAT_IMG_CACHE", "/opt/wechat-relay/imgcache.json")
IMG_CACHE_TTL = 30 * 24 * 3600   # 30 days
_img_cache_lock = threading.Lock()

# Always go direct (no proxy) with a normal UA when fetching the public covers:
# Cloudflare 403s the default python-urllib UA.
_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))
if WECHAT_PROXY:
    _WECHAT_OPENER = urllib.request.build_opener(
        urllib.request.ProxyHandler({"http": WECHAT_PROXY, "https": WECHAT_PROXY})
    )
else:
    _WECHAT_OPENER = _OPENER  # already on the whitelisted IP — direct is correct

_ERRCODE_RE = re.compile(r"errcode['\"]?\s*[:=]\s*(-?\d+)")
_ERRMSG_RE = re.compile(r"errmsg['\"]?\s*[:=]\s*['\"]([^'\"]*)['\"]")


def log(msg):
    """Wall-clock-stamped progress line, flushed so journald streams live."""
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def _req(method, url, data=None, headers=None):
    h = dict(headers or {})
    h.setdefault("User-Agent", "voicedrop-relay/1")
    req = urllib.request.Request(url, data=data, method=method, headers=h)
    with _OPENER.open(req, timeout=60) as r:
        return r.read()


def _wechat_req(method, url, data=None, headers=None):
    h = dict(headers or {})
    h.setdefault("User-Agent", "voicedrop-relay/1")
    req = urllib.request.Request(url, data=data, method=method, headers=h)
    with _WECHAT_OPENER.open(req, timeout=60) as r:
        return r.read()


# ── WeChat draft publishing ──────────────────────────────────────────────────

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


_PHOTO_LINE_RE = re.compile(r'^\s*\[\[photo:([^\]]+)\]\]\s*$')
_INLINE_PHOTO_RE = re.compile(r'\[\[photo:[^\]]+\]\]')


def md_to_wechat_html(md, photo_url=None):
    """Convert markdown to basic WeChat-compatible HTML with inline styles.

    A standalone `[[photo:<key>]]` line (the in-app inline session photos) becomes a
    centered <img> when `photo_url` is given and resolves the key to a WeChat
    content-image URL. Otherwise — no resolver, or the resolve failed (owner missing,
    photo gone, upload error) — the marker is stripped: a WeChat draft must never carry
    a `[[photo:...]]` marker as literal text. `photo_url` is a callable key -> url|None.
    The key is now a relative photo key (e.g. photos/<ts>/<offset>-<rand>.jpg); old
    numeric `[[photo:N]]` markers don't resolve and are simply stripped."""
    md = re.sub(r'\n{3,}', '\n\n', md)
    lines = md.split('\n')
    parts = []
    list_tag = None  # 'ul' or 'ol'
    for line in lines:
        photo_m = _PHOTO_LINE_RE.match(line)
        if photo_m:
            if list_tag:
                parts.append(f'</{list_tag}>')
                list_tag = None
            url = photo_url(photo_m.group(1)) if photo_url else None
            if url:
                parts.append(
                    f'<p style="text-align:center;margin:1em 0">'
                    f'<img src="{url}" style="max-width:100%;border-radius:4px"/></p>')
            continue
        # Strip any stray inline marker (markers are normally on their own line; a
        # mid-paragraph one can't become a sensible inline image, so drop it).
        line = _INLINE_PHOTO_RE.sub('', line)
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
# uploaded to WeChat once and cached per image name (in WECHAT.json.coverMediaIds,
# which the Function passes in and persists) so docs sharing a cover reuse it.
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
    (the Function persists the cover_media_ids we return)."""
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


def _fetch_photo(owner, relkey):
    """Fetch a session photo's bytes from the PUBLIC photo endpoint (no auth).
    owner = 'users/<sub>/', relkey = 'photos/<ts>/<file>.(jpg|png)'. Returns
    (bytes, content_type), or None if owner is missing / relkey isn't a photo /
    the fetch fails (HTTP error → urllib raises → caught by the caller)."""
    if not owner or not relkey:
        return None
    full = owner.rstrip("/") + "/" + relkey.lstrip("/")   # users/<sub>/photos/<ts>/<file>
    if "/photos/" not in full or not full.lower().endswith((".jpg", ".jpeg", ".png")):
        return None
    raw = _req("GET", f"{BASE}/photo/{quote(full, safe='/')}")
    ct = "image/png" if full.lower().endswith(".png") else "image/jpeg"
    return raw, ct


def wechat_upload_content_image(access_token, img, filename="img.jpg", content_type="image/jpeg"):
    """Upload ONE in-article image via media/uploadimg and return a WeChat URL usable
    inside draft content. media/uploadimg does NOT consume the material-library quota
    (10000/day) — it's the API meant for 图文消息 body images. jpg/png, ≤1MB."""
    boundary = b'VoiceDropImgBoundary42'
    part = (b'--' + boundary + b'\r\n'
            b'Content-Disposition: form-data; name="media"; filename="' + filename.encode("utf-8") + b'"\r\n'
            b'Content-Type: ' + content_type.encode() + b'\r\n\r\n' + img + b'\r\n')
    body = part + b'--' + boundary + b'--\r\n'
    raw = _wechat_req(
        "POST",
        f"https://api.weixin.qq.com/cgi-bin/media/uploadimg?access_token={access_token}",
        data=body,
        headers={"Content-Type": f"multipart/form-data; boundary={boundary.decode()}"},
    )
    result = json.loads(raw)
    if "url" not in result:
        raise RuntimeError(f"WeChat uploadimg error: {result}")
    return result["url"]


def _img_cache_load():
    try:
        with open(IMG_CACHE_PATH, encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}   # missing / corrupt → empty (entries just get re-uploaded)


def img_cache_get(appid, fullkey):
    """Return a still-fresh cached WeChat URL for (appid, fullkey), or None."""
    k = f"{appid}|{fullkey}"
    with _img_cache_lock:
        ent = _img_cache_load().get(k)
    if ent and (time.time() - ent.get("ts", 0)) < IMG_CACHE_TTL:
        return ent.get("url")
    return None


def img_cache_put(appid, fullkey, url):
    """Persist url for (appid, fullkey) and prune expired entries. Atomic replace so a
    crash mid-write can't corrupt the file; failure to persist is non-fatal."""
    k = f"{appid}|{fullkey}"
    now = time.time()
    with _img_cache_lock:
        data = _img_cache_load()
        data = {kk: vv for kk, vv in data.items() if now - vv.get("ts", 0) < IMG_CACHE_TTL}
        data[k] = {"url": url, "ts": now}
        try:
            tmp = IMG_CACHE_PATH + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(data, f, ensure_ascii=False)
            os.replace(tmp, IMG_CACHE_PATH)
        except Exception as e:  # noqa: BLE001 — a cache write must never fail a publish
            log(f"   ⚠ img cache write failed: {str(e)[:120]}")


def make_photo_resolver(access_token, owner, appid):
    """Build a key -> WeChat-content-image-URL resolver for md_to_wechat_html. For each
    referenced session photo: reuse the global 30-day disk cache if present, else fetch
    it from the public endpoint, upload to WeChat once, and cache the URL. An in-memory
    map also dedupes within a single publish (across all articles + the create/update
    retry). A photo failure NEVER breaks publishing — it just drops that one image
    (returns None → md_to_wechat_html strips the marker) and is NOT cached, so the next
    publish retries it."""
    mem = {}

    def resolve(relkey):
        if relkey in mem:
            return mem[relkey]
        fullkey = owner.rstrip("/") + "/" + relkey.lstrip("/") if owner else relkey
        url = img_cache_get(appid, fullkey)
        if url:
            mem[relkey] = url
            return url
        try:
            got = _fetch_photo(owner, relkey)
            if got:
                raw, ct = got
                fname = relkey.rstrip("/").split("/")[-1] or "img.jpg"
                url = wechat_upload_content_image(access_token, raw, filename=fname, content_type=ct)
                img_cache_put(appid, fullkey, url)
                log(f"   🖼 photo embedded: {relkey} → {url[:64]}…")
        except Exception as e:  # noqa: BLE001 — a bad photo must not fail the publish
            log(f"   ⚠ photo embed failed {relkey}: {str(e)[:140]}")
            url = None
        mem[relkey] = url
        return url

    return resolve


def create_wechat_draft(access_token, title, body_md, thumb_media_id, photo_url=None):
    """Create a WeChat draft and return its media_id."""
    content_html = md_to_wechat_html(body_md, photo_url=photo_url)
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


def update_wechat_draft(access_token, media_id, index, title, body_md, thumb_media_id, photo_url=None):
    """Update an existing WeChat draft in place (no new draft). draft/update takes
    a single article object (not a list) at the given index."""
    content_html = md_to_wechat_html(body_md, photo_url=photo_url)
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


def sync_wechat_drafts(access_token, art, thumb_media_id, make_thumb=None, photo_url=None):
    """Push one WeChat draft per article in `art`, mutating each in place.
    An article with a still-valid wechatMediaId is updated where it sits (no
    duplicate); a missing OR stale one (the saved draft was deleted → 40007) is
    created fresh and its id stored back. If creating also 40007s — the cover
    material was wiped — and make_thumb is given, a new cover is uploaded and the
    create retried once. `photo_url` (key->url|None) embeds the body's inline session
    photos as <img>. Returns (created, updated)."""
    created = updated = 0
    for a in art.get("articles", []):
        mid = a.get("wechatMediaId")
        if mid:
            try:
                update_wechat_draft(access_token, mid, 0, a["title"], a["body"], thumb_media_id, photo_url=photo_url)
                updated += 1
                log(f"   ♻ WeChat draft updated: {a['title']} → {mid}")
                continue
            except InvalidMediaIdError:
                log(f"   ⚠ stale draft media_id {mid} → creating a fresh draft")
                a.pop("wechatMediaId", None)
        try:
            new_mid = create_wechat_draft(access_token, a["title"], a["body"], thumb_media_id, photo_url=photo_url)
        except InvalidMediaIdError:
            if not make_thumb:
                raise
            log("   ⚠ cover material invalid → re-uploading cover")
            thumb_media_id = make_thumb()
            new_mid = create_wechat_draft(access_token, a["title"], a["body"], thumb_media_id, photo_url=photo_url)
        a["wechatMediaId"] = new_mid
        created += 1
        log(f"   📩 WeChat draft: {a['title']} → {new_mid}")
    return created, updated


# ── HTTP relay ───────────────────────────────────────────────────────────────

def _wechat_err(exc):
    """Pull a real WeChat {errcode, errmsg} out of a RuntimeError raised above (its
    messages embed the WeChat response dict). Falls back to the raw string."""
    s = str(exc)
    code = _ERRCODE_RE.search(s)
    msg = _ERRMSG_RE.search(s)
    return {
        "errcode": int(code.group(1)) if code else None,
        "errmsg": msg.group(1) if msg else s,
    }


def _publish(payload):
    """Run the synchronous WeChat publish and return the JSON-able result dict."""
    appid = payload.get("appid")
    secret = payload.get("secret")
    article = payload.get("article") or {}
    if not appid or not secret or not isinstance(article.get("articles"), list):
        raise ValueError("missing appid/secret/article.articles")

    token = wechat_access_token(appid, secret)
    # Per-article cover from assets/wechat-covers/, chosen by hash(doc id). The
    # cover->media_id cache lives in WECHAT.json; the Function passes it in and
    # persists whatever we return. No R2 access here — covers are fetched from the
    # public asset route by resolve_cover_thumb.
    cfg = {"coverMediaIds": dict(payload.get("cover_media_ids") or {})}
    doc_id = article.get("id") or ""
    thumb = resolve_cover_thumb(token, doc_id, cfg)
    # Inline session photos: the body carries [[photo:<relkey>]] markers; the Function
    # passes `owner` (= 'users/<sub>/') so we can fetch each photo from the public
    # endpoint and upload it into the draft. Missing owner (old Function) → no embeds,
    # markers stripped, exactly as before.
    photo_url = make_photo_resolver(token, (payload.get("owner") or "").strip(), appid)
    created, updated = sync_wechat_drafts(
        token, article, thumb, photo_url=photo_url,
        make_thumb=lambda: resolve_cover_thumb(token, doc_id, cfg, force=True))
    return {
        "ok": True,
        "article": article,          # mutated in place: each item now has wechatMediaId
        "cover_media_ids": cfg["coverMediaIds"],
        "created": created,
        "updated": updated,
    }


class Handler(BaseHTTPRequestHandler):
    server_version = "wechat-relay/1"

    def _send(self, status, obj):
        body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path == "/health":
            self._send(200, {"ok": True})
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):
        if self.path != "/publish":
            return self._send(404, {"error": "not found"})
        # Auth: constant-time compare of the shared secret.
        got = self.headers.get("X-Relay-Secret", "")
        if not RELAY_SECRET or not hmac.compare_digest(got, RELAY_SECRET):
            return self._send(401, {"error": "unauthorized"})
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = 0
        if length <= 0 or length > MAX_BODY:
            return self._send(400, {"error": "bad content-length"})
        try:
            payload = json.loads(self.rfile.read(length).decode("utf-8"))
        except Exception:
            return self._send(400, {"error": "invalid json"})

        try:
            return self._send(200, _publish(payload))
        except ValueError as e:
            return self._send(400, {"error": str(e)})
        except RuntimeError as e:
            # A real WeChat-side failure — relay the actual errcode/errmsg (HTTP 200,
            # ok:false) so the Function/app can show it.
            return self._send(200, {"ok": False, **_wechat_err(e)})
        except Exception as e:  # noqa: BLE001 — last-resort guard
            return self._send(500, {"error": "relay error", "detail": str(e)[:200]})

    def log_message(self, fmt, *args):
        # Quiet access log; never prints request bodies (which hold creds).
        print(f"[relay] {self.address_string()} {fmt % args}", flush=True)


def main():
    if not RELAY_SECRET:
        raise SystemExit("WECHAT_RELAY_SECRET must be set")
    httpd = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print(f"[relay] listening on 127.0.0.1:{PORT}", flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
