# App Review 回信（Submission 30458391-cfe9-4ace-aa72-e8a25b6ae910，2026-07-06 被拒三条）

回信正文（贴到 App Store Connect 的 Reply 框，英文）——发送前把 `build ___` 替换成新 build 号：

---

Hello,

Thank you for the detailed review. We have addressed all three issues. Please review the new build (1.0, build ___).

**Guideline 5.1.1(v) — Account deletion**

Account deletion is now fully supported in-app: Settings (设置) → Account (账户) → Delete Account (删除账户). After an explicit confirmation dialog, the account and ALL associated data are permanently and immediately erased on our servers — recordings, transcripts, articles, photos, settings, community posts, public share links, and the Sign in with Apple binding — and the app resets to a brand-new empty state. It is a complete deletion, not a deactivation, and no customer-service step is involved. A screen recording of the complete flow (sign in → navigate to the option → delete → confirmation) captured on a physical device is attached in the App Review notes.

**Guideline 1.2 — User-Generated Content**

All required precautions are in place, and the app's age rating has been set to 18+:

- Age rating: 18+.
- Terms (EULA): before a user's FIRST community post they must agree to the community agreement (社区公约 / EULA), which states zero tolerance for objectionable content and abusive users.
- Filtering: when a user shares an article to the community, the server automatically screens the full text and rejects objectionable content.
- Flagging: every community post has a Report (举报) action in its ⋯ menu.
- Blocking: every community post has a Block this user (屏蔽此用户) action; blocked users can be managed in Settings → 已屏蔽用户.
- Immediate removal: reporting a post removes it from the public feed IMMEDIATELY (hidden pending review), and owners can unshare their own posts instantly.
- 24-hour action: reports enter our moderation queue; we remove offending content and eject the offending user within 24 hours.
- Contact information: Settings → 联系我们 / 内容投诉 (jianshuo@hotmail.com) is available inside the app for reporting inappropriate activity.

**Guideline 2.5.4 — Background audio**

VoiceDrop is a voice-dictation recorder. The "audio" value in UIBackgroundModes is used for background audio RECORDING — a documented use of this mode — not playback. Users start a recording and then lock the screen or return to the Home Screen while continuing to dictate; without the audio background mode the recording would be cut off the moment the phone locks. The app also provides a "Start recording" App Shortcut that begins recording from the Lock Screen / Action button. A screen recording captured on a physical device is attached: it shows a recording in progress, the user going to the Home Screen and locking the phone while continuing to speak, and the finished recording (with its transcript) containing the speech spoken while the app was in the background.

Thank you very much for your time!

---

## 发送前 checklist（人肉步骤）

1. **年龄分级 18+**：App Store Connect → App → App 信息/年龄分级 → 设为 18+（或用 ASC API 改 ageRatingDeclaration）。回信里已宣称 18+，务必先改好。
2. **真机录屏 ①（删号）**：真机上：登录/新装 → 设置 → 账户 → 删除账户 → 确认 → 回到全新状态。整段录屏。
3. **真机录屏 ②（后台录音）**：开始录音 → 回主屏幕（画面里能看到 Home Screen + 灵动岛/状态栏录音指示）→ 锁屏继续说话 → 回 app 停止 → 显示这条录音（转写含后台说的话）。整段录屏。
4. 两段录屏传到 App Review Information 的 Notes 附件（或回信附件）。
5. 新 build（CI 自动出）在 TestFlight 就绪后，按 STATE.md 的 resubmit playbook 把 version 挂新 build 重新提交，回信里填上 build 号。
