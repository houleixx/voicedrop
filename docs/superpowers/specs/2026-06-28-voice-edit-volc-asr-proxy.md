# Voice-edit dictation → Volcengine streaming ASR via an authenticated proxy

Date: 2026-06-28
Status: re-introduced after rollback (see History)

## Goal

Replace the iOS voice-edit dictation engine (`SpeechDictation` in
`VoiceDropApp/VoiceEdit.swift`) from Apple on-device `SFSpeechRecognizer` to
**Volcengine (火山引擎) bigmodel streaming ASR**, so 语音编辑 transcription matches
the rest of the pipeline (per the standing "ASR 用火山引擎" rule) and gets better
zh-CN accuracy. **The Volcengine credentials must never reach the device** — the
server proxies the streaming WebSocket and injects the credentials.

## Architecture

```
iOS mic → mono 16k PCM → Volc bigmodel binary frames (gzip)
        ──wss──> jianshuo.dev/agent/asr  (auth'd relay, holds creds)
        ──https──> openspeech.bytedance.com/api/v3/sauc/bigmodel
   ← recognition results piped back the same way
```

The **client owns the entire Volcengine wire protocol**; the **server is a dumb
authenticated byte-pipe** that only adds credentials. This keeps the token-secure
boundary crisp: the app holds no Volc secret.

### Server (jianshuo.dev agent worker)

- `agent/src/asr-proxy.js` — `buildVolcAsrRequest` injects `X-Api-App-Key` =
  `VOLC_ASR_APPID`, `X-Api-Access-Key` = `VOLC_ASR_ACCESS_TOKEN` (already
  configured on the worker; mining ASR uses them), resource id
  `volc.bigasr.sauc.duration` (**streaming**, distinct from mining's file
  `volc.bigasr.auc`), random `X-Api-Connect-Id`. `proxyVolcAsrWebSocket` opens
  the upstream WS via `fetch(...).webSocket` and pipes both directions.
- `agent/src/index.js` — route `/agent/asr`: `resolveScope(bearer)` (401 on
  failure), then proxy. The client `Authorization` header is **dropped** before
  the upstream fetch (never forwarded to Volcengine).
- `agent/test/asr-proxy.test.js` — credential injection + Authorization-stripped
  + https assertion.

### Client (voicedrop iOS)

- `VoiceDropApp/VolcASRProtocol.swift` — the Volc bigmodel streaming binary
  protocol: 4-byte header + int32 sequence + uint32 length + gzip payload; builds
  the full-client config + audio-only frames, parses full-server / error frames.
- `VoiceDropApp/VoiceEdit.swift` `SpeechDictation` — `AVAudioEngine` mic tap →
  resample to mono 16k Int16 PCM → stream over a `URLSessionWebSocketTask` to
  `/agent/asr` with `AuthStore.bearer`. `stopAndGetFinal()` waits briefly for the
  tail result.
- `project.yml` — `OTHER_LDFLAGS: -lz` to link zlib for gzip.

## Critical gotcha (baked in)

**CF Workers outbound WebSocket must use an `https://` URL**, not `wss://`. A
`wss://` scheme makes `fetch()` throw `Fetch API cannot load`, so every
connection 500s before reaching Volcengine. The unit test only builds the
`Request` (never fetches), so it cannot catch this — an end-to-end WebSocket
smoke test is the only guard.

## Rollout ordering

Deploy the worker first (so `/agent/asr` exists) → end-to-end smoke test → merge
iOS → TestFlight. A build shipped before the worker route exists would break
voice editing.

## History

This feature first landed as houleixx's two PRs (voicedrop#2 client +
jianshuo.dev#3 server), was verified end-to-end (101 handshake → Volc streaming
resource responds), then **rolled back** at the user's request, then
**re-introduced** here as first-party commits with the https fix integrated from
the start. The git history therefore shows merge → revert → re-add; this doc is
the canonical record so that sequence doesn't confuse a future reader.
