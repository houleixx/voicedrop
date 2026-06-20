# VoiceDrop

**打开即录音，停止即自动上传——一个口述捕捉器。** 录下来的音频进入 `jianshuo.dev/files`（R2 收件箱），之后在 Mac 上跑 `/wjs-mining-voicedrop` 自动转写并挖成微信公众号草稿。

这个 repo 只装 **iOS App**；Mac 端的处理是一个独立 skill（见下「端到端闭环」）。

---

## 端到端闭环

```
┌─────────────┐   PUT m4a    ┌──────────────────────┐   pull/del   ┌──────────────────────────┐
│ iPhone App  │ ───────────▶ │ jianshuo.dev/files   │ ◀──────────▶ │ Mac: /wjs-mining-voicedrop│
│ (本 repo)   │   带富文件名  │ R2 桶 = 收件箱        │   收件箱进出  │  转写 → 挖文章 → 微信草稿  │
└─────────────┘              └──────────────────────┘              └──────────────────────────┘
   开口即录                    未处理录音暂存于此                      ↓ 复用两个 skill
   停即上传                    (单文件 ≤100MB)              wjs-transcribing-audio (火山豆包 → SRT)
                                                          wjs-mining-articles    (SRT → 草稿)
                                                                    ↓ 落
                                                            ~/code/wechat-publish/
```

**三个独立部分，各自有边界：**

| 部分 | 在哪 | 职责 |
|---|---|---|
| **iOS App** | 本 repo `~/code/voicedrop` | 录音 + 上传，仅此 |
| **文件中转站** | `jianshuo.dev/files`（Cloudflare Pages + R2 桶 `jianshuo-dev-files`，repo `~/code/jianshuo.dev`） | 暂存未处理录音；R2 当「收件箱」 |
| **挖文章 skill** | `~/.claude/skills/wjs-mining-voicedrop` | 拉收件箱 → 转写 → 成文 → 删；成功才删，没成文不删 |

App 不负责 Mac 端任何自动化——录完上传就结束，处理由用户手动跑 skill。

---

## 1. iOS App（本 repo）

### 行为

- 打开 App → 自动开始录音（黑底、计时器、一个大停止钮，没别的）。
- 点停止 → 录音（m4a/AAC，单声道 64kbps）立即 PUT 上传，回到准备录音态。
- 断网/失败 → 录音留在本地待传队列（右上角「↑ N」），下次回前台自动重传。**绝不丢录音。**
- 来电等中断 → 当作一次停止收尾，不丢已录部分。

### 文件名（自描述）

停止时拼出富文件名再上传，便于在收件箱列表里一眼辨认：

```
VoiceDrop-2026-06-18-143052-0m33s-Thu-Afternoon-Shanghai-Xuhui.m4a
└─前缀──┘ └──时间戳───┘ └时长┘ └星期┘└─时段──┘ └──城市-城区──┘
```

- **全 ASCII**（英文地名，去掉所有非字母字符）——URL / R2 key / curl 全程干净。
- **`VoiceDrop-` 前缀 + `.m4a` 后缀不变**——挖文章 skill 靠这两个认领，中间字段随便加。
- 地点 = CoreLocation 粗定位 + CLGeocoder（en locale）反向地理编码，**best-effort、3s 超时、绝不阻塞录音**；拒绝定位/室内无信号就省略地名。
- 录音先落临时名 `VoiceDrop-<时间戳>.m4a`（崩溃也能补传），停止时算时长+反查地点改成富名。

### ⚠️ 跑起来前唯一一步：填 token

上传鉴权用 `jianshuo.dev/files` 的 `FILES_TOKEN`，不在仓库里（已 gitignore）：

```bash
cp Secrets.example.xcconfig Secrets.xcconfig
# 编辑 Secrets.xcconfig，把 REPLACE_ME 换成真实 FILES_TOKEN
```

**token 现存于 `~/code/.env`（`FILES_TOKEN=`）**，与 R2 / Cloudflare Pages secret 同一个（2026-06-18 轮换为 UUID）。不填的话 App 能录能存，但上传提示「缺少 FILES_TOKEN」并排队。详见记忆 `jianshuo-dev-files-transfer`。

### 开发 / 安装

```bash
xcodegen generate                       # 由 project.yml 生成 VoiceDrop.xcodeproj（已 gitignore）
open VoiceDrop.xcodeproj                 # 数据线连真机直接 Run（最简单）
```

