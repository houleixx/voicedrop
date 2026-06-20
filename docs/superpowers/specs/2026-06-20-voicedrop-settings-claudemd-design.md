# VoiceDrop — Settings tab (name + style) → per-user CLAUDE.md prompt

Date: 2026-06-20

A Settings tab where the user sets their **name** and **style** (pasted distilled
text). Saved as `users/<sub>/CLAUDE.md` in R2 via the existing upload endpoint.
The server miner appends that CLAUDE.md after the system prompt when calling the
Claude API, so each user's articles come out in their own voice.

## Storage — CLAUDE.md only

One file per user: `users/<sub>/CLAUDE.md`, written/read through the existing
authenticated `PUT/GET /files/api/upload|download/CLAUDE.md` (no backend change).
Fixed, round-trip-safe format — 文风 is the last, greedy section so markdown
headings inside the style text can't break parsing:

```
# 我的名字
<name>

# 我的文风
<style — everything to end of file>
```

Parse on load: `name` = text between `# 我的名字` and `# 我的文风`; `style` =
everything after `# 我的文风`. If the markers are absent (hand-edited file),
`name` = "" and `style` = whole content (best-effort, never crashes).

## App — third "设置" tab

- `RootView`: add a third `Tab("设置", systemImage: "gearshape")` → `SettingsView`.
- `SettingsView`: a `Form`/`List` (dark theme to match) with
  - **名字** — `TextField` (single line).
  - **文风** — a multi-line `TextEditor` (paste distilled style), with a hint.
  - **保存** button → composes CLAUDE.md, `PUT`s it; shows saved/last-error state.
- `SettingsStore` (`@Observable`): `load()` (GET CLAUDE.md, parse) on first appear;
  `save(name:style:)` (compose + PUT). Uses `AuthStore.shared.bearer` and the same
  `https://jianshuo.dev/files/api` base as `LibraryStore`. 404 on load = no settings
  yet (empty fields, not an error).

## Server — mine.py

- New helper `fetch_claude_md(audio_key)`: derive the `users/<sub>/` prefix (same
  split as `_stem_keys`) and `api_download` `<prefix>CLAUDE.md`; return its text or
  "" (404 → "").
- In the per-recording loop, fetch it once and pass to `generate_articles`, which
  sets `system = SYSTEM + "\n\n---\n\n" + claude_md` when non-empty. Log
  `+ CLAUDE.md (<n> chars)` so the run shows it was applied.
- Append-after-system matches the user's "放在 PROMPT 的后面" intent: the per-user
  name/style layers on top of the base voice prompt.

## Out of scope (v1)

- No settings.json sidecar (CLAUDE.md is the single source).
- No per-article style override; one CLAUDE.md per user.
- The Mac skill (`wjs-mining-voicedrop`) is unchanged — this is the server miner.

## Verification

- App builds; the 设置 tab saves → `curl` GET `/files/api/download/CLAUDE.md`
  (user token) returns the composed file; reopening the tab reloads the fields.
- `mine.py` MINE_DRY/unit: with a CLAUDE.md present for a user, the system prompt
  passed to the API includes it (log line shows the char count).
