# VoiceDrop 接受分享（Share Collect）— 设计

**日期**：2026-07-01
**状态**：设计已批准（据 Share Collect.dc.html + 用户决策），待写实现计划
**作者**：王建硕 + Claude
**设计源**：`design_handoff_share_collect/Share Collect.dc.html`（+ `share_collect.png`）

## 一句话

VoiceDrop 成为 iOS 系统分享目标。从别的 app 分享进来，按内容类型升起**自定义 sheet**：
- **你自己的内容（音频 / 图片）→「成文」sheet** → 挖文章。
- **外部素材（文字 / 网页 / 文档）→「风格数据集」sheet** → 攒进语料库，随时一键「提取文章风格」。

客户端负责一切文字提取；服务端加语料 collect/list/extract 接口 + 一处 vision 挖图逻辑。

## 路由（最终，据用户决策）

| 分享类型 | 升起的 sheet | 去向 |
|---|---|---|
| **音频** | 成文 sheet · 波形版 | 挖文章（现有音频管道 + 确认 UI） |
| **图片**（1~N 张） | 成文 sheet · 缩略图版 | 挖文章（静音占位 `.m4a` + 照片 + vision 看图写文） |
| **文字 / 网页 URL / 文档(.docx/.pdf/.rtf)** | 风格数据集 sheet | 客户端提取正文 → 语料库 → 「提取文章风格」批量蒸馏成写作风格新版本 |

**决策记录**：图片归「挖文章」（推翻设计原稿把图片放进数据集的画法）——外部文字素材是学风格的料，图片和音频是你自己的内容、成文。图片沿用「成文 sheet」的缩略图变体（设计只画了音频版，此为一致延伸）。

## 组件 A：iOS Share Extension —— 自定义 UI（替换 SLComposeServiceViewController）

现有 `VoiceDropShare/ShareViewController.swift`（`SLComposeServiceViewController` + 用途选择器）**整个替换**为自定义控制器（SwiftUI 托管在扩展里，`UIHostingController`）。启动时按分享附件类型分派到三种 sheet 之一。

### A.0 类型分派（`ShareRouter`）
读 `extensionContext.inputItems` 的附件，判定主类型：
- 有音频文件（`public.audio` / `.m4a/.mp3/.wav/.m4a`）→ **成文·音频**。
- 有图片（`public.image`）→ **成文·图片**。
- 其余（URL / 纯文字 / `.pdf/.docx/.doc/.rtf`）→ **风格数据集**。
- 混合：按「自己的内容优先」——出现音频/图片即走成文；否则数据集。

### A.1 客户端提取 `ShareExtraction.swift`（纯逻辑，零三方依赖）
- `extractPDF(fileURL) -> String?` — `PDFKit.PDFDocument(url:)?.string`。
- `extractRichDocument(fileURL) -> String?` — `NSAttributedString(url:options:documentAttributes:)` 自动识别 docx/rtf/html，取 `.string`。
- `Readability.fetch(url) async -> (title:String?, text:String)?` — `URLSession` 浏览器 UA + 10s 超时；微信特判 `#js_content`，通用剥 `<script>/<style>` 取 `<article>`/`<body>` 去标签解实体；取 `og:title`/`<title>` 作标题；失败 → nil。
- `firstLineTitle(text) -> String` — 文字/文档取首行/文件名作标题。

### A.2 风格数据集 sheet（`StyleDatasetView`）
设计：`Share Collect.dc.html` 左侧 sheet。

- **顶部**：标题「风格数据集」+「已收集 N 项 · 约 X 字」+「关闭」。
- **列表**（可滚）：每项 = 类型上色方形图标（文档米色/网页绿/文字灰，去掉图片）+ 标题（尽量抓，回退文件名/域名）+ 副标题「类型 · 字数或域名 · 日期」。数据从 `GET /files/api/style/dataset` 读。
- **「本次新增」分割线**（赭红）：本次分享上传的项排在末尾，赭红描边高亮 + 勾。
- **URL 状态**：进来是链接 → 先插一行「正在解析网页…」+ 转圈（客户端 `Readability.fetch` 进行中）→ 成功回填标题 / 失败标灰「解析失败·仅存链接」+「重试」。
- **底部**：
  - 复选「提取后清空数据集」（默认勾）+「下次从零开始」。
  - 「继续收集」（次按钮）→ 上传本次项、`completeRequest` 关闭、回到来源 app（数据集留存）。
  - 「提取文章风格」（主按钮，赭红）→ 调 `POST /agent/style/extract {clearAfter}` 蒸馏 → 成功提示 → 关闭。

