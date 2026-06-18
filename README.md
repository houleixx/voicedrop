# VoiceDrop

打开即录音，停止即自动上传到 `jianshuo.dev/files`。一个口述捕捉器——录下来的音频后续可在 Mac 上手动跑 `/wjs-transcribing-audio` → `/wjs-mining-articles` 变成公众号草稿。

## 它做什么

- 打开 App → 自动开始录音（黑底、计时器、一个大停止钮，没别的）。
- 点停止 → 录音（m4a/AAC）立即 PUT 上传到 `https://jianshuo.dev/files/api/upload/<VoiceDrop-时间戳.m4a>`。
- 上传成功回到准备录音状态，可马上录下一条。
- 断网/失败 → 录音留在本地待传队列（右上角显示「↑ N」），下次回前台自动重传。**绝不丢录音。**

## ⚠️ 跑起来前的唯一一步：填 token

上传鉴权用 `jianshuo.dev/files` 的 `FILES_TOKEN`。它不在仓库里（已 gitignore）。

```bash
cp Secrets.example.xcconfig Secrets.xcconfig   # 仓库里已放了一份占位的 Secrets.xcconfig
# 编辑 Secrets.xcconfig，把 REPLACE_ME 换成真实 FILES_TOKEN
```

token 来源见记忆 `jianshuo-dev-files-transfer`（它是 Cloudflare Pages secret，本体不落盘；忘了就轮换）。不填的话 App 能录、能存，但上传会提示「缺少 FILES_TOKEN」并留在待传队列。

## 开发 / 安装

```bash
xcodegen generate          # 由 project.yml 生成 VoiceDrop.xcodeproj（已 gitignore）
open VoiceDrop.xcodeproj    # 用数据线连真机直接 Run（最简单）
```

模拟器只能验证 UI（无真实麦克风输入）：

```bash
xcodebuild -project VoiceDrop.xcodeproj -scheme VoiceDrop \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

TestFlight（照搬 drop 的签名，需 App Store Connect API key）：

```bash
bundle exec fastlane beta
```

## 图标

`scripts/make_icon.py` 纯 stdlib 生成珊瑚橘→深紫的对角渐变 1024 PNG，可随时重生成：

```bash
python3 scripts/make_icon.py VoiceDropApp/Assets.xcassets/AppIcon.appiconset/icon-1024.png
```

## 结构

| 文件 | 作用 |
|---|---|
| `VoiceDropApp/VoiceDropApp.swift` | `@main` 入口 |
| `VoiceDropApp/ContentView.swift` | 单屏状态机（录音/上传/完成/失败） |
| `VoiceDropApp/AudioRecorder.swift` | AVAudioRecorder 封装，m4a、计时、中断处理 |
| `VoiceDropApp/Uploader.swift` | PUT 上传 + Documents 目录即待传队列 |
| `Secrets.xcconfig` | FILES_TOKEN（gitignore，本地） |
| `project.yml` | XcodeGen 工程定义 |
| `docs/superpowers/specs/` | 设计文档 |

设计文档见 `docs/superpowers/specs/2026-06-18-voicedrop-design.md`。
