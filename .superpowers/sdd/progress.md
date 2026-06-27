# Voice-edit durable queue — SDD progress ledger

Plan: docs/superpowers/plans/2026-06-27-voice-edit-durable-queue.md
Phase A repo+worktree: ~/code/jianshuo.dev/.claude/worktrees/voice-edit-durable-queue (branch voice-edit-durable-queue, base b856856)
Phase B repo+worktree: ~/code/voicedrop/.claude/worktrees/voice-edit-durable-queue (branch worktree-voice-edit-durable-queue)
Deploy/push: DEFERRED to user (active WIP in both repos; outward-facing).

## Tasks
- [x] A1 queue.js durable queue module
- [ ] A2 write_article stamps lastEditId
- [ ] A3 edit-turn.js runEditTurn (HARDENED: runEditTurn must re-check lastEditId — see Minor note)
- [ ] A4 ArticleEditor DO wiring
- [ ] B1 EditQueueStore.swift
- [ ] B2 AgentSession.swift rewrite
- [ ] B3 RecordingDetailView onDisappear

## Minor findings (for final review triage)
- A1: best-effort loadDoc → narrow double-apply window (crash after write+stamp, then transient read blip on replay) UNLESS runEditTurn (A3) re-checks lastEditId. RESOLUTION: A3 hardened to re-check lastEditId at the top of runEditTurn (plan updated). Verify closed after A3.

## Completed
- A1: complete (commits fadfe43..1365aaf, review clean; queue 9/9, full suite 96/96 pristine)
