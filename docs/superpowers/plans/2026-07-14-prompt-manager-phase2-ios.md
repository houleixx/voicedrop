# Prompt Manager Phase 2（iOS）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 iOS 的提示词管理换成新 Prompt Manager（5a 列表 / 3c 新建 / 5c 编辑 / 4a+4b 魔法数字导入 / 1b 删除 / 1d+1a 拖动分组），长按菜单改吃同一份列表的 appliesTo 过滤视图，并修复当前老设置页「加载失败」。

**Architecture:** 服务端 Phase 1 已上线（ref/fork 模型，worker `f4cd16cd`）。iOS 端一个 `PromptStore`（模型 + 整树读写 + 过滤 + 缓存回退）喂五个新视图和现有 `ConfigMenu`；编辑系统项 = 客户端实体化（fork）。先补两个小服务端件（分享状态读端点 + fork 时分享码 re-key），分享卡才能工作。

**Tech Stack:** SwiftUI（iOS 17+，现有代码风格）、xcodegen、XCTest（新建测试 target）；服务端件 = Cloudflare Worker（`~/code/jianshuo.dev`，vitest）。

**Spec:** `docs/superpowers/specs/2026-07-13-prompt-manager-redesign.md`（§9 iOS、§10 tokens）。设计稿 `/Users/jianshuo/Downloads/design_handoff_prompt_manager/`（`Prompt Manager.dc.html`）。

## Global Constraints

- **iOS 仓库 `~/code/voicedrop`，在 main 上就地干活**（本会话约定）。服务端件在 `~/code/jianshuo.dev-prompts` worktree（新分支）。
- **xcodegen**：每次新增/删除 Swift 文件后必须在仓库根跑 `xcodegen`（CLAUDE.md 规则；`.xcodeproj` 不入库）。
- **构建验证**：`cd ~/code/voicedrop && xcodegen && xcodebuild build -project VoiceDrop.xcodeproj -scheme VoiceDrop -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO | tail -5`，期望 `BUILD SUCCEEDED`。
- **单元测试**：Task 2 建 `VoiceDropTests` target 后：`xcodebuild test -project VoiceDrop.xcodeproj -scheme VoiceDrop -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:VoiceDropTests 2>&1 | tail -5`（模拟器名不存在就先 `xcrun simctl list devices available | head` 挑一个）。
- **服务端测试**：`cd ~/code/jianshuo.dev-prompts/agent && npm test`，基线 **81 文件 / 985 用例绿**。
- **服务端契约（已上线，勿改形状）**：
  - `GET /agent/prompts` → `{schema:1, items:[resolved]}`；resolved 节点 = `{id, type:"action"|"group", label, origin:"system"|"custom"|"user", prompt?, appliesTo?, kind?, forkedFrom?, children?}`
  - `PUT /agent/prompts` body `{items:[raw]}`；raw 节点 = `{ref}`（系统引用，group 可带 `children`）或实体 `{id:"p_[a-z0-9]{6,}", type, label≤40, prompt≤4000, appliesTo⊆{text,image}非空, kind?, forkedFrom?, children?}`；非法 → 400 `{error}`
  - `POST /agent/prompts/import {code}` → `{item}`；`POST /agent/prompts/restore-defaults` → 全量；`GET /agent/prompt-share/<7位码>`（**无需 auth**）→ `{label, prompt, appliesTo, kind?, author, importCount}`，查无 404 `{error:"not-found"}`
  - 铸码/关码（现有）：`POST /agent/prompt-share {id}` → `{code}`；`DELETE /agent/prompt-share/<id>`；429 = 当日铸码上限
