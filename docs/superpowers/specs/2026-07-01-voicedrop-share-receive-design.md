# VoiceDrop 接受分享（Share Extension 收件）— 设计

**日期**：2026-07-01
**状态**：设计已批准，待写实现计划
**作者**：王建硕 + Claude

## 一句话

让 VoiceDrop 成为 iOS 系统分享目标：从别的 app（微信文章、Safari 网页、相册照片、Files 里的 Word/PDF）点「分享」→ VoiceDrop 收下 → 走挖矿流水线成文，或收进训练风格语料。**客户端负责一切文字提取，服务端尽量不动。**

## 现状（起点）

Share Extension 的**管道已经铺好**，服务端只处理了「文字」和「音频」两类：

- iOS `VoiceDropShare/ShareViewController.swift`：接受 URL/文字/图片/文件；「用途」选择器 挖文章(mine)/训练风格(style)；上传到 `/files/api/upload/<name>`，文件名带 `VoiceDrop-mine-*` / `VoiceDrop-style-*` 前缀；AppGroup 把 anon token 桥给扩展。
- 服务端 `agent/src/miner.js`：
  - `classifyKey` 路由 `VoiceDrop-style-*`→style、`VoiceDrop-mine-*.txt/.md`→mine-text、`.m4a`→audio。
  - `mineOneText` ✅ 分享文字挖文章（跳 ASR，文字即 transcript）。
  - `collectStyle` ✅ 分享文字/链接收进 `<scope>style/` 语料。
  - `.m4a` 音频 ✅ 走正常 ASR→挖矿。

**四个缺口**（本设计要补）：

1. **图片 → 挖文章**：`classifyKey` 对 `VoiceDrop-mine-*.jpg` 返回 null，图片完全没被处理。
2. **URL**：只把 URL 当纯文字塞给 Claude，**不抓网页正文**。
3. **文档 .docx/.pdf → 挖文章**：`classifyKey` 只认 txt/md，docx/pdf 根本没被收。
4. **文档 .docx/.pdf → 训练风格**：`collectStyle` 记了 `needsExtraction:true` 但**从不提取正文**，样本是死的。

## 决策（已与用户确认）

- **本次范围**：三个缺口全做（图片、URL 抓正文、文档提文本）。
- **核心原则**：**尽量把文字提取放客户端**，服务端保持简单。
- **URL 抓取位置**：**客户端抓**（手机住宅 IP + 真浏览器 UA，微信文章成功率最高）；抓不到回退成只传 `URL+备注`；服务端零改动。
- **多图归拢**：**一次分享 = 一篇**（图文/照片故事），所有图当一组喂 Claude vision，插 `[[photo:key]]` 标记内联。
- **图片+备注**：备注走 sidecar，做最薄（见下）。

## 架构

```
微信/相册/Safari/Files ──分享──▶ VoiceDropShare(ShareViewController)
   PDF/docx/rtf/URL ──客户端提取(ShareExtraction)──▶ .txt ─┐
   图片 ──────────────原样上传──────────────▶ .jpg ──┐    │
   纯文字/备注 ────────原样上传──────────────▶ .txt ──┼────┴─▶ 现有 mineOneText / collectStyle（零改动）
                                                       └──────▶ 新 mineOneImageGroup → photos/<ts>/ + [[photo]] → 一篇图文
```

关键效果：**docx/pdf/url 永远不会以原格式到达服务端**——客户端提取原则让「服务端 docx 解析」「服务端 URL 抓取」这两个 Cloudflare Worker 无原生库的硬坑**整条消失**。两个 intent（挖文章/训练风格）都走同一套客户端提取。

服务端真正新增的只有**「图片 → 挖文章」一条 vision 管道**。

## 组件 A：iOS Share Extension —— 客户端提取

### A.1 新文件 `VoiceDropShare/ShareExtraction.swift`

把提取逻辑从 `ShareViewController` 抽出，便于阅读与（将来）单测。纯函数/小类，无 UI。提供：

