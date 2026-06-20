# Design: `wjs-publishing-appstore` skill

**Date:** 2026-06-20
**Status:** Approved

## Goal

A generic, reusable `wjs-*` skill that takes an iOS app already wired for
TestFlight (via `wjs-publishing-testflight`) the rest of the way to the App
Store: prepare the **screenshots** and the **description/metadata**, then use the
existing **fastlane** setup to **submit for review**.

It is the App Store counterpart to `wjs-publishing-testflight`. That skill owns
build + signing + TestFlight CI. This skill assumes that's done and adds the
storefront listing + an explicit `release` lane. VoiceDrop + Cathier are the
reference implementations. No secrets inlined (auto-publishes to public repo).

## Decisions (from brainstorming)

| Question | Choice |
|----------|--------|
| Screenshots | **Scripted simctl capture** (`scripts/shoot.sh`) — boot sim, install, drive, `simctl io screenshot`; optional `frameit`. No UITest target. |
| Scope | **Generic `wjs-*`** with placeholders (`APP`/`SCHEME`/`BUNDLE_ID`); VoiceDrop/Cathier as worked example. |
| Submit trigger | **Manual lane** (`fastlane release`). `git push` → TestFlight stays as-is; review submission is a deliberate, explicit action. |

## Deliverables (into a target iOS repo)

1. **`fastlane/metadata/`** — `deliver` format. Per-locale `zh-Hans/` + `en-US/`
   with `name/subtitle/description/keywords/promotional_text/release_notes`,
   `support_url/marketing_url/privacy_url`; plus `review_information/`,
   `primary_category.txt`, `copyright.txt`. Scaffolded by
   `scripts/scaffold-metadata.sh`, seeded with editable VoiceDrop copy.
2. **`scripts/shoot.sh`** — scripted simctl capture into
   `fastlane/screenshots/<locale>/`. Default device iPhone 16 Pro Max (6.9",
   the one required size). `drive_screens()` is the editable per-app section.
3. **A `release` fastlane lane** (added next to existing `beta`) — `match`
   readonly → app-store build → `upload_to_app_store` (metadata + screenshots,
   `skip_metadata:false`, `skip_screenshots:false`) → `submit_for_review:true`
   with encryption/IDFA compliance answers; guarded by `guard_not_in_review`.
4. **SKILL.md** — runbook: prerequisites (cross-link `wjs-publishing-testflight`
   + `[[apple-developer-credentials]]`, no secrets re-listed), step order
   (scaffold → write copy → shoot → preview → `fastlane release`), App Store
   Connect first-time gotchas (app record, age rating, privacy nutrition label,
   export compliance), verification checklist.

## Boundaries / YAGNI

- No auto-submit-on-push; no UITest snapshot target; no multi-device matrix
  beyond the single required 6.9" size; `frameit` opt-in only.
- Cross-links `wjs-publishing-testflight` as prerequisite instead of duplicating
  the build/CI Fastfile.