- **`imageParams` 本期不解码不渲染**（spec 推迟；当前线上无任何数据带它。客户端 fork 会丢它——现在丢无可丢，Phase 3 接图片参数时再补解码）。
- **设计 token（spec §10，精确还原）**：页面/sheet 背景 `#FAF6EF`；卡白 `#fff`/1px `#ECE3D5`/圆角 5（大卡）·sheet 10–14；行分隔 `#F0E8DA`；文字主 `#2A2521` 次 `#8A8175` 弱 `#b8ae9e` 组题 `#a79f93` 词文 `#5b5349`；适用标：都行灰 `#7A6E5C`/`#F1ECE3`、仅文字绿 `#5E8A6A`/`#EAF1EC`、仅图片橙红 `#D8593B`/`#F6E4DC`；origin 标：系统 `#9a9184`/`#F1ECE3`、已自定义 `#C98A2E`/`#FBEAD2`、自建 `#5E8A6A`/`#EAF1EC`；强调/删除/＋ `#D8593B`；拖动高亮 `#D8B08A`~`#D8A25B`；字号：页题 26/编辑页 19、行名 15、说明 12.5、标 10.5、导入数字 30 monospace（letter-spacing 8）。复用 `Theme` / `SettingsCard` / `SettingsRow` / `NavSquare` / `settingsChevron` / `settingsRowDivider`。
- **新 UI 字符串全部走 `String(localized:)`**（老 app 全量本地化过，String Catalog 会收集；英文翻译留给发版前统一补，不阻塞构建）。
- **AI 建议已砍**（用户拍板）：5c 无琥珀条，新建 appliesTo 默认 `["text","image"]`（都行）。
- iOS 提交信息中文，结尾 `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`。

---

### Task 1（服务端）：分享状态读端点 + fork 时分享码 re-key

Phase 1 终审遗留 ①②。没有它们，5c 分享卡要么瞎（读不到状态，用 POST 试探会把已关的分享复活），要么用户一编辑正在分享的系统项、分享码就永远停在旧内容。

**Files:**
- Modify: `agent/src/prompt-share.js`（暴露 states 路由 + re-key 函数）
- Modify: `agent/src/prompt-routes.js`（PUT 保存后调 re-key）
- Modify: `agent/src/index.js`（新路由一行）
- Test: `agent/test/prompt-share.test.js`、`agent/test/prompts.test.js`（追加）

**Interfaces:**
- Produces: `GET /agent/prompt-shares`（用户 token，401 无 token）→ `{byItem: {"<itemId>": {code, sharing}}}`——直接暴露现有 `shareStates(env, scope)` 的结果（它原是老 ui-config/custom GET 的内部件，逻辑现成）。
- Produces: `rekeyForkedShares(env, scope, items)`——PUT 保存后调用：对每个带 `forkedFrom: F` 的实体，若 owner 索引 `byItem[F]` 存在且 `byItem[实体id]` 不存在 → 把索引条目从 F 挪到实体 id（**码不变**，"一条指令一辈子一个码"），随后现有活同步把 fork 的内容刷进 `shares/<码>`。幂等（再存一次无副作用）。边界：fork 又被删、同一 F 的二次 fork → 不 re-key（码停在上一个内容，写测试钉死这个接受的行为）。

- [ ] **Step 1: 失败测试**——`GET /agent/prompt-shares`：无 token 401；有分享 → byItem 带 code+sharing:true；关掉后 sharing:false 码保留。re-key：铸码于 `sys_cartoon` → PUT 一棵把它 fork 成 `p_x` 的树 → 索引键变 `p_x`、`shares/<码>` 内容 = fork 的新词、码不变；重复 PUT 幂等；fork 已删除的场景不动索引。
- [ ] **Step 2: 确认失败**（路由 404 / re-key 不存在）
- [ ] **Step 3: 实现**——states 路由照 `/agent/prompts` 的鉴权惯例；re-key 在 `handlePromptsRoute` PUT 分支 `saveUserPrompts` 之后、活同步 `refreshPromptShare` 循环**之前**调（这样同一次 PUT 里 re-key 完立刻被刷新）。best-effort：re-key 失败不挡保存（try/catch + console.error）。
- [ ] **Step 4: 全套绿**（`npm test`，985 + 新增）
- [ ] **Step 5: 提交 + 部署**——commit 后 `cd agent && npx wrangler deploy`（**部署是生产动作：执行前向用户确认**；这次不删任何端点，纯增量，无老 app 风险）。线上冒烟：`curl -s https://jianshuo.dev/agent/prompt-shares -H "Authorization: Bearer anon_x…"` → `{"byItem":{}}`。

---

### Task 2（iOS）：测试 target + PromptStore 纯逻辑（模型/序列化/fork/过滤）

**Files:**
- Modify: `project.yml`（加 `VoiceDropTests` unit-test target）
- Create: `VoiceDropApp/PromptStore.swift`（本任务只放模型 + 纯逻辑；网络下个任务）
- Create: `VoiceDropTests/PromptStoreTests.swift`

