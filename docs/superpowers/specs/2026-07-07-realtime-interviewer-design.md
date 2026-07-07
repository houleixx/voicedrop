# 录音时接通 Realtime AI 采访员 — 设计

日期：2026-07-07
后端代码：`~/code/jianshuo.dev/agent/`（voicedrop-agent worker）
iOS 代码：`~/code/voicedrop/VoiceDropApp/`（RecordSession / AudioRecorder / …）
外部依赖：OpenAI Realtime API，模型 `gpt-realtime-2.1`（Realtime 2，speech-to-speech + reasoning）
相关既有 spec：`2026-06-27-voicedrop-usage-billing-design.md`（算力计费）、`2026-06-28-voice-edit-volc-asr-proxy.md`

## 一句话

在 VoiceDrop 录音屏红色大按钮左边加一个隐蔽触发区，按下后**照常开始录音**、并**同时**用 WebSocket 接通 `gpt-realtime-2.1` 把麦克风音频实时流给一位「媒体采访员」AI；AI 只在说话人**停顿 ≥5 秒**且合适时用**一句、<5 秒**的简短追问帮他继续讲；**录音本身绝不被打断**，照常保存上传；按 OpenAI 官方费率折算算力计费。

## 核心决策（已与用户确认，2026-07-07）

| 决策 | 选择 | 理由 |
|---|---|---|
| 目标表面 | **原生 iOS app**（不是 web） | 用户确认；红键在原生录音屏 |
| 传输 | **WebSocket Realtime，不用 WebRTC** | WebRTC 用 RTCAudioSession 接管/重配音频会话 + 自带一路麦克风采集，和现有 AVAudioRecorder 抢麦→易打断录音；WS 让我们单采集全掌控。用户授权「用最好的方法」 |
| 音频采集 | **AVAudioRecorder → AVAudioEngine 单采集 tee** | 一路采麦，PCM 同时写录音文件(a) + 推给 AI(b)；两个采集者不可靠，AVAudioRecorder 不给 buffer，单采集 tee 是唯一稳的架构 |
| AI 声音 | **外放 + 回声消除(AEC)** | 用户选；voiceProcessing 把 AI 声音从麦克风信号里消掉。**代价**：AEC/降噪/AGC 会改变录音音色，与今天原始 AAC 有差别（用户已接受；要逐比特一致只有「只进耳机」能做到） |
| 何时追问 | **程序控制 + 限流**（app 计时 ≥5s 停顿 + 限流才发 response.create），不用纯服务端 VAD | 纯服务端 VAD 每次静音就问→话痨且无法「不合适就不问」；app 控制精确且可限流。用户确认 |
| 模型 | **gpt-realtime-2.1** | 最新 Realtime 2；`reasoning.effort: low` |
| 计费 | **OpenAI 官方费率 → 算力 ledger** | 用户要求；接现有 usage_store |
| 分期 | **Phase 1 后端(全交付)+ Phase 2 iOS(写但真机验)** | 原生音频「录音不被打断/无爆音/AEC 干净」只能真机验，是用户的 build/TestFlight 环 |

## 核准的 OpenAI 技术事实（2026-07-07 查最新文档）

- **模型**：`gpt-realtime-2.1`（Realtime 2，加 reasoning；建议 `reasoning.effort: low`）。
- **临时凭证 mint**：`POST /v1/realtime/client_secrets`，服务端用 `OPENAI_API_KEY`。请求体字段：`model`、`instructions`、`audio.input.format` / `audio.output.format`、`audio.input.turn_detection`、`output_modalities`（`["audio"]`）、`reasoning.effort`。响应含 `id`(sess_…)、`client_secret`、`expires_at`。
- **WS 连接**：`wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1&client_secret=<临时secret>`。key 绝不上设备。
- **turn_detection**：`server_vad` 字段 `silence_duration_ms`(默认 500)、`threshold`(0.5)、`prefix_padding_ms`(300)、`create_response`、`interrupt_response`；另有 `semantic_vad`(`eagerness` low/medium/high/auto)。server_vad **仍发** `input_audio_buffer.speech_started` / `speech_stopped` 事件（不受 create_response 影响）。
- **音频事件**：发 `input_audio_buffer.append`(PCM16 base64)；喊 AI 开口发 `response.create`(client event)；掐断 AI 发 `response.cancel`；收 `response.audio.delta`(AI 语音 base64)、`response.done`(含 `usage`)。
- **费率(gpt-realtime-2.1，每 1M token)**：audio input **$32**、audio cached input **$0.40**、audio output **$64**；text input **$4**、text cached **$0.40**、text output **$24**。

## 架构

### A. 音频（iOS，Phase 2）—— 录音是神圣的
- 一个 `AVAudioEngine`，`inputNode` 开 **voiceProcessing(AEC)**，装一个 tap。每个 PCM buffer：
  1. **写录音文件**：`AVAudioFile`（AAC `.m4a`，与今天同 `Prefs.recorderSettings` 等价格式）。**最高优先级、同步、永不因 realtime 出错而失败。**
  2. **喂 AI**：重采样到 24kHz mono PCM16 → base64 → WS `input_audio_buffer.append`。**best-effort**：断网/鉴权失败/OpenAI 挂/背压，一律**静默降级**（停止喂 AI、UI 标降级），录音继续。
