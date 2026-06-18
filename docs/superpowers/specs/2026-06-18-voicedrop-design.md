# VoiceDrop — 设计文档

> 2026-06-18 · 作者：王建硕 + Claude

## 一句话

打开 iPhone App 即开始录音，点停止即自动把录音上传到 `jianshuo.dev/files`。结束。Mac 端的转写、挖文章由用户**手动**跑（`/wjs-transcribing-audio` → `/wjs-mining-articles`），不在本 App 范围内。

## 背景与范围

最初设想是端到端全自动（录音→上传→自动触发 Mac 生成公众号草稿）。讨论后**主动收窄**：iPhone 只负责「录音 + 上传」，Mac 侧处理保持手动。砍掉自动触发后不再需要常驻进程 / Worker 改动 / Durable Object，范围干净。

**做：** 录音（m4a）、停止即上传、断网本地重传、渐变 App 图标。
**不做（YAGNI）：** Mac 端任何自动化、已录列表/播放/剪辑/波形、账号、设置页、多 token 切换。

## 用户流程

1. 打开 App → 首次弹麦克风权限 → 授权后**立即开始录音**。
2. 极简界面：黑底，中间走动的计时器 `00:23`，下方一个大号 **停止** 圆钮。无其它元素。
3. 点停止 → 立即 PUT 上传到 `https://jianshuo.dev/files/api/upload/<文件名>`。
4. 上传中转圈 → 成功显示 `已上传 ✓` → **回到准备录音状态**（露出开始钮，可马上录下一条）。
5. 上传失败（断网等）→ 录音留在本地待传队列，UI 显示「待上传 N」，下次进入前台自动重传。**绝不丢录音。**

## 架构（组件 + 边界）

| 组件 | 职责 | 依赖 |
|---|---|---|
| `VoiceDropApp` | `@main` 入口，承载 `ContentView`；前台时触发重传 | SwiftUI |
| `ContentView` | UI 状态机：`idle → recording → uploading → done/failed`；驱动录音与上传 | `AudioRecorder`, `Uploader` |
| `AudioRecorder` | 封装 `AVAudioRecorder`：请求权限、开始/停止、输出 m4a 文件 URL、暴露计时；处理中断 | AVFoundation |
| `Uploader` | PUT 上传到 files API；维护本地待传队列（Documents 目录扫描）；前台重传 | URLSession, Foundation |
| `Secrets.xcconfig` | 注入 `FILES_TOKEN` + `FILES_BASE_URL`（gitignore，不进 repo）；编译进 Info.plist，运行时读 | 构建配置 |
| `AppIcon` | 渐变色块图标（脚本生成 1024 PNG） | Assets.xcassets |

### 数据流

```
麦克风 ──AVAudioRecorder──> Documents/VoiceDrop-YYYY-MM-DD-HHMMSS.m4a
                                    │ 停止
                                    v
                     Uploader.upload(file)
                                    │
              PUT /files/api/upload/<name>  (Authorization: Bearer FILES_TOKEN)
                    │成功                       │失败
                    v                           v
              删除本地文件 + UI「已上传✓」   留在 Documents, 前台重试
```

待传队列 = Documents 目录里所有 `VoiceDrop-*.m4a` 文件。上传成功即删除；没删的就是待传。无需单独索引文件。

## 关键决定

| 项 | 决定 | 理由 |
|---|---|---|
| 录音格式 | m4a/AAC（44.1k/单声道/~64kbps，语音够用） | iOS 原生，无需 LAME；Mac 转写直接吃 m4a，需 mp3 再 ffmpeg |
| 文件名 | `VoiceDrop-YYYY-MM-DD-HHMMSS.m4a` | 可读、可排序、秒级唯一、桶里好认 |
| 上传鉴权 | `FILES_TOKEN` 走 `Secrets.xcconfig` → Info.plist → 运行时读 | 私有自用 App 可接受 token 编译进二进制；**绝不进公开 repo**；example 文件占位 |
| 上传端点 | 复用现有 `jianshuo.dev/files`（R2 + Pages Functions），单文件 ≤100MB | 零新基建 |
| 失败处理 | Documents 目录即待传队列 + 前台自动重传 | 绝不丢录音，无额外状态文件 |
| 录音中来电/中断 | `AVAudioSession` 中断通知：停止并当作一次「停止」收尾（保存待传） | 不丢已录部分 |
| 安装 | XcodeGen 工程，照搬 `drop` 的 fastlane/签名（team `97XBW2A43H`）；数据线直跑或 TestFlight | 复用现成流水线 |
| 代码位置 | 新私有 repo `~/code/voicedrop` | 隔离，token 安全 |
| 图标 | 脚本渲染渐变（珊瑚橘→深紫对角）1024 PNG，单尺寸 AppIcon | 比默认占位强，确定性、可重生成 |

## 错误处理

- **无麦克风权限**：显示一句说明 + 「去设置」按钮；不崩。
- **上传 401/403**：标记 token 失效，UI 提示；文件留队列，指数退避，不狂试。
- **网络错误/超时**：留队列，下次前台重试。
- **磁盘写失败**：极少；提示并不开始录音。

## 测试

- 工程能 `xcodegen generate` 且 `xcodebuild`（模拟器）编译通过 = 最低验收线。
- 手动：真机录一段 → 停止 → 确认 `jianshuo.dev/files` 列表里出现该文件 → 开飞行模式录一段确认进待传队列、关飞行模式回前台自动补传。
- 音频录制需真机/麦克风，单元测试不强求。

## 明确不在本期

- Mac 端自动触发与 headless claude 流水线（用户手动跑）。
- 录音管理 UI、波形、剪辑、转写预览。
