# VoiceDrop 接受分享（Share Extension 收件）— 设计

**日期**：2026-07-01
**状态**：设计已批准，待写实现计划
**作者**：王建硕 + Claude

## 一句话

让 VoiceDrop 成为 iOS 系统分享目标：从别的 app（微信文章、Safari 网页、相册照片、Files 里的 Word/PDF）点「分享」→ VoiceDrop 收下。**内容类型直接决定去向**：音频/图片 → 挖文章，文字/URL/文档 → 训练风格语料。**客户端负责一切文字提取；服务端只加一处逻辑。**

## 核心设计原则（本轮讨论定下的）

1. **内容类型即路由**，无需用户选「用途」：
   - **音频** → 挖文章（现有音频管道）。
   - **图片** → 挖文章（造静音占位音频 + 照片，走统一的「无语音+有照片→看图写短文：标题+简短描述」）。
   - **文字 / URL / 文档** → **只进训练风格语料**，不挖文章。
2. **客户端提取一切文字**（PDF/docx/URL），服务端不碰无原生库的解析/抓取。
3. **用占位音频统一状态**：图片分享 = app 内「静音录音+拍照」，两者共用同一条挖矿路径，不做两套。
4. **iOS 主 app 零改动**：占位就是一条普通录音，天然进列表/详情/删除；播放键播静音，不特殊处理。

## 现状（起点）

- iOS `VoiceDropShare/ShareViewController.swift`：已能接受 URL/文字/图片/文件，有「用途」选择器（本轮**去掉**），上传到 `/files/api/upload/<name>`。AppGroup 把 anon token 桥给扩展（`publishBearer`/`sharedBearer`）。
- 列表发现（`Library.swift` + `RecordingName.isRecordingFile`）**只认 `VoiceDrop-*.m4a`**，`stem = dropLast(4)` 到处假设有音频文件 → 所以任何非音频来源的文章都进不了列表。**本设计用「占位音频」绕过这一点，不改 iOS 列表模型。**
- 服务端 `agent/src/miner.js`：`mineOneAudio`（ASR→挖矿）、`mineOneText`（分享文字→文章）、`collectStyle`（文字/链接→`<scope>style/` 语料）、`classifyKey`（style/mine-text/audio）。**本设计只在 `mineOneAudio` 加一处逻辑，其余全部保持原样。**

## 为什么这样最简（两处塌缩）

- **图片不需要新的服务端分类**：图片分享造出的静音 `.m4a` 就是普通 `audio`，miner 照常按 `photos/<sessionTs>/` 收图。`classifyKey` **零改动**，无需 `mine-image` 分支。
- **文字/URL/文档不挖文章**：它们只喂 `collectStyle` 语料库，不需要占位音频、不需要 transcript sidecar、不需要进列表。已有 `collectStyle` 直接复用（客户端已把 docx/pdf/url 提成纯文本，`needsExtraction` 死路径）。

## 架构

```
微信/相册/Safari/Files ──分享──▶ VoiceDropShare(ShareViewController，按类型路由，无 用途 选择器)
   音频 .m4a ─────────────原样上传───────────────▶ 现有音频管道（挖文章，不动）
   图片 ──▶ 造静音占位 VoiceDrop-<date>-…​.m4a + 图片传 photos/<sessionTs>/
                                     └─▶ mineOneAudio：ASR空 + 有照片 → 看图写「标题+简短描述」短文  ← 唯一服务端新增
   文字/URL/文档 ──客户端提取正文(ShareExtraction)──▶ VoiceDrop-style-*.txt ──▶ collectStyle 语料库（挖文章不涉及）
```

服务端真正新增的只有一处：`mineOneAudio` 里「无语音 + 有照片 → vision 挖文」。这条逻辑**独立就有价值**——顺手救活 app 内「只拍照不说话」的录音（现在被直接判「无语音」，照片白拍）。

## 组件 A：iOS Share Extension

### A.1 新文件 `VoiceDropShare/ShareExtraction.swift`

把文字提取抽成纯逻辑（便于阅读/将来单测），零第三方依赖：