**收集时序**：sheet 出现即 `GET dataset` 显示已有；同时把本次分享的项 `POST /files/api/style/collect` 上传（文档/文字先本地提取；URL 先转圈后回填），新项标「本次新增」。

### A.3 成文 sheet · 音频版（`AudioComposeView`）
设计：`Share Collect.dc.html` 右侧 sheet。

- 顶部「从这段录音成文」+「来自 <源> · 已就绪」+「关闭」。
- **音频卡**：紫色音符图标 + 文件名 + 「m4a · 大小」；**波形**（从音频采样简易绘制，取不到用等宽占位条）；播放键（`AVAudioPlayer`）+ 进度 + 时长。
- **生成设置**：写作风格（显示当前风格首句，chevron；v1 只读展示）+ 识别语言（中文·自动）。
- **算力预估**：「预计消耗约 N 算力 · 转写 + 成文一步完成」——按时长估（ASR ¥0.8/时 + 典型挖矿），客户端用 `usage` 已知费率粗算。
- 底部主按钮「开始生成文章」→ 以录音式名 `VoiceDrop-<date>-<HHMMSS>-<dur>-…​.m4a` 上传音频 + `POST /agent/mine/trigger` → 关闭。文章随后进「我的录音」（音频锚点，主 app 零改动）。

### A.4 成文 sheet · 图片版（`PhotoComposeView`，A.3 的缩略图变体）
- 顶部「看图写一篇」+「N 张图片 · 已就绪」+「关闭」。
- **缩略图网格**代替波形（1~N 张，方形裁切预览）。
- 生成设置（写作风格）+ 算力预估（vision 粗算）。
- 底部主按钮「开始生成文章」→ 造静音占位 `.m4a`（bundle 一段 ~1KB 静音资源，录音式名）+ 图片传 `photos/<sessionTs>/<i>-<rand>.jpg` + `POST /agent/mine/trigger` → 关闭。走 B.3 的 vision 路径成图文。

### A.5 鉴权
沿用现有 `AppGroup.sharedBearer`（登录时主 app `publishBearer` 镜像 anon token）。未登录 → sheet 显示「请先在 App 内登录」占位，禁用主操作。

## 组件 B：服务端

### B.1 风格语料 API（Pages `functions/files/api/[[path]].js`，纯 R2，无 Claude）
语料样本存 `<scope>style/<id>.json`（复用现有 `collectStyle` 的样本约定，补全 `title`）：
- `POST style/collect` `{type, title, text, source}` → 写一条样本（客户端已提取好文本）；返回 `{ok,id}`。**取代**「上传 .txt 让 miner `collectStyle` 拾取」的间接路径（富交互 sheet 需要同步反馈）。旧的 file-drop + `collectStyle` 保留兼容。
- `GET style/dataset` → `{items:[{id,type,title,chars,source,collectedAt}], count, totalChars}`（按时间倒序）。
- `DELETE style/dataset` → 清空语料（`提取后清空` / 手动清）。

### B.2 提取文章风格（agent worker `agent/src/index.js`，需 Claude + 计费）
- `POST /agent/style/extract` `{clearAfter}` — 读 `<scope>style/*.json` 全部样本 → 拼语料 → Claude 蒸馏出一套写作风格卡（复用 `wjs-distilling-style` 的提示词精神）→ 经 style-store 写**写作风格新版本**（`CLAUDE.json` schema-3 PUT）→ `clearAfter` 则删语料 → best-effort 扣算力 → 返回 `{ok, version, styleSummary}`。
- 空语料 → 400「数据集为空」。防滥用：与挖矿同一余额闸。