- AI 回来的 `response.audio.delta` → `AVAudioPlayerNode` 外放；AEC 保证它不进(1)的录音文件。
- 下游 staging→promote→上传队列**一行不改**：录音文件路径/命名/promote/离线队列与今天完全一致（`AudioRecorder` 的 staging→enriched 名 + Uploader）。
- **失败隔离**：realtime 子系统封装成独立对象 `RealtimeInterviewer`，它 crash / 抛错 / 网络断，录音路径完全不受影响（录音写入不经过它）。

**风险（最需真机验证）**：把现有 `AVAudioRecorder` 换成 `AVAudioEngine` 采集，动了神圣录音路径。缓解：录音文件写入是 tap 里第一优先、同步、不依赖任何 realtime 状态；先在真机验证「纯录音（不接 AI）」用新引擎与旧 AVAudioRecorder 产出等价、无 glitch，再接 AI。

### B. 服务端（voicedrop-agent worker，Phase 1）
两个新端点，认证用现有用户 token（resolveScope）：

1. **`POST /agent/realtime/session`** — mint 临时凭证
   - **不硬性拦截余额**（用户定：算力可为负）。直接用 `env.OPENAI_API_KEY` 调 `POST /v1/realtime/client_secrets`，body 带：`model: "gpt-realtime-2.1"`、采访员 `instructions`（见 D）、`audio.input.format`/`audio.output.format`（pcm16 24kHz）、`audio.input.turn_detection: { type:"server_vad", silence_duration_ms:500, create_response:false, interrupt_response:false }`（只借它的 speech_started/stopped 事件，**不自动回应**）、`output_modalities:["audio"]`、`reasoning.effort:"low"`。
   - 回 `{ client_secret, expires_at, session_id }` 给 app。`OPENAI_API_KEY` 只在 worker。
2. **`POST /agent/realtime/usage`** — 结算计费
   - app 会话结束上报 `{ session_id, usage: {audio_in, audio_in_cached, audio_out, text_in, text_in_cached, text_out} }`（token 数从 WS `response.done.usage` 累加）。
   - worker 按费率折算美元 → 折算算力，**直接扣费**（沿用 usage_store，**允许扣成负数，不设下限**），记 ledger（来源标 `realtime`）。
   - **计费不追求精确**（用户定）：直接信 app 上报的 token 数，不做 audio_seconds 上限兜底那类复杂 reconciliation。

**换算口径（用户定 2026-07-07）**：`1 USD = 7.3 RMB`，再 `×23 算力/元` ⇒ **`1 USD ≈ 167.9 算力`**。常量 `USD_TO_SUANLI = 7.3 * 23`。费率($/1M token)存 worker 侧常量/config，便于跟 OpenAI 官方更新。

### C. App WS 客户端（iOS，Phase 2）—— `RealtimeInterviewer`
- 向 `/agent/realtime/session` 取临时 secret → 连 `wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1&client_secret=…`。
- 连上发 `session.update` 兜底设 instructions / turn_detection / modalities。
- 持续发 `input_audio_buffer.append`（来自音频 tap 的(b)路）。
- 监听 `input_audio_buffer.speech_started` / `speech_stopped` 驱动停顿计时（见 D）。
- 累加 `response.done.usage`；会话结束调 `/agent/realtime/usage`。
- 任何错误 → 静默降级，录音继续。

### D. 采访员行为（instructions + 程序控制 + 限流）
- **instructions（中文）**：你是一位老练的媒体采访者。你认真听、真正理解对方说的核心。只用一句话、不超过 5 秒的简短追问，扣住他刚说的关键点，目的是帮他更容易接着往下说。绝不打断、不评论、不总结、不寒暄、不重复他的话。语气自然、克制。
- **程序控制（app 侧）**：AI 平时「静音旁听」（`create_response:false`，不自动出声）。app 用 server_vad 的 `speech_stopped` 事件起一个计时器；满足**全部**条件才发 `response.create`：
  1. 自 `speech_stopped` 起持续静音 **≥5 秒**（期间收到 `speech_started` 则重置）；
  2. **限流**：距上次追问 ≥ `MIN_GAP`（默认 20s）；
  3. 自上次追问以来说话人**有新说话段**（`speech_started` 至少发生过一次）。
- **打断保护**：AI 正在说（我们创建的 response 未完）时若收到 `speech_started` → 发 `response.cancel`，别盖过说话人。
- **长度兜底**：`response.create` 时带 `max_output_tokens` 上限，配合 instructions 保证 <5 秒。
- 常量（`MIN_GAP`、静音阈值 5s、max_output_tokens）真机可调。

## 数据流