**Interfaces（后续任务全靠这些签名）:**
```swift
struct PromptNode: Codable, Identifiable, Equatable {
    var id: String
    var type: String            // "action" | "group"
    var label: String
    var origin: String          // "system" | "custom" | "user"（服务端派生，客户端只读它画标）
    var prompt: String?
    var appliesTo: [String]?    // action 才有
    var kind: String?
    var forkedFrom: String?
    var children: [PromptNode]? // group 才有
}
enum PromptAnchor: String { case text, image }

// 纯逻辑（全部 static，可单测）：
PromptLogic.rawItems(_ nodes: [PromptNode]) -> [[String: Any]]     // resolved → PUT 的 raw 形状
PromptLogic.fork(_ node: PromptNode) -> PromptNode                 // 系统项实体化：新 p_ id + forkedFrom + origin=custom
PromptLogic.newUserID() -> String                                  // "p_" + 8 位 base36
PromptLogic.filter(_ items: [PromptNode], for: PromptAnchor) -> [PromptNode]  // 5b 过滤
PromptLogic.menuConfig(_ items: [PromptNode], for: PromptAnchor) -> UIMenuConfig  // 过滤结果 → ConfigMenu 现有输入形状
```

- [ ] **Step 1: project.yml 加测试 target**（在 `targets:` 下追加；`VoiceDropTests/` 目录 + 一个空测试文件先落地，`xcodegen` 后 `xcodebuild test` 能跑起来）：
```yaml
  VoiceDropTests:
    type: bundle.unit-test
    platform: iOS
    sources: [VoiceDropTests]
    dependencies:
      - target: VoiceDrop
    settings:
      GENERATE_INFOPLIST_FILE: YES
      TEST_HOST: "$(BUILT_PRODUCTS_DIR)/VoiceDrop.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/VoiceDrop"
      BUNDLE_LOADER: "$(TEST_HOST)"
```
  并在 `schemes:`（没有就新建 VoiceDrop scheme 节）里挂 test target。跑通一次空测试。
- [ ] **Step 2: 失败测试**（`PromptStoreTests.swift`，覆盖，全部用内嵌 JSON fixture，不打网络）：
  - 解码：真实 GET 响应形状（含 group/children/kind/forkedFrom）解出正确字段；未知字段（`imageParams`）被忽略不炸。
  - `rawItems`：origin=system → `{ref:id}`（group 带 children 递归）；custom/user → 实体全字段（forkedFrom 有才带、kind 有才带）；**round-trip**：模板全 ref 的树序列化后不含任何 `label/prompt`（引用不携带内容）。
  - `fork`：新 id 匹配 `^p_[a-z0-9]{8}$`、forkedFrom=旧 id、origin=custom、内容字段原样保留；fork 两次 id 不同。
  - `filter`：`["text"]` 项只出现在 .text；`["text","image"]` 两边都出现；组内任一子项命中 → 组出现且只带命中子项；全不命中 → 组消失；空组不出现在菜单（但这是 filter 的行为——5a 管理页不走 filter）。
  - `menuConfig`：连续散项合一个 section、每个 group 自成 section（对齐 ConfigMenu 现有的组间厚分隔视觉）；action.prompt → UIMenuNode.instruction；group → type:"submenu"。
  - `newUserID`：格式 + 1000 次无重复。
- [ ] **Step 3: 确认失败** → **Step 4: 实现**（`rawItems` 用 `JSONSerialization` 兼容的 `[String: Any]`，PUT body 由下个任务拼）→ **Step 5: 测试绿 + 构建绿** → **Step 6: 提交**（xcodegen 已跑）。

---

### Task 3（iOS）：PromptStore 网络层 + 长按菜单切换 + 删 UIConfigStore

**Files:**
- Modify: `VoiceDropApp/PromptStore.swift`（加 `@Observable PromptStore` 网络/缓存层）
- Modify: `VoiceDropApp/ConfigMenu.swift`（把 `UIMenuNode`/`UIMenuConfig` 两个 struct 从 UIConfigStore.swift 挪进来——它们是 ConfigMenu 的输入契约；`fill` 静态函数一并挪入）
- Modify: `VoiceDropApp/RecordingDetailView.swift:329,815-833`（`UIConfigStore.shared.refresh()` → `PromptStore.shared.refresh()`；`textMenu/imageMenu(page:)` → `PromptStore.shared.menuConfig(for: .text/.image)`；`UIConfigStore.fill` → 挪去后的新家）
- Delete: `VoiceDropApp/UIConfigStore.swift`
- Test: `VoiceDropTests/PromptStoreTests.swift`（追加回退链测试）