- `extractPDF(_ fileURL: URL) -> String?` — `PDFKit.PDFDocument(url:)?.string`，trim 后返回；空（扫描件无文本层）→ nil。
- `extractRichDocument(_ fileURL: URL) -> String?` — `NSAttributedString(url:options:documentAttributes:)`（自动识别 docx/rtf/html/plain）取 `.string`。**注意**：HTML 文档读取需主线程（WebKit 支持），docx/rtf 不需要——本路径只喂本地 docx/rtf 文件，off-main 安全。
- `Readability`：
  - `fetchAndExtract(_ url: URL) async -> (title: String?, text: String)?` — `URLSession` 带浏览器 UA（`Mozilla/5.0 …`）+ 10s 超时 fetch HTML；
  - 微信特判：host 含 `mp.weixin.qq.com` → 正则抽 `<div id="js_content" …>…</div>`；
  - 通用：剥 `<script>/<style>`，取 `<article>` 或 `<body>`，去标签 + 解 HTML 实体，折叠空白；
  - 取 `og:title` 或 `<title>` 作标题提示，拼在正文前（如 `# <title>\n\n<正文>`）；
  - 任一步失败 → nil（调用方回退）。

**零第三方依赖**：全部用系统 `PDFKit` / `Foundation` / 正则。

### A.2 `ShareViewController.uploadAttachment` 分流（改）

现有分流基础上，按类型就地拍平：

1. **Web 链接**（URL 非 fileURL）：`Readability.fetchAndExtract` 成功 → `uploadText(提取正文, intent)`；失败 → **回退**现状（`url + "\n\n" + note` 当文字上传）。
2. **文件**：按扩展名/UTI
   - `.pdf` → `extractPDF`；有文本 → `uploadText`；空 → 回退原样上传该文件（服务端记为待提取，惰性，不阻断）。
   - `.docx/.doc/.rtf`（`officeOpenXML` / `com.microsoft.word.*` / `rtf`）→ `extractRichDocument`；有文本 → `uploadText`；空 → 回退原样上传。
   - **图片**（jpg/png/heic 等）→ 原样 `uploadFile`（保持 `.jpg`/`.png`，heic 可选转 jpg 与录音配图一致；v1 原样即可）。
   - 其它文件 → 原样上传（现状）。
3. **纯文字** → 现状。

提取出的文本一律 `.txt`。图片保持图片扩展名。因此服务端只会见到 `.txt`（文字）或 `.jpg/.png`（图片）。

### A.3 图片+备注 sidecar（薄）

图片分享时若用户打了备注（`contentText`）：**不再把备注当独立文字上传**（否则会被 `mineOneText` 单独挖成一篇）。改为上传 sidecar `VoiceDrop-mine-<ts>-note.txt`，内容是备注。`classifyKey` 对 `*-note.txt` 返回 null（不单独挖），由 `mineOneImageGroup` 读作该组上下文。无图片时行为不变。

### A.4 文件名时间戳去碰撞（小改）

现有 `filename()` 用 `Int(Date().timeIntervalSince1970)`（秒级）。为避免同一秒的两次分享被服务端按 `<ts>` 误并成一组，`<ts>` 加 3 位 base36 随机尾（如 `1719800000ab`）。同一次分享的多张图/sidecar 共用**同一个** `<ts>` 值，index 用 `-1/-2` 后缀区分。

## 组件 B：服务端图片管道（`agent/src/miner.js`）

### B.1 `classifyKey` 扩展

```
if (leaf 匹配 *-note.txt)              → null   // sidecar，跳过单独挖
if (VoiceDrop-mine-*.(jpg|jpeg|png))   → "mine-image"
// 其余不变：style / mine-text / audio / null
```

### B.2 分组

`mine-image` 键按**去掉 `-<index>` 后缀和扩展名**得到的基 stem 分组：`VoiceDrop-mine-<ts>-1.jpg` / `VoiceDrop-mine-<ts>.jpg` → 同组，基 stem = `VoiceDrop-mine-<ts>`。处理标记 = `articleKeyFor(基stem)`。

### B.3 `mineOneImageGroup(baseStem, imageKeys[], noteKey?, uploaded, env, modelCfg)`

1. 已有 `articleKeyFor` 或 `emptyKeyFor` → skip。
2. **拷贝定位**：每张图 `env.FILES.get` → `env.FILES.put` 到 `users/<sub>/photos/<ts>/<i>-<rand>.jpg`（photo 端点要求 key 含 `photos/`，这样内联渲染整套机制全复用），记下相对 key。拷完 `env.FILES.delete` 顶层原图（避免残留与重复挖；文章标记也会挡住重挖，双保险）。
3. 备注：有 `noteKey` 则读作 `note`，否则空。
4. **复用 `mineVariant`**：`photos=[已拷贝的图]`、`transcript=note||""`、`cacheMode:"system"`、`metaExtra:{source:"image"}`。vision 看图 → Claude 写一篇图文并在正文里插 `[[photo:photos/<ts>/<i>-<rand>.jpg]]` 标记。
   - **提示词敏感点**：现有挖矿提示词是「transcript + 配图」为主；纯图片（transcript 为空）时要能**只凭图片**写出文章。需小幅确认/微调 MINE 提示词使其在空 transcript + 有 photos 时产出图文。这是本管道唯一需要盯的提示词点，必测。