### B.3 挖文章：无语音 + 有照片 → vision（`agent/src/miner.js`）
`mineOneAudio`：把照片收集提到「无语音判定」之前——
```
ASR 完成：
  有语音          → 照常挖矿
  无语音 + 有照片  → 专用短提示词 IMAGE_ONLY_SYSTEM：给简短标题 + 简短图片描述，插 [[photo:key]]   ← 新
  无语音 + 无照片  → writeEmpty(no-speech)（照旧）
```
- 复用 `mineVariant`（vision 输入、`[[photo:key]]` 标记、`writeArticle`、计费、`maybeAutoShareCommunity` 不变）。
- `prompts/mine.js` 新增 `IMAGE_ONLY_SYSTEM` 短提示词：**空 transcript + 有照片时不硬写长文**，起简短标题 + 一段简短图片描述。必测。
- 顺手救活 app 内「只拍照不说话」的录音（同一分支）。

## 组件 C：不改动 / 明确边界

- **iOS 主 app**：零改动。占位录音是普通录音（进列表/详情/删除，播放键播静音，不特殊处理）；图片经 `[[photo:key]]` + `PhotoTile` + `photo/<ts>/` 端点内联渲染。
- `classifyKey`（图片以 `.m4a` 占位归入 `audio`，无需 `mine-image` 分支）、`mineOneText`：保持原样（向后兼容）。
- 数据集 sheet **不含图片项**（图片走成文）。

## 组件 D：iOS 工程

- 替换 `VoiceDropShare/ShareViewController.swift` → 自定义 `UIHostingController` 入口 + 新 SwiftUI 文件：`ShareRouter.swift`、`StyleDatasetView.swift`、`AudioComposeView.swift`、`PhotoComposeView.swift`、`ShareExtraction.swift`、`ShareUploader.swift`（PUT + collect + trigger + extract 调用），bundle 静音 `.m4a` 资源。
- `project.yml` 的 `VoiceDropShare.sources: - path: VoiceDropShare` 已含整目录，自动纳入；仍**跑 xcodegen** 重新生成工程。扩展需网络（默认可）+ 可能的照片/URL 无需额外权限。

## 测试

- **服务端**（`agent/test/`）：
  - `mineOneAudio`：ASR 空 + 有照片 → vision 挖文、文章含 `[[photo]]`；无照片仍 `.empty`；有语音不变。
  - `style/collect` + `style/dataset`：写样本、列表元数据（chars/title/type）、DELETE 清空。
  - `POST /agent/style/extract`：mock Claude 返回风格卡 → 写入新版本；`clearAfter` 删语料；空语料 400。
  - 向后兼容：现有 audio/text/style/community/photo-marker 全套绿。
- **iOS**：`ShareExtraction`（PDF/docx/readability）抽纯函数便于测（仓库单测在 agent/，iOS 手测）；手测覆盖：分享微信文章/网页/Word/PDF/纯文字 → 数据集 sheet 出现、正文入库、URL 转圈/失败/重试；分享音频 → 成文·音频 sheet、波形/播放/算力、生成文章进列表；分享 1/多图 → 成文·图片 sheet、缩略图、生成图文内联；「提取文章风格」→ 写作风格出新版本；「提取后清空」勾/不勾。

## 部署

- Pages：`cd ~/code/jianshuo.dev && npx wrangler pages deploy .`（干净 worktree，见 STATE.md Pages 部署坑）。
- Worker：`cd ~/code/jianshuo.dev/agent && npx wrangler deploy`。改动前后各跑 `npm test`。
- iOS：xcodegen → 推 main → TestFlight（扩展大改要新 build）。

## 非目标（本期不做）

- 数据集 sheet 里编辑/删单项（只列表 + 清空 + 提取；删单项后议）。
- 成文 sheet 的写作风格/语言**选择器**下钻页（v1 只读展示当前值）。
- 扫描版 PDF OCR、服务端 URL 抓取兜底。
- 文字/网页/文档 → 挖文章（只进数据集）。

## 待实现时确认的开放点

1. `prompts/mine.js` 的 `IMAGE_ONLY_SYSTEM` 在空 transcript + 有照片下产出质量（标题 + 简短描述）—— 必测。
2. `POST /agent/style/extract` 的蒸馏提示词与算力估算（可先借 `wjs-distilling-style`）。
3. 扩展进程内 `NSAttributedString` 读 docx / `AVAudioPlayer` 播放 / 波形绘制的实测（内存/时长）。
4. 静音 `.m4a` 资源：优先 bundle 预制静音；备选扩展内 `AVAudioRecorder` 录 1s。
5. 微信 readability（`#js_content`）稳健性 —— 真实文章验证。