**Interfaces:**
```swift
@MainActor @Observable final class PromptStore {
    static let shared = PromptStore()
    private(set) var items: [PromptNode]          // 当前生效列表（网络 → 缓存 → 内置 三级回退）
    var loading: Bool; var error: String?
    func refresh() async                          // GET /agent/prompts；成功缓存 UserDefaults "promptsCache.v1"
    func save() async -> String?                  // PUT 整树（rawItems(items)）；nil=成功，非 nil=错误文案；成功后用响应回填 items
    func importPrompt(code: String) async -> Result<PromptNode, String>   // POST import；成功后刷新
    func restoreDefaults() async -> Bool
    func sharePreview(code: String) async -> SharePreview?   // GET /agent/prompt-share/<code>（无 auth）
    func shareStates() async -> [String: ShareState]         // GET /agent/prompt-shares
    func setSharing(id: String, on: Bool) async -> String?   // 沿用 InstructionCustomStore.setSharing 的实现（POST/DELETE + 429 文案），搬过来
    func menuConfig(for anchor: PromptAnchor) -> UIMenuConfig // PromptLogic.menuConfig(items, for:)
}
struct SharePreview: Decodable { let label, prompt: String; let appliesTo: [String]; let kind: String?; let author: String; let importCount: Int }
struct ShareState: Decodable { let code: String; let sharing: Bool }
```
- **内置回退** = 服务端 `DEFAULT_PROMPT_TEMPLATE` 的解析形态，作为一段内嵌 JSON 字符串常量（12 条 prompt 文案**从被删的 `UIConfigStore.swift` builtin 逐字搬**——它们和服务端模板是同一批文案；id 用 `sys_*`）。三级回退：本次 GET → UserDefaults 缓存 → 内置。**任何一级失败都静默落下一级——长按永远有菜单**（照抄老 UIConfigStore 的注释纪律）。
- 网络请求全部走 `API.agentBase` + `req.setBearer(AuthStore.shared.bearer)`（惯例见原 `InstructionCustomStore.load()`）。

- [ ] **Step 1: 失败测试**（回退链：坏缓存 → 内置 15 节点；`menuConfig(.image)` 内置下 = 1 个 section 6 个子项）→ **Step 2: 实现网络层** → **Step 3: 挪 struct、删文件、改 RecordingDetailView 三处** → **Step 4: `xcodegen` + 测试绿 + 构建绿**（此刻全 app 不再引用 UIConfigStore，长按菜单已吃新数据）→ **Step 5: 提交**。

---

### Task 4（iOS）：PromptManagerView（5a 列表 + 1b 左滑删除 + 4a 导入入口）+ 设置入口切换

**Files:**
- Create: `VoiceDropApp/PromptManagerView.swift`
- Modify: `VoiceDropApp/SettingsView.swift:472`（`NavigationLink { InstructionSettingsView() }` → `NavigationLink { PromptManagerView() }`；入口文案不变「提示词」）