5. 无产出（两次均空）→ `writeEmpty(基stem, "no-article")` + `notifyStatus empty`。
6. 成功 → `writeArticle`（schema-2，`sourceImages:[leaf...]`）+ `notifyStatus ready` + `maybeAutoShareCommunity`。
7. **计费**：`mineVariant` 内已 best-effort 扣 Claude 费用（vision token 由 Claude usage 计），无 ASR 费。`meteredMineGate` 余额闸沿用（无 duration → 走余额判定，不触发 too-long）。

### B.4 主循环 `runMine`

在 audio/text/style 三个循环旁加 `images` 分组循环，调用 `mineOneImageGroup`，budget 记账（一组 ≈ N 次拷贝 + 1 次 vision；`budget -= 8 + imageCount` 量级）。`todo`/`texts`/`styles` 的过滤逻辑照旧（未处理 = 无 `.json/.empty`）。

## 组件 C：向后兼容 & 清理

- `collectStyle` 的 `needsExtraction`（docx 待提取）路径：新上传不再有 docx 到站（客户端已提成 txt），成为死路径。**保留分支不删**（老数据 + 安全兜底）。
- Pages 端**零改动**：上传走现有 `PUT upload/<key>`，图片内联走现有 `GET /files/api/photo/<key>`（已服务 `users/*/photos/*`）。
- URL/docx/pdf 的服务端分支不需要——客户端拍平后它们从不到站。

## 测试（`agent/test/`）

- `classifyKey`：新增 `mine-image`（jpg/jpeg/png）、`*-note.txt`→null 用例；现有 style/mine-text/audio/null 不变。
- 分组：多图共享 `<ts>` 归一组、index 后缀解析、基 stem 提取。
- `mineOneImageGroup`：mock Claude vision 返回带 `[[photo:...]]` 标记的文章 → 断言 (a) 文章 JSON 写入且含标记；(b) 图片已拷到 `users/<sub>/photos/<ts>/`；(c) 顶层原图已删；(d) 空返回 → `.empty no-article`；(e) 已处理 → skip。
- 向后兼容：现有 audio/text/style/community/photo-marker 测试全绿（挖矿契约不破）。
- iOS：提取 helper（PDF/docx/readability）可抽成可测的纯函数，但仓库单测只在 agent/；iOS 端**手测**（分享微信文章 / Word / PDF / 相册多图，验证成文与内联图）。

## 部署 & 工程

- 新增 `VoiceDropShare/ShareExtraction.swift` → **跑 xcodegen**（`project.yml` 的 `VoiceDropShare.sources: - path: VoiceDropShare` 已含整目录，自动纳入；仍执行 xcodegen 重新生成工程）。
- Worker：`cd ~/code/jianshuo.dev/agent && npx wrangler deploy`。
- iOS：改了扩展 → 推 main → GitHub Actions → 新 TestFlight build。
- Pages / reco：不动。
- 改动前后各跑一遍 `cd ~/code/jianshuo.dev/agent && npm test`（CLAUDE.md 规则）。

## 非目标（本期不做）

- 扫描版 PDF（无文本层）的 OCR / 逐页转图 vision——回退原样上传，惰性。
- 服务端 URL 抓取兜底（HTMLRewriter）——客户端抓失败就只留 URL，不加服务端抓取。
- 图片 → 训练风格（图片无写作风格；扩展默认图片走挖文章，若手动选风格则沿用现状惰性收录）。
- 混合分享（同一次既有文字又有图片）的深度合并——v1 图组只并图 + note sidecar，独立文字仍各自成文。

## 待实现时确认的开放点

1. iOS `NSAttributedString` 读 docx 在**扩展进程**里的实测表现（内存/时长）——Word 文档一般小，预期没问题，实现时验证。
2. MINE 提示词在**空 transcript + 有 photos** 下产出图文的质量——必测，可能需一句提示词补丁（见 `agent/src/prompts/mine.js`）。
3. 微信 readability 抽取的稳健性（`#js_content` 结构变化）——实现时用几篇真实微信文章验证。
