# Voice-edit durable queue — SDD progress ledger

Plan: docs/superpowers/plans/2026-06-27-voice-edit-durable-queue.md
Phase A repo+worktree: ~/code/jianshuo.dev/.claude/worktrees/voice-edit-durable-queue (branch voice-edit-durable-queue, base b856856)
Phase B repo+worktree: ~/code/voicedrop/.claude/worktrees/voice-edit-durable-queue (branch worktree-voice-edit-durable-queue)
Deploy/push: DEFERRED to user (active WIP in both repos; outward-facing).

## Tasks
- [x] A1 queue.js durable queue module
- [x] A2 write_article stamps lastEditId
- [x] A3 edit-turn.js runEditTurn (HARDENED: self-idempotency guard — verified present + tested)
- [x] A4 ArticleEditor DO wiring  (Phase A code-complete; A5 deploy deferred to user)
- [x] B1 EditQueueStore.swift
- [ ] B2 AgentSession.swift rewrite
- [ ] B3 RecordingDetailView onDisappear

## Minor findings (for final review triage)
- A1: best-effort loadDoc → narrow double-apply window (crash after write+stamp, then transient read blip on replay) UNLESS runEditTurn (A3) re-checks lastEditId. RESOLUTION: A3 hardened to re-check lastEditId at the top of runEditTurn (plan updated). Verify closed after A3.

- A2 (Minor): no negative-path test that absent editId → no lastEditId stamp. Cheap; protects the backward-compat Global Constraint. Final review: add `omits lastEditId when ctx.editId is absent` to tools.test.js (or fold into a Minor cleanup wave).

## Completed
- B1: complete (commit 8e6ea35, review clean Approved; BUILD SUCCEEDED). Minor→final: silent encode-failure path in save() (theoretical only for two Strings).
- A1: complete (commits fadfe43..1365aaf, review clean; queue 9/9, full suite 96/96 pristine)
- A2: complete (commit 5723c1a, review clean Approved; tools 18/18, full suite 97/97 pristine; 2 ⚠️ resolved by controller: fakeFetch import pre-exists; writeArticleDoc {...rest} preserves lastEditId — verified in article-store.js)
- A3: complete (commit 28e8563, review clean Approved; edit-turn 3/3, full suite 100/100 pristine; self-idempotency guard verified present+tested). Minors→final: missing-doc test could assert hadError+article:null; idempotency test could assert reply==="".
- A4: complete (commit 6f11d30, review clean Approved; full suite 100/100, node --check src/index.js OK, _busy 0 refs; backward-compat verified). Minors→final cleanup wave: (1) drop dead import resolveArticles (index.js:22); (2) drop dead import runAgentLoop (index.js:18); (3) append .catch(()=>{}) to onConnect snapshot IIFE.