```
点隐蔽触发区
  → RecordSession 照常 recorder.start()（录音开始，神圣）
  → 同时 RealtimeInterviewer.start():
       POST /agent/realtime/session（worker 用 OPENAI_API_KEY mint 临时 secret；不拦余额）
       连 WS → session.update
  → 音频 tap 每 buffer: (a) 写 .m4a  (b) 24kHz PCM16 → input_audio_buffer.append
  → 收 speech_stopped → app 起 5s 静音计时
       满足 ≥5s + 限流 + 有新内容 → response.create → 收 response.audio.delta → 外放（AEC 挡住不进录音）
       收 speech_started（说话人续说）→ 若 AI 在说则 response.cancel
  → 停止录音 / 再点触发区:
       recorder.stop() 照常 promote→上传队列（不变）
       RealtimeInterviewer.stop(): 累加的 usage → POST /agent/realtime/usage → 扣算力记账
```

## 错误处理 / 降级（录音优先级最高）
- realtime 任一环失败（无网、mint 失败、算力不足、WS 断、OpenAI 5xx、背压）：**只影响 AI**，录音写入与上传**完全不受影响**；UI 显示「AI 已断开（录音继续）」。
- 算力不足：**不拦截**（用户定：可为负）。照常接通，结算时扣成负数，用户后续充值补上。录音永远照常。
- 临时 secret 过期：app 在 `expires_at` 前重新 mint（长录音跨越 secret 有效期时重连，重连期间录音不受影响）。
- app 崩溃/切后台：录音按现有 AVAudioSession 中断逻辑处理（`interruptionNotification` 现有路径保留）；realtime 断开即可。

## 计费细节
- 换算：`美元 = Σ(token 数 × 该档费率 / 1e6)`；`算力 = 美元 × USD_TO_SUANLI`，`USD_TO_SUANLI = 7.3 × 23 = 167.9`（1 USD = 7.3 RMB，23 算力/元）。
- 分档费率($/1M)：audio_in **32** / audio_in_cached **0.40** / audio_out **64** / text_in **4** / text_in_cached **0.40** / text_out **24**。
- 来源：WS `response.done.usage` 逐 response 累加（app 侧累加后一次上报）。
- **不追求精确 + 允许负数**（用户定）：直接信上报值折算扣费，扣成负也不拦；不做 audio_seconds 兜底。
- ledger 记来源 `realtime`，与挖矿/编辑/图片并列，用户在「设置→算力」看得到。

## 分期

### Phase 1（我完整交付 + vitest + 部署）
voicedrop-agent worker：`/agent/realtime/session`（mint + 算力预检）、`/agent/realtime/usage`（费率折算 + 扣费记账）、费率 config、采访员 instructions 常量。需要 `OPENAI_API_KEY` 配成 worker secret（用户提供）。这是 iOS 要调的后端契约，可独立测试上线。

### Phase 2（我写 Swift，用户 Xcode/真机/TestFlight 验）
`AudioRecorder` 采集重构（AVAudioEngine + AEC + tee，保录音输出/上传契约）、`RealtimeInterviewer`（WS 客户端 + 停顿计时/限流 + 播放）、RecordSession UI（隐蔽触发区 + 状态）、usage 上报。**先真机验证「新引擎纯录音等价、无 glitch」，再接 AI。**

## 测试策略
- **Phase 1**：vitest 覆盖 `/agent/realtime/session`（余额足→mint 转发正确 body / 余额不足→402 / OpenAI 失败→502）、`/agent/realtime/usage`（费率折算数值、扣费入账、sanity 上限、坏输入拒绝）。用 fakeEnv + fakeFetch（拦截 OpenAI 调用）。
- **Phase 2**：真机手测——(1) 新引擎纯录音与旧 AVAudioRecorder 产出等价、无爆音；(2) 接 AI 后录音仍完整、AEC 挡住 AI 声音；(3) ≥5s 停顿才追问、说话人续说即 cancel；(4) 断网/杀 AI 录音不受影响；(5) 计费数与官方用量吻合。

## 安全
- `OPENAI_API_KEY` 只在 worker secret，绝不下发设备；app 只拿短时 `client_secret`（`expires_at` 到期重 mint）。
- realtime 端点认用户 token + scope 隔离；usage 上报按 session_id 记该用户账。

## 非目标（YAGNI）
- 不做 WebRTC。
- 不改录音的保存/命名/上传流程。
- 不把 AI 追问写进录音文件（AEC 挡住；也不做「访谈稿」模式）。
- 不做 AI 文字聊天 UI（纯语音；oai-events 数据通道只用于音频/事件/usage）。
- 不做多语言/多音色切换（v1 定一个中文音色 + 中文 instructions）。
- Phase 1 不依赖 Phase 2；后端可先上线自测。

## 已确认的取舍
- AEC 会改变录音音色（已确认接受）。
- 计费不追求精确、算力可为负、mint 不拦余额（已确认，2026-07-07）。换算 1 USD = 7.3 RMB → ×23 算力。
