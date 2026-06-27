# Voice-edit durable queue — never-drop, always-resume

Date: 2026-06-27
Status: approved design, ready for implementation plan

## Problem

Voice editing of a mined article must not be lost when the connection drops, the
app is backgrounded, or the app is killed. Today an interrupted edit can be lost,
double-applied, or silently dropped — and queued-but-unsent instructions vanish
when the app dies. The requirement: **for any interruption reason (网络断 / 切后台 /
app 被杀), no instruction is lost, none is applied twice, and the next time the
app comes back it continues.**

## Current flow (baseline) and why it breaks

```
app enqueue → in-memory queue → WS send {type:"instruct", text} →
  ArticleEditor DO onMessage: _busy=true (in-memory), runAgentLoop, write R2,
  send {updated} + {reply}, record history, _busy=false →
  app receives {updated} → drops queue head → pumps next
```

Relevant code:
- `voicedrop/VoiceDropApp/AgentSession.swift` — `ArticleAgentSession` (in-memory queue, 1.5s auto-reconnect, **re-sends the in-flight instruction on reconnect**).
- `voicedrop/VoiceDropApp/RecordingDetailView.swift` — connects on `.task` / `connectIfNeeded()`, **disconnects on `.onDisappear`** (clears queue). No `scenePhase` handling → no background keep-alive.
- `jianshuo.dev/agent/src/index.js` — `ArticleEditor` Durable Object. `config`/`history` persist in SQLite; **`_busy` is in-memory**. WebSocket Hibernation keeps `config`/`history` across hibernation.

Three concrete failure modes (verified against the code):

1. **断网 / 切后台 (socket dies, app alive).** The DO finishes and **writes the
   article to R2** (result persisted), but the `{updated}` push is lost, so the
   app never removes the queue head. On reconnect, `openSocket()` does
   `if !queue.isEmpty { processing=false; pump() }` → **re-sends the same
   instruction** → the DO applies it **a second time** (double-apply). If the DO
   is still busy, the re-send gets `{type:"error","正在修改，请稍候"}` →
   `failHead()` **drops the instruction** even though it is completing.
2. **app killed (mid-edit).** The in-flight one finishes server-side, but the
   app's in-memory `queue` is gone → any **queued-but-unsent** instructions are
   lost, and on relaunch there is no "continue".
3. **DO evicted mid-loop (before the R2 write).** The instruction has no durable
   record anywhere → lost entirely.

Root cause: **queue authority lives in client memory**; there is no durable
server-side queue and no idempotency key.

## Approach: the Durable Object owns a durable queue (server-authoritative)

Move queue authority into the `ArticleEditor` DO. The client becomes a thin
submitter + renderer. The DO:

- persists every instruction in a SQLite `queue` table (survives hibernation/
  eviction, same mechanism as the existing `config`/`history` tables),
- drains the queue with `this.schedule()` (a durable scheduled task that runs
  **even when no client is connected**) — so queued edits complete regardless of
  network / background / kill,
- dedups by a **stable instruction id** so a reconnect re-send returns the cached
  result instead of re-applying,
- broadcasts state to any connected client and sends a **snapshot on connect** so
  reconnect / relaunch reconciles the UI.

`agents` SDK capabilities used (confirmed present in the installed `agents`
package): `this.sql`, `this.schedule(seconds, "methodName", payload)` /
`getSchedules` / `cancelSchedule`, `this.broadcast(message)`,
`this.getConnections()`, `onConnect(connection, ctx)`, `onMessage`.

## Design

### 1. Data model — new SQLite table in `ArticleEditor`

```sql
CREATE TABLE IF NOT EXISTS queue (
  id         TEXT PRIMARY KEY,  -- client-supplied stable UUID; server fills srv-<ts>-<rand> if absent (old clients)
  seq        INTEGER,           -- monotonic FIFO order (max(seq)+1 on insert)
  text       TEXT,
  images     TEXT,              -- JSON [{key,data,mediaType}], nullable
  status     TEXT,              -- 'pending' | 'running' | 'done' | 'error'
  reply      TEXT,              -- the one-line reply the user saw (cached for idempotent replay)
  error      TEXT,
  created_at INTEGER,
  updated_at INTEGER
)
```