**视觉（照设计稿 5a，literal 全给）：**
- 顶栏：`NavSquare(systemName: "chevron.left", size: 36)` + 「提示词」26/semibold `Theme.ink` + Spacer + 36pt 方块「＋」（白 plus 于 `#D8593B` 圆角 10 块）。
- 说明行 12.5 `#8A8175`：「一套指令，长按文字或图片时按『适用于』自动筛选。灰=系统（可改不可删……其实都可删），绿=自建。」→ 新模型下都可删，文案改为：**「一套指令，长按文字或图片时按『适用于』自动筛选。改过的系统项标『已自定义』，自己建的标『自建』。」**
- 一张白卡（`SettingsCard`），行结构：34pt 圆角图标块 + 行名 15 + origin 标（**只有** custom→琥珀「已自定义」`#C98A2E`/`#FBEAD2`、user→绿「自建」`#5E8A6A`/`#EAF1EC`；system 不画标——灰是常态不用标）+ 第二行「适用于」标：都行 → 两枚灰标「文字」「图片」（10.5 `#7A6E5C` 底 `#F1ECE3` 圆角 4 内距 1×6）；仅 text → 绿「仅文字」；仅 image → 橙红「仅图片」+ `settingsChevron`。行间 `settingsRowDivider`。
- 分组行：行名旁灰字「分组 · N 项」（12 `#a79f93`），点击展开/收起（`@State expandedGroups: Set<String>`），组内行缩进 16pt 同卡渲染。分组行第二行不画适用标（组无 appliesTo）。
- **1b 左滑**：所有行（含系统项——新模型都可真删）`.swipeActions` 红「删除」→ `confirmationDialog`「删除『X』？此操作不可恢复（可用底部「恢复默认提示词」找回系统项）」→ 从 `store.items` 移除（组被删连子项一起，确认文案点明）→ `await store.save()`，失败回滚 + toast。
- 卡下方两个入口：
  - **4a 导入虚线框**：`#FBF3E9` 底、1.5pt dashed `#D8B08A` 边、圆角 12、内距 16：42pt 图标块（`#F6E4DC` 底 `square.and.arrow.down` `#D8593B`）+「输入魔法数字导入」15.5/semibold +「把别人分享的提示词存进你的菜单」12.5 `#8A8175` + chevron。下面一行 12 `#b8ae9e`：「也可以在录音时直接对 VoiceDrop 说出数字，或点开 voicedrop.cn 链接自动跳转到这里。」点击 → `PromptImportSheet`（Task 6，本任务先用空 sheet 占位可编译）。
  - **恢复默认按钮**（文字按钮 13 `Theme.accent` 居中）：「恢复默认提示词」→ confirm「把系统自带的提示词补回列表？你自建和改过的都不受影响。」→ `store.restoreDefaults()`。
- 新建「＋」→ `PromptNewSheet`（Task 5 实现，本任务先占位）。
- 加载/错误态照 `InstructionSettingsView` 现有模式（ProgressView / 错误文案 + 下拉重试）。

- [ ] Step 1 建视图骨架（列表渲染 + 展开 + 标）→ Step 2 左滑删除 + save 回滚 → Step 3 两个入口 + 设置页切换 → Step 4 `xcodegen` + 构建绿 + **模拟器截图人工比对设计稿 5a**（`xcrun simctl` boot + 截图，贴进报告）→ Step 5 提交。

---

### Task 5（iOS）：PromptEditView（5c）+ fork-on-edit + 分享卡 + PromptNewSheet（3c）

**Files:**
- Create: `VoiceDropApp/PromptEditView.swift`
- Create: `VoiceDropApp/PromptNewSheet.swift`
- Modify: `VoiceDropApp/PromptManagerView.swift`（行点击 → EditView；＋ → NewSheet）

**PromptEditView（对 action；group 只改名，简化版同页）：**
- 顶栏：返回方块 + 标题 = 行名（19/semibold）+「保存」按钮（52×34 `#D8593B` 圆角 9，dirty 才亮，逻辑照抄 `InstructionEditView` 的 dirty/保存流）。
- 字段（含设计稿 5c 全部 literal）：「菜单里的名字」13/semibold `#8A8175` → 白底输入框高 44 圆角 12；「提示词」→ TextEditor 最小高 150；**「适用于」行**：左标签 13/semibold + 右提示「决定在哪种长按里出现」12 `#b8ae9e`；下面**两个方块开关**并排（flex 均分、圆角 10、竖排 icon+文字+勾）：「文字」pencil / 「图片」photo——选中 = 1.5pt `#D8593B` 边 + icon/文字 `#D8593B` 13/semibold + 底部 `checkmark`；未选 = 1.5pt `#E5DCCB` 边 + `#a79f93` + 底部 15×15 空框（1.5pt `#D8CFC0` 圆角 4）。**至少选一个**：取消最后一个时抖动 + 不生效。**无 AI 建议琥珀条**（已砍）。
- **保存语义（核心）**：`origin == "system"` 的项一旦 dirty 保存 → 客户端 `PromptLogic.fork(node)` 实体化（新 p_ id + forkedFrom + custom）替换原位置节点 → `store.save()` 整树 PUT。custom/user 直接改字段 PUT。服务端会自动把分享码 re-key 到 fork（Task 1）。
- **分享卡**：整块 UI 从 `InstructionSettingsView.swift` 的 `shareCard`/`shareAction`/`ShareCodePayload`（:308-393）**照搬**（码大字 34 monospaced tracking 6、voicedrop.cn 短链、复制数字/复制链接/分享…、「分享的始终是已保存的版本」脚注、429 文案）。数据源换新：状态从 `store.shareStates()`（Task 1 端点）读，开关走 `store.setSharing(id:on:)`。**注意 id**：分享键 = 当前节点 id（system 项即 `sys_*`，fork 后即 `p_*`——re-key 保证连续）。origin==user/custom/system 均可分享（自建可分享是 Phase 1 的核心新能力）。
- **group 编辑**：只有名字字段；系统 group 改名同样走 fork（spec §3：fork group 只冻结 label）。