- **必须真机**：模拟器没有麦克风，录出来永远是 -91dB 纯静音（转写为空、挖不出文章）。要测整条链路，用物理 iPhone 录有声内容。
- 模拟器只能验证 UI / 编译：
  ```bash
  xcodebuild -project VoiceDrop.xcodeproj -scheme VoiceDrop \
    -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
  ```
- TestFlight（照搬 `~/code/drop` 的签名，需 App Store Connect API key）：`bundle exec fastlane beta`
- 渐变图标可重生成：`python3 scripts/make_icon.py VoiceDropApp/Assets.xcassets/AppIcon.appiconset/icon-1024.png`

### 代码结构

| 文件 | 作用 |
|---|---|
| `VoiceDropApp/VoiceDropApp.swift` | `@main` 入口 |
| `VoiceDropApp/ContentView.swift` | 单屏状态机（requesting/recording/uploading/done/failed），停止时编富名+改名+上传 |
| `VoiceDropApp/AudioRecorder.swift` | AVAudioRecorder 封装：录临时名 m4a、计时、中断处理；停止返回 `Recording`(url/start/duration) |
| `VoiceDropApp/Uploader.swift` | PUT 上传到 files API；Documents 目录即待传队列；前台重传 |
| `VoiceDropApp/RecordingName.swift` | 纯 Foundation 的富文件名构造（时间戳/时长/星期/时段），可单测 |
| `VoiceDropApp/LocationTagger.swift` | CoreLocation 粗定位 + CLGeocoder 英文反向地理编码（3s 超时） |
| `project.yml` | XcodeGen 工程定义（bundle `com.wangjianshuo.VoiceDrop`，team `97XBW2A43H`，iOS 26 / Swift 6） |
| `Secrets.xcconfig` | `FILES_TOKEN`（gitignore，本地）；`Secrets.example.xcconfig` 是占位模板 |
| `scripts/make_icon.py` | 渐变 App 图标生成器 |
| `docs/superpowers/specs/` | 设计文档（单一事实源） |

---

## 2. 处理录音（Mac 端）

在 Mac 上跑 skill 把收件箱里的录音变成草稿：

```
/wjs-mining-voicedrop
```

它做：列收件箱（`VoiceDrop-*.m4a`）→ 对每条**串行**地下载存档(`~/code/voicedrop/archive/`) → 转写(火山豆包) → 交 `wjs-mining-articles` 出选题清单(人工勾选)→ 成文 → 建微信草稿 → **成功才从 R2 删**。

**删除安全红线**：`download(存档) → transcribe → mine → 出了草稿 → 才 delete`。任何一步失败/没勾选/没成文 → 不删，留收件箱下次再来。先存档后删，音频永不丢。

skill 自带一个收件箱小工具（也可手动用）：

```bash
~/.claude/skills/wjs-mining-voicedrop/scripts/voicedrop-inbox.sh list           # 列未处理
~/.claude/skills/wjs-mining-voicedrop/scripts/voicedrop-inbox.sh download <name> <dir>
~/.claude/skills/wjs-mining-voicedrop/scripts/voicedrop-inbox.sh delete <name>   # 仅成功后
```

---

## 给未来 agent 的指北

- **改 App 行为** → 这个 repo。设计的单一事实源是 `docs/superpowers/specs/2026-06-18-voicedrop-design.md`，先读它。
- **改处理流程 / 收件箱进出** → skill `~/.claude/skills/wjs-mining-voicedrop/`（注意：wjs-* skill 会自动同步到公开 repo，**token 绝不进代码**，运行时从 `~/code/.env` 读）。
- **改文件中转站本身**（鉴权 / 路由 / R2） → `~/code/jianshuo.dev`，函数在 `functions/files/api/[[path]].js`，Pages 项目名 `jianshuo-dev`。
- **token 在哪** → `~/code/.env` 的 `FILES_TOKEN`，与 Cloudflare Pages secret 同值；轮换见记忆 `jianshuo-dev-files-transfer`。
- **后台/隔离**：本 repo 是 git 仓库，后台 agent 改代码前先 `EnterWorktree`。
- **已知坑**：模拟器无麦克风 → 录音恒为 -91dB 静音；`CLGeocoder` 在 iOS 26 标记 deprecated（仍可用，将来可迁 `MKReverseGeocodingRequest`）。
- **相关**：`~/code/drop` / `~/code/DuduCam`（同款 XcodeGen+fastlane iOS 工程，可参照签名/发布）。

仓库：https://github.com/jianshuo/voicedrop （private）