- `extractPDF(_ fileURL) -> String?` — `PDFKit.PDFDocument(url:)?.string`，trim；空（扫描件无文本层）→ nil。
- `extractRichDocument(_ fileURL) -> String?` — `NSAttributedString(url:options:documentAttributes:)`（自动识别 docx/rtf/html/plain）取 `.string`。docx/rtf 本地解析，off-main 安全（HTML 读取需主线程，但本路径喂的是本地文档文件，不是 HTML）。
- `Readability.fetchAndExtract(_ url) async -> (title: String?, text: String)?` — `URLSession` 带浏览器 UA + 10s 超时 fetch HTML；微信特判抽 `#js_content`，通用剥 `<script>/<style>` 取 `<article>`/`<body>` 去标签解实体；取 `og:title`/`<title>` 作标题拼前面；失败 → nil。

### A.2 `ShareViewController` 按类型路由（改）

**去掉「用途」选择器**（`configurationItems` 返回空 / 移除 picker 行；`SLComposeServiceViewController` 的分享面板与可选备注框保留）。`didSelectPost` 里按附件类型分流：

- **音频文件**（`.m4a` 等） → 原样 `uploadFile`，名 `VoiceDrop-<date>-<HHMMSS>-…​.m4a`（录音式名，走挖文章）。
- **图片**（jpg/png/heic…） → **图片分享分支**（见 A.3）。
- **Web 链接**（URL 非 fileURL） → `Readability.fetchAndExtract` → 成功传提取正文，失败回退 `url + note` → **训练风格**（`VoiceDrop-style-*.txt`）。
- **文档** `.pdf` → `extractPDF`；`.docx/.doc/.rtf` → `extractRichDocument`；有文本 → **训练风格**（`VoiceDrop-style-*.txt`）；空 → 原样上传该文件到 style（`collectStyle` 记 `needsExtraction`，惰性）。
- **纯文字** → **训练风格**（`VoiceDrop-style-*.txt`）。

即：图片/音频 → 挖文章；文字/URL/文档 → 训练风格。备注框对图片忽略；对文字/风格可拼进样本文本（次要）。

### A.3 图片分享 → 静音占位录音

一次图片分享（1~12 张）：

1. **生成录音式名** `VoiceDrop-<yyyy-MM-dd-HHmmss>-<0s或1s>-<weekday>-<period>.m4a`（`sessionTs = yyyy-MM-dd-HHmmss`）。
2. **上传静音占位音频**：扩展内 bundle 一段 ~1KB 的合法静音 `.m4a` 资源，`PUT upload/<该名>`（最简，无需在扩展里录音）。
3. **上传图片**到 `photos/<sessionTs>/<i>-<rand>.jpg`（与 app 内拍照配图**同一命名/同一路径约定**，`RecordingName.photoKey` 的等价物；`<i>` = 该次分享内序号，`<rand>` 3 位 base36）。

于是这次分享 = R2 里一条静音 `.m4a` + 若干 `photos/<sessionTs>/…`，**与 app 内「静音录音时拍了几张照片」在 R2 上完全同形**。iOS 列表/详情/删除全部照常工作，零改动。

## 组件 B：服务端 miner —— 唯一新增逻辑

`agent/src/miner.js` `mineOneAudio`：把「照片收集」提到「无语音判定」之前，改判定：

```
ASR 完成：
  有语音            → 照常挖矿（transcript + 照片，如常，用完整挖矿提示词）
  无语音 + 有照片    → 专用「图片短文」提示词：给一个简短标题 + 一段简短图片描述，插 [[photo:key]] 标记   ← 新
  无语音 + 无照片    → writeEmpty(no-speech)（照旧）
```