`config` (articleKey/scope/token) and `history` (instruction↔reply cross-turn
memory) are **unchanged**. `history` is still written on each completed turn, so
the model keeps cross-turn context exactly as today.

The article doc gains one optional top-level field **`lastEditId`** (the id of
the instruction that produced the current doc) — used for crash-safe
exactly-once (see §4). Written via the existing article-store write path; old
docs without it are treated as `lastEditId: null`.

### 2. Idempotency (the "never apply twice" core)

On `instruct`, look up the row by `id` first:

| existing row status | action |
|---|---|
| (none) | insert `pending`, schedule a drain |
| `done` | **do not re-run**; re-send the cached `{updated}` (current doc) + `{reply}` to the caller |
| `pending` / `running` | already queued/running; no-op (no duplicate row) |
| `error` | re-send the cached `{error}`; a real retry comes as a **new id** |

Client-supplied `id` is the existing `EditRequest.id` (`let id = UUID()`), now
put on the wire. Old clients send no id → the server synthesizes one, so they
process normally but get no dedup (degraded, never worse than today).

### 3. Drain loop (the "finishes even when the app is closed" core)

- `enqueue(row)`: insert `pending`; if not currently draining, `this.schedule(0,
  "drain")`.
- `drain()`:
  1. pick the `pending` row with the smallest `seq`; if none → stop (clear the
     draining marker).
  2. **crash-safe skip**: if `doc.lastEditId === row.id` (this instruction already
     produced the current doc), mark `done` (cache reply if available) and go to
     the next — never re-run.
  3. mark `running`; `broadcast {type:"status", state:"working", id}`.
  4. run the existing `runAgentLoop` (load doc + `history` + images), tools write
     R2; on a terminal write, stamp `doc.lastEditId = row.id`.
  5. on success: read back the final doc; mark row `done` + cache `reply`; insert
     into `history`; `broadcast {type:"updated", id, article}` + `{type:"reply",
     id, text, ok}`.
  6. on error: mark `error` + cache message; `broadcast {type:"error", id,
     message}`. **Continue** to the next row (one failure never blocks the queue).
  7. loop to (1).
- Only **one** drain runs at a time (in-memory `_draining` guard + single
  scheduled "drain" task; `getSchedules` prevents duplicates).
- **Crash recovery**: `onStart` re-arms — if any `pending` rows exist, or a
  `running` row is left over (the DO died mid-run), reset that `running` row to
  `pending` and `this.schedule(0, "drain")`. The §3.2 `lastEditId` check makes a
  reset-and-retry safe even if the DO died in the window *after* the R2 write but
  *before* marking `done` (exactly-once effect).

### 4. Crash consistency — exactly-once effect

R2 and the DO's SQLite are two stores with no shared transaction, so a crash
between "wrote R2" and "marked done" could otherwise re-apply on retry. The
`lastEditId` stamp closes this: a terminal write stamps the doc with the current
`row.id`; before running any row, drain checks whether the doc already carries
that id and skips the model call if so. Result: each instruction's *effect* lands
at most once, even across DO eviction mid-run.

(Cloudflare keeps a DO alive while a request/scheduled task is actively
executing; eviction happens when idle, so this window is rare — `lastEditId` is
the belt-and-suspenders guarantee, not the common path.)

### 5. Protocol — strictly additive (backward compatibility, the hard constraint)

The server deploys independently and immediately; the moment it ships, **every
already-installed app (mine + beta testers) talks to the new server** while the
app updates only via a new TestFlight build. So **old app + new server must
coexist**. Rules:

**Unchanged (old clients keep working):**
- WS path `/agent/edit?stem=<stem>`, `Authorization: Bearer` handshake, auth/scoping.
- Inbound `{type:"instruct", text, images?}` still accepted as-is.
- Outbound `{type:"status"}`, `{type:"updated", article}`, `{type:"reply", text, ok}`,
  `{type:"error", message}` keep their existing shape.