**PromptNewSheet（3c，底部 sheet）：**
- 抓手条 + 标题「新建」17/semibold 居中 + 两个白卡选项行（圆角 10、1px `#ECE3D5`、内距 15、间距 13、右 chevron）：
  - 44pt 图标块 `#EAF1EC` pencil `#5E8A6A` +「**新建动作**」16/semibold +「一条提示词指令」12.5 `#8A8175` → 进 EditView（新实体：`PromptLogic.newUserID()`、origin=user、appliesTo=`["text","image"]` 都行预勾、空名空词，保存时追加到列表末尾）。
  - 44pt 图标块 `#F1ECE3` folder `#7A6E5C` +「**新建分组**」16/semibold +「收纳几个动作，菜单里成二级子菜单」12.5 → 弹名字 alert → 追加空组（拖动进组在 Task 7）。

- [ ] Step 1 EditView 字段 + 开关 + fork 保存（含**取消 fork 场景测试**：dirty 后又改回原值 → 不 fork 不 PUT）→ Step 2 分享卡接新端点 → Step 3 NewSheet 两条路 → Step 4 `xcodegen` + 构建绿 + 截图比对 5c/3c → Step 5 提交。

---

### Task 6（iOS）：PromptImportSheet（4b）+ universal link 进导入

**Files:**
- Create: `VoiceDropApp/PromptImportSheet.swift`
- Modify: `VoiceDropApp/AppRouter.swift:82-90`（`universalLink`：voicedrop.cn/<path> 若 path 匹配 `^[1-9][0-9]{6}$` → 新 case `.promptImport(code)`；文章分享 id 是 10 位 hex、社区 12 位，纯 7 位数字无歧义）
- Modify: RootView/LibraryView 的 DeepLink 分发处（跟着 `.shareLink` 现有处理找到 switch，加 `.promptImport` → 打开 PromptManagerView 并弹 ImportSheet 预填码）

**PromptImportSheet（4b literal）：**
- 标题「导入提示词」17/semibold +副题「输入 7 位魔法数字，或粘贴分享链接」12.5 `#8A8175`。
- 输入框：白底圆角 12 内距 14，聚焦 1.5pt `#D8593B` 边；内容 30/bold monospaced tracking 8 居中；`keyboardType(.numberPad)`；**粘贴含链接自动抽码**（正则 `[1-9][0-9]{6}`）。
- 输够 7 位自动 `store.sharePreview(code:)` → 预览卡（白卡圆角 12 内距 15）：适用标（复用 5a 的标组件）+ 名字 17/semibold + 提示词全文 13.5 `#5b5349` 行高 1.7 + 来源行 12 `#b8ae9e`「来自 {author} · 已被导入 {N} 次」（**author 为空串 → 整行只显示「已被导入 N 次」；N==0 → 不显示次数**）。
- 查无/失效 → 卡片位置错误文案「这个魔法数字无效或已停止分享」。
- 主按钮「加入我的提示词」（`#D8593B` 圆角 12 内距 15 白 16/semibold 全宽）→ `store.importPrompt(code:)` → 成功关 sheet、列表滚动到新行并 2 秒高亮（`#FBF3E9` 底渐隐）。
- 脚注 12 `#b8ae9e` 居中：「导入后是你自己的副本，可改名、改内容、随时删除；原作者之后的修改不影响你。」