- **图片-only 用专门的短提示词，不复用完整挖矿提示词**（`agent/src/prompts/mine.js` 新增一段，例如 `IMAGE_ONLY_SYSTEM`）：没有语音时不要硬写长文，而是**看图起一个简短标题 + 写一段简短的图片描述（几句话即可），用用户的文风**，并在描述里插入 `[[photo:key]]` 标记内联图片。产出仍是标准文章 schema（`{title, body}`），所以 `mineVariant`/`writeArticle`/计费/`maybeAutoShareCommunity` 下游全不变——只是喂进去的 system 提示词换成短版。
- **提示词敏感点（必测）**：这段短提示词要稳定产出「标题 + 简短描述」而非长文或空洞套话；用几组真实照片验证。这是本设计唯一的提示词风险点。
- **计费**：`mineVariant` 内已扣 Claude（vision token 由 usage 计）；静音 `.m4a` 的 ASR ≈ 0 费；`meteredMineGate` 按极短时长走余额判定（不触发 too-long）。
- **ASR**：静音占位仍走现有 `transcribeResumable`（Volcano 对 1s 静音快速返回空）——**不加任何 skip-ASR 特殊处理**（按用户要求，占位就是没声音，随它 ASR）。

`classifyKey` / `mineOneText` / `collectStyle` **不改**（向后兼容契约不破）。

## 组件 C：不改动的部分（明确边界）

- **iOS 主 app**：零改动。占位录音是普通录音，进列表、进详情（顶部播放键播静音，**不隐藏、不特殊处理**）、可删除、图片经 `[[photo:key]]` + `PhotoTile` + `photo/<ts>/` 端点内联渲染（全是现成机制）。
- **Pages**：零改动（上传走现有 `upload/`，内联走现有 `photo/`）。
- **文字/URL/文档进文章**：**本期不做**（只进风格语料）。因此无 transcript sidecar、无 `mine-text` 依赖。
- **训练风格语料的可见性**：style 样本不作为录音进列表（设计如此，是参考素材而非内容）。`collectStyle` 照常 `notifyStatus(style)`。

## 测试（`agent/test/`）

- `mineOneAudio` 新分支：mock ASR 返回空 + 提供 `photos/<ts>/…` → 断言 (a) 走 vision 挖文、文章 JSON 含 `[[photo:…]]` 标记；(b) 无照片时仍 `.empty no-speech`；(c) 有语音时行为不变。
- 向后兼容：现有 audio/text/style/community/photo-marker 全套测试保持绿（挖矿契约不破）。
- iOS：`ShareExtraction` 的 PDF/docx/readability 可抽成纯函数便于测（仓库单测只在 agent/，iOS 端手测）；手测覆盖：分享微信文章/网页/Word/PDF/纯文字 → 进风格语料；分享 1 张 / 多张相册图 → 出一篇图文、图片内联。

## 部署 & 工程

- 新增 `VoiceDropShare/ShareExtraction.swift`（+ bundle 静音 `.m4a` 资源）→ **跑 xcodegen**。
- Worker：`cd ~/code/jianshuo.dev/agent && npx wrangler deploy`。改动前后各跑 `npm test`（CLAUDE.md 规则）。
- iOS：改了扩展 → 推 main → GitHub Actions → 新 TestFlight build。
- Pages / reco：不动。

## 非目标（本期不做）

- 文字 / URL / 文档 → 挖文章（现在只进风格语料；「现在」= 可将来再议）。
- 扫描版 PDF（无文本层）OCR / 逐页转图 vision → 回退原样上传到 style，惰性。
- 服务端 URL 抓取兜底（HTMLRewriter）→ 客户端抓失败就回退传 URL 文本到 style。
- 占位录音的任何特殊 UI（隐藏播放键、去时长等）—— 按用户明确要求，不做。

## 待实现时确认的开放点

1. iOS `NSAttributedString` 读 docx 在**扩展进程**内的实测（内存/时长）——Word 文档一般小，预期没问题。
2. `prompts/mine.js` 新增的 `IMAGE_ONLY_SYSTEM` 短提示词在**空 transcript + 有照片**下的产出质量（标题 + 简短描述，非长文）—— 必测。
3. 微信 readability（`#js_content`）稳健性 —— 用几篇真实微信文章验证。
4. 生成合法静音 `.m4a` 的最简法：优先 bundle 一段预制静音资源；备选扩展内 `AVAudioRecorder` 录 1s。