**Additive (new clients use; old clients ignore unknown fields / types):**
- `instruct` may carry `id` (optional). When absent, server synthesizes one.
- `updated` / `reply` / `error` / `status` may carry an extra `id` field
  identifying which queued instruction they resolve.
- New `{type:"snapshot", article, queue:[{id, text, status}]}` sent on connect —
  old clients hit `default: break` in `handle()` and ignore it.

**Behavior change that only improves old clients:** the `_busy` →
`{type:"error","正在修改，请稍候"}` path (which made old clients drop the
instruction) is replaced by enqueue. Old clients simply wait for `{updated}`
instead of dropping — strictly safer than today.

**Old app + new server net effect:** connects fine, never crashes, behaves like
today (a reconnect re-send may still double-apply because the old client puts no
id on the wire) — **no regression**. Full no-drop / no-dup / resume guarantees
activate once the new build ships.

### 6. App-side changes (new build — unlocks the full guarantee)

`voicedrop/VoiceDropApp/AgentSession.swift` + `RecordingDetailView.swift`:

1. Put `EditRequest.id` on the wire in the `instruct` payload.
2. **Persist the un-acked queue to disk**, keyed by stem (a small JSON file /
   `UserDefaults` entry), so an app kill survives. On reopening the article,
   re-submit pending ids (the server dedups).
3. On connect, handle `{type:"snapshot"}`: reconcile the local queue against
   server truth — drop ids the server reports `done`, keep `pending`/`running`
   shown as in-flight, surface a final `done` doc that arrived while away.
4. Stop clearing the queue on disconnect; **clear only on explicit user exit**
   (not on transient `.onDisappear` caused by backgrounding).
5. Route `updated`/`reply`/`error` by `id` to the matching queue item (not just
   `queue.first`), since out-of-order / replayed results can arrive.

App protocol and `SpeechDictation` are otherwise unchanged.

### 7. Out of scope (YAGNI)

- No change to the tool set, the agent loop, or the owner-voice prompt.
- No background URLSession / push-to-resume — "resume on next open" is the
  contract; the server finishing on its own covers the "walked away" case.
- No multi-device live cursor; broadcast to whatever clients happen to be
  connected is enough.
- No per-instruction cancel UI (a future add; the queue table can support it).

## Testing

Worker unit tests (`jianshuo.dev/agent/test/`, vitest + `fakes.js`):

- **enqueue + FIFO**: rows drain in `seq` order; `drain` empties the queue.
- **idempotent re-submit**: submitting the same `id` after `done` returns the
  cached `{updated}`+`{reply}` and **does not** run the agent loop a second time
  (assert the mock `callClaude` call count).
- **crash recovery**: a leftover `running` row on `onStart` is reset to `pending`
  and retried; with `doc.lastEditId === id` the retry **skips** the model call
  (exactly-once).
- **error does not block**: an erroring row is marked `error` and the next
  `pending` still drains.
- **backward compat**: an `instruct` with **no id** is processed (server
  synthesizes an id); existing `updated`/`reply`/`error` shapes still emitted.
- **snapshot**: `onConnect` (or first message) yields `{type:"snapshot"}` with the
  current article + queue states.
- Existing `loop.test.js` / `tools.test.js` / `article-store.test.js` stay green
  (the loop and tools are unchanged).

Manual end-to-end:
- Speak an edit, kill the app mid-run → reopen → the edit is applied exactly once,
  no duplicate.
- Queue 3 edits, background the app immediately → reopen later → all 3 applied in
  order, none duplicated.
- Old build (before this app change) against the new server → still edits, still
  connects, no crash.

## Deploy order

1. **Server first**: `cd ~/code/jianshuo.dev/agent && npm test` (green) →
   `npx wrangler deploy`. Backward compatible — installed apps keep working.
2. **App next**: regenerate via xcodegen, build, push `main` → TestFlight. This
   build unlocks the full no-drop / no-dup / resume guarantee.

(`jianshuo.dev` Pages is not touched; only the `voicedrop-agent` Worker and the
iOS app change.)