- [ ] Step 1 sheet UI + 自动解析 + 错误态 → Step 2 导入 + 回列表高亮 → Step 3 AppRouter 分支 + 分发（**测试**：模拟器 `xcrun simctl openurl booted "https://voicedrop.cn/1234567"` 应落到导入 sheet 且预填）→ Step 4 构建绿 + 截图比对 4b → Step 5 提交。

---

### Task 7（iOS）：1d + 1a 拖动排序 / 拖进分组

**Files:**
- Modify: `VoiceDropApp/PromptManagerView.swift`

**行为（1d literal）：**
- 长按任意行 → 进排序态：顶栏右上变「完成」（15/semibold `#D8593B`，＋隐藏）；每行左侧出 3 横线拖动手柄（`#C9C0B1`）；被拖行 `scale(1.03)` + 投影 `0 12 26 rgba(60,48,30,0.22)` + 1px `#EBD9B8` 边、手柄变 `#D8A25B`。
- 实现用 SwiftUI `List` + `.onMove`（顶层与组内各自 onMove）；**拖进/拖出分组**用 drop target：拖动中分组行高亮 1.5pt dashed `#D8A25B` 边 +「拖到这里收进分组」提示，drop 到分组行 = 移入该组末尾；组内行拖到组外 = 移出。**两级封顶：分组行本身不可拖进别的分组**（drop 到分组行时若拖的是 group → 忽略 + 触觉反馈）。
- 「完成」→ 一次 `store.save()`（整树 PUT 天然承载排序/分组——这就是当初选整树写的原因）。失败回滚 + toast。

- [ ] Step 1 排序态 UI + onMove → Step 2 跨组 drop（进/出/组不进组）→ Step 3 完成时 PUT + 回滚 → Step 4 构建绿 + 手测录屏（排序、进组、出组、杀 app 重进顺序仍在）→ Step 5 提交。

---

### Task 8：删老文件 + 全量验证 + STATE.md + TestFlight

- [ ] **Step 1: 删 `VoiceDropApp/InstructionSettingsView.swift`**（分享卡已在 Task 5 搬走；grep 全仓确认无引用）+ `xcodegen`。
- [ ] **Step 2: 全量验证**：单测绿 + 构建绿 + 模拟器手测清单：① 设置→提示词打开新列表（**不再「加载失败」**）② 长按文字/图片菜单 = 列表过滤视图，新建的文字项立刻出现在长按文字菜单 ③ 改一条系统项 → 标变「已自定义」→ 长按菜单吃到新词 ④ 删除→恢复默认找回 ⑤ 导入码全流程 ⑥ 分享开关 + fork 后码不变 ⑦ 断网 → 长按菜单仍有（内置回退）。
- [ ] **Step 3: 更新 `STATE.md`**：Phase 2 上线段（新文件清单、PromptStore 三级回退、fork-on-edit 语义、AppRouter 7 位数字分支、测试 target 的存在与跑法）；标注 spec/plan 路径。
- [ ] **Step 4: 提交 + push main → CI 自动 TestFlight**（`build.yml` push 触发；**push 前向用户确认**——这是发版动作）。

---

## Self-Review

- **Spec §9 对照**：PromptStore（模型/整树/过滤）✓T2-3；PromptManagerView（5a/1b/1d/1a/4a/＋）✓T4+T7；PromptEditView（5c 两开关/分享卡）✓T5；PromptNewSheet（3c）✓T5；PromptImportSheet（4b）✓T6；ConfigMenu 改吃过滤列表、视觉不动 ✓T3；fork = 客户端实体化 ✓T5；「恢复默认」双语义 ✓T4/T5（单条恢复：spec 说「换回 ref」——**T5 未做单条恢复按钮，简化为整体恢复**，5c 里改回原值不 fork 即等效；记为有意裁剪）；删两个老文件 ✓T3/T8。
- **AI 建议琥珀条**：spec 已划掉，T5 明确不做 ✓。
- **imageParams**：全局约束声明不解码，风险（fork 丢字段）已论证为当前零数据 ✓。
- **终审遗留③**（registry 无 MAX_PROMPT 上限，admin-only）：**本计划不做**，留 STATE.md。
- **类型一致性**：`PromptNode`/`PromptAnchor`/`PromptLogic.*`/`PromptStore.*` 签名 T2 定义、T3-7 引用一致；`UIMenuConfig` 挪家后 T3-T7 均从 ConfigMenu.swift 引用 ✓。
