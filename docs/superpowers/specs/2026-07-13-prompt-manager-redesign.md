# Prompt Manager 重构 — 一套有序列表 · 引用/实体化 · 魔法数字导入

设计稿：`design_handoff_prompt_manager/`（`Prompt Manager.dc.html`，定稿 = 第 5 轮 5a/5b/5c + 第 4 轮 4a/4b + 1b/1d/1a）
日期：2026-07-13

---

## 1. 为什么重构

今天一条指令的**身份就是它的菜单路径**（`voice-editor.longpress.image.style.cartoon`）。
`image` / `text` 是 id 的一段 —— "我出现在哪个菜单"焊死在主键里。由此四件事做不到：

| 做不到 | 根因 |
|---|---|
| 新建自己的提示词 | `PUT /agent/ui-config/custom` 里 `if (!flat.some(p => p.id === body.id)) return 404` —— 列表是从系统目录打平出来的，用户加不进东西 |
| 删除 | 只有 `hidden`。条目属于目录不属于用户，删了下次读又回来 |
| 排序 / 分组 | 顺序和分组写死在目录里，用户文件里没有"顺序"这个概念 |
| 改「出现在哪个菜单」 | 菜单归属 = id 路径。改它就得改主键，已有覆盖和已铸分享码全断 |

另外：分组节点没有 `instruction`，`flattenPrompts` 不收，所以**今天的设置页根本看不见分组**，只看得见 12 条叶子。

## 2. 新模型：引用 / 实体化（ref → fork）

### 核心洞察

**大多数用户不会自己写 prompt。他们应该永远吃到系统调优后的最新版本。**
所以「跟随系统」是默认，「拥有自己的副本」是例外。

用户列表里的每一项只有两种形态：

- **`{"ref": "sys_cartoon"}`** —— 我没动过这条，用系统的。读的时候**整条**去模板取，所以模板一调优，用户立刻吃到。
- **完整条目** —— 这条是我的。冻结，系统不再碰。

解析逻辑只有两行，**没有合并、没有打补丁**：

```
每一项：有 ref → 整条去模板取（模板里没有了 → 跳过）
        没 ref → 原样用
```

### 关键性质

**没有 `prompts.json` 的用户，服务端直接返回模板** —— 等价于一棵全是 `ref` 的树。不折腾的大多数永远吃最新。

**轻度触碰不冻结全局。** 用户新建一条「写成小红书」或用魔法数字导入一条，他的文件里只是多一条完整条目，那些系统项**仍然是 `ref`，继续跟随最新**。
（这是"全量副本"模型的致命坑：导入一条别人的提示词，就把 12 条系统 prompt 全冻结了 —— 而导入恰恰是本次的主打功能。）

**只有真的改了某条系统 prompt 的字**，那一条才从 `ref` 实体化成完整副本（fork），只冻结那一条。这正是用户明确要的："这条我要我自己的版本"。

**`ref` 的有无天然表达 origin**，5a 的三种标不需要额外字段：

| 形态 | 5a 显示 |
|---|---|
| `{"ref": "sys_*"}` | 灰标「系统」 |
| 实体 + `forkedFrom: "sys_*"` | 琥珀标「已自定义」 |
| 实体，无 `forkedFrom` | 绿标「自建」 |

## 3. 数据结构

### 系统模板（真源）

`agent/src/prompt-template.js` 里的字面量 `DEFAULT_PROMPT_TEMPLATE`；
R2 `config/prompt-template.json` 存在且形状合法则**整体覆盖**（沿用 ui-config 的零部署覆盖机制）。

**模板的形状 = 用户列表的形状**（一个有序树，两级封顶），不再是老的 `pages.longpress.image/.text` 两棵树。

```json
{
  "schema": 1,
  "items": [
    { "id": "sys_style", "type": "group", "label": "图片风格", "children": [
      { "id": "sys_cartoon", "type": "action", "label": "卡通",
        "prompt": "把这张图（[[photo:{{KEY}}]]）重画成宫崎骏动画的手绘卡通风格…",
        "appliesTo": ["image"] },
      { "id": "sys_ad", "type": "action", "label": "广告", "prompt": "…", "appliesTo": ["image"] }
    ]},
    { "id": "sys_wechat_cover", "type": "action", "label": "公众号题图",
      "prompt": "…", "appliesTo": ["text"], "kind": "image" }
  ]
}
```

`sys_*` id 是**稳定但无语义**的键 —— 不编码菜单归属、不编码层级。菜单归属是 `appliesTo` 这个数据字段。

### 用户文档

`users/<sub>/prompts.json`：

```json
{
  "schema": 1,
  "items": [
    { "ref": "sys_style", "children": [ {"ref": "sys_cartoon"}, {"ref": "sys_ad"} ] },
    { "id": "p_zq1f6e", "type": "action", "label": "写成小红书",
      "prompt": "口语、多用 emoji、分点、结尾加话题标签…", "appliesTo": ["text"] },
    { "id": "p_8k2m4a", "type": "action", "label": "卡通风", "prompt": "我改过的…",
      "appliesTo": ["image"], "forkedFrom": "sys_cartoon" }
  ]
}
```

**数组顺序即显示顺序；`children` 即分组。** 排序 = 改数组顺序；拖进分组 = 挪进 `children`。

### 节点字段

| 字段 | 说明 |
|---|---|
| `ref` | 指向模板 `sys_*` id。有 `ref` 就没有其他内容字段（`children` 除外，见下） |
| `id` | 实体条目主键，`^p_[a-z0-9]{6,}$`，客户端生成，服务端校验格式 + 唯一 |
| `type` | `action` / `group`。group 是容器，无 `prompt` / `appliesTo` |
| `label` | 名称，≤ 40 字 |
| `prompt` | 提示词，≤ 4000 字（沿用 `PROMPT_SHARE_DEFAULTS.maxLength`） |
| `appliesTo` | `["text"]` / `["image"]` / `["text","image"]`，至少一个。**仅 action** |
| `children` | 仅 group，元素只能是 action（两级封顶） |
| `forkedFrom` | 可选，实体条目从哪个 `sys_*` fork 而来。驱动「已自定义」标 + 防止「恢复默认」重复补 |
| `kind` | 可选，`"image"` = 产出为图片。**本期存 + 透传，不做 UI** |
| `imageParams` | 可选，`{aspect, count}`。**本期存 + 透传，不做 UI**（用户已确认推迟） |

**`appliesTo`（在哪出现）和 `kind`（产出什么）是两件事。** 「插入图片 · 公众号题图」的 `appliesTo` 是 `["text"]`（它出现在长按文字的菜单里），`kind` 是 `"image"`（它产出一张图）。

### ref 分组的 children

一个 `{"ref": "sys_style"}` 的 group 仍然带 `children` 数组 —— 因为**分组的成员关系归用户管**（他可以把 `sys_cartoon` 拖出去、把自建的拖进来）。group 的 `label` 跟随模板，成员由用户列表决定。

**改分组的名字 = fork 这个 group**（和 action 一样）：变成实体 `{"id":"p_*", "type":"group", "label":"我的名字", "forkedFrom":"sys_style", "children":[…]}`。
成员关系本来就归用户管，所以 fork group 只冻结它的 **label**（group 没有 prompt / appliesTo）。这保持了"实体化 = 我要我自己的版本"这一条规则的一致性，不给 group 开特例。

## 4. 解析（GET /agent/prompts）

```
无 users/<sub>/prompts.json  →  返回模板全量（每条 origin: "system"）
有                          →  逐项：
                                 ref  → 模板查表；查不到 → 跳过（模板删了这条）
                                 实体 → 原样
```

服务端为每条计算 `origin` 返回给客户端：`system`（来自 ref）/ `custom`（实体 + forkedFrom）/ `user`（实体，无 forkedFrom）。

**不做「模板新增项自动追加」。** 用户一旦有了自己的文件，新系统 prompt 靠「恢复默认提示词」按钮拿。
理由：自动追加会把用户**主动删掉**的条目塞回来，要修就得引入 `deleted: []` 墓碑列表 —— 多一个字段，换一个用户不可控的行为。一个按钮同时是"我删多了想找回来"的后悔药和"拿系统新出的 prompt"的入口。

## 5. 长按菜单 = 过滤视图（5b）

```
解析后的列表 ──filter(appliesTo 含 "image")──→ 长按图片的菜单
             └─filter(appliesTo 含 "text") ──→ 长按文字的菜单
```

**分组规则：组里只要有任一子项命中过滤，这个组就出现**（组本身没有 `appliesTo`）。空组不出现在菜单里（但出现在 5a 管理页）。

新 app **只拉一次 `/agent/prompts`**，同一份数据同时喂 5a 管理页和两个长按菜单，客户端过滤。不再需要服务端下发菜单。

⚠️ **因此过滤逻辑只存在于 iOS（Phase 2），服务端没有这段代码，也没有对应的 vitest。** 过滤的单测在 Phase 2 用 Swift 写。

## 6. 端点

### 新增

| 端点 | 说明 |
|---|---|
| `GET /agent/prompts` | → `{schema:1, items:[已解析, 带 origin]}` |
| `PUT /agent/prompts` | body `{items:[...]}` 整棵树。新建/删除/改名/改词/排序/分组/fork **全走这一个写**。校验后落盘，返回解析结果 |
| `POST /agent/prompts/restore-defaults` | 把模板里**缺的**（既不在 ref 里、也不是任何条目的 `forkedFrom`）补回列表末尾。返回解析结果 |
| `POST /agent/prompts/import` | body `{code}` → 追加一条实体副本（`origin: user`，无 `forkedFrom`），`importCount` +1。返回 `{item}` |
| `POST /agent/prompt-classify` | body `{prompt}` → `{appliesTo, reason}`。AI 建议默认适用范围（5c 的琥珀条） |
| `GET /agent/prompt-share/<code>` | → `{label, prompt, appliesTo, kind, author, importCount}`。4b 的导入预览 |

**写操作只有整树 PUT。** 拖动排序、拖进分组、删除、新建 —— 全都只是"树变了，写回去"。客户端本来就整棵树拿在手里，不存在局部更新竞态。

### PUT 校验（违反 → 400）

- 两级封顶：`group.children` 元素只能是 action，group 不能套 group
- `ref` 必须存在于模板
- 实体 `id` 格式 `^p_[a-z0-9]{6,}$`，全树唯一
- action 的 `appliesTo` 非空且 ⊆ `{text, image}`；group 不带 `appliesTo` / `prompt`
- `label` ≤ 40，`prompt` ≤ 4000
- 全树条目数 ≤ 200（防滥用）

### 改造

- **`prompt-registry`**（`prompt.jianshuo.dev` 调优桥接页）：改成读写新模板。对外响应形状 `{prompts:[{id,label,instruction}]}` **保持不变**，只是 `id` 从语义路径变成 `sys_*`（桥接页把 id 当不透明串用）。
- **`prompt-share`**（铸码 / 关码）：`effectiveLeaf` 改走新解析器 —— 这才**第一次让自建提示词能被铸码分享**（今天对自建项铸码会直接失败，而没有这个，导入功能没有意义）。写穿副本 `sharedDocFor` 增加 `appliesTo` + `kind`。

### 删除

- `GET /agent/ui-config`、`GET/PUT /agent/ui-config/custom`（用户已确认：不管老 app）
- `agent/src/ui-config.js`（→ `prompt-template.js`）、`agent/src/ui-config-custom.js`
- `agent/test/ui-config.test.js`、`agent/test/ui-config-custom.test.js`
- iOS `UIConfigStore.swift`、`InstructionSettingsView.swift`

### 明确不做迁移

用户已确认：**老 `users/<sub>/ui-config.json`（改名/改词/隐藏）不迁移**，大家从新模板重新开始。

**老魔法数字继续能兑换**（与用户初选相反 —— 已当面纠正并采纳）：`shares/<码>` 存的是 label+instruction 的写穿副本，兑换路径（语音报号 `resolveSharedPromptBlock` / 4b 导入）直接读副本，**不需要 `itemId`**。让它们活着是零成本，作废反而要专门写删除代码，且会把已发在微信里的 `voicedrop.cn/<码>` 变成死链。
代价：老码的「作者改词后自动同步分享副本」链断掉（`refreshPromptShare` 按新 id 索引），副本停在铸码当时那版。可接受。
老副本缺 `appliesTo` → 4b 预览回退 `["text","image"]`（都行）。

## 7. `prompt-classify`（5c 的 AI 建议）

一次便宜的 haiku 调用，走现有 `llmlog` + `usage` best-effort 计费。

**绝不能挡住用户新建提示词。** 调用失败 / 算力不足 / 超时 → 返回 `{appliesTo: ["text","image"], reason: ""}`，5c 的琥珀提示条不渲染，两个开关都预勾。

用户手动改过之后以手动为准，不再覆盖（客户端状态，服务端无需记）。

## 8. 魔法数字导入（4a / 4b）

- **4a 入口**：5a 列表底部虚线框「输入魔法数字导入」。
- **4b sheet**：7 位数字输入（或粘 `voicedrop.cn/<码>` 链接）→ 输够自动 `GET /agent/prompt-share/<code>` → 预览卡（适用标 + 名字 + 提示词全文 + 「来自 X · 已被导入 N 次」）→「加入我的提示词」→ `POST /agent/prompts/import`。
- **语义**：导入 = 独立自建副本（实体，`origin: user`，无 `forkedFrom`），可改名/改词/删；**原作者之后的修改不影响你**。这与分享码的"一次性语音使用"是两条路。
- 无效 / 已失效码 → 预览卡位置显示错误。

**`author`**：复用 Pages Function 里已有的 `readProfileName(env, scope)`（从 `CLAUDE.md` / `CLAUDE.json` 读用户名）。把它从 `functions/files/api/[[path]].js` 提到 `functions/lib/profile.js`，worker 侧 import（worker 已经在 import `functions/lib/auth.js`，路径通）。读不到名字 → 不显示「来自」行。

**`importCount`**：存在 `shares/<码>` 文档里，`refreshPromptShare` 保留它（如同已有的 `createdAt`）。R2 没有原子自增，**并发导入偶尔丢计数 —— 接受**（虚荣数字）。

## 9. iOS

删 `UIConfigStore.swift` / `InstructionSettingsView.swift`。新增：

| 文件 | 内容 |
|---|---|
| `PromptStore.swift` | 模型（`PromptNode`、`PromptOrigin`、`AppliesTo`）+ `PromptStore`（load / save 整树 / import / classify / restoreDefaults）+ 过滤（`menu(for: .text/.image)`） |
| `PromptManagerView.swift` | **5a** 一套列表：白卡、34pt 图标块、origin 标（灰/琥珀/绿）、「适用于」标（都行两枚灰 / 仅文字绿 / 仅图片橙红）、分组行「分组 · N 项」、**1b** 左滑删除（二次确认）、**1d/1a** 长按进排序态（拖动手柄、拖起 1.03 + 投影、拖到分组虚线高亮收进）、**4a** 底部虚线导入入口、右上「＋」 |
| `PromptEditView.swift` | **5c** 名称 + 提示词 + **「适用于」两个方块开关**（至少选一个；选中 = 1.5px `#D8593B` 边 + 底部对勾）+ AI 建议琥珀条 + 分享卡（沿用现有 `InstructionEditView` 的魔法数字 UI） |
| `PromptNewSheet.swift` | **3c** 底部 sheet 两项：新建动作 / 新建分组 |
| `PromptImportSheet.swift` | **4b** 7 位大号等宽数字输入（letter-spacing 8）+ 预览卡 + 「加入我的提示词」 |

`ConfigMenu.swift` 改造：不再吃 `UIMenuConfig`，改吃 `PromptStore` 过滤后的列表。视觉不动。

**编辑一条 `ref` 系统项 = 客户端把它实体化**（生成 `p_*` id，拷贝模板内容，带上 `forkedFrom`），整树 PUT。fork 是客户端行为，服务端只校验。

**「恢复默认」**：单条恢复 = 把实体条目换回 `{ref: forkedFrom}`；整体恢复 = `POST /agent/prompts/restore-defaults`。

## 10. 设计 token（照设计稿精确还原）

- 页面 / sheet 背景 `#FAF6EF`；遮罩 `#EFEAE0`
- 卡片：白 `#fff` / 1px `#ECE3D5` / 圆角 5px（大卡）· sheet 10–14px；行分隔 `#F0E8DA`
- 文字：主 `#2A2521` / 次 `#8A8175` / 弱 `#b8ae9e` / 组标题 `#a79f93` / 提示词正文 `#5b5349`
- 适用标：都行灰 `#7A6E5C` 底 `#F1ECE3`；仅文字绿 `#5E8A6A` 底 `#EAF1EC`；仅图片橙红 `#D8593B` 底 `#F6E4DC`
- origin 标：系统 `#9a9184`/`#F1ECE3`；已自定义 `#C98A2E`/`#FBEAD2`；自建 `#5E8A6A`/`#EAF1EC`
- 强调 / 删除 / ＋ `#D8593B`；拖动高亮 `#D8B08A`~`#D8A25B`；AI 琥珀 `#B98A3E` 底 `#FBF3E9` 边 `#EBD9B8`
- 字号：页标题 26 / 编辑页 19、行名 15、说明 12.5、标 10.5、导入数字 30（monospace）

字体 -apple-system / PingFang SC。复用现有 `Theme` / `SettingsCard` / `SettingsRow` / `NavSquare`。

## 11. 测试（`agent/test/prompts.test.js`）

解析：
- 无 `prompts.json` → 返回模板全量，全部 `origin: system`
- **模板改了 prompt → `ref` 项跟着变**（核心性质）
- fork 一条 → 只有那条冻结，其余仍跟随模板
- 模板删了一条 → 悬空 `ref` 跳过，不崩
- 空组：出现在 5a，不出现在菜单

校验（400）：两级封顶 / 未知 ref / id 格式 / id 重复 / `appliesTo` 空 / 超长 / 超 200 条

`restore-defaults`：补回缺的；**已 fork 的不重复补**（认 `forkedFrom`）

`import`：追加实体副本、`importCount` +1、无效码 404

`prompt-classify`：Claude 挂 / 无算力 → 回退 `["text","image"]` + 空 reason（不 500）

`prompt-share`：对 `ref` 项铸码（读解析后的有效内容）、对自建项铸码（今天会失败）；老副本无 `appliesTo` → 预览回退都行

`prompt-registry`：响应形状 `{prompts:[{id,label,instruction}]}` 不变

## 12. 分期

- **Phase 1 — 服务端**：模板 + 解析器 + 6 个端点 + 改造 registry/share + 删旧。vitest 全绿。**独立可部署**。
- **Phase 2 — iOS**：5 个新文件 + `ConfigMenu` 改造 + 删旧两个文件。

Phase 1 上线后老 app 的长按菜单会退回 app 内置默认（`UIConfigStore.refresh()` 失败路径是静默保留现值，不崩），老设置页显示加载失败 —— **用户已确认接受**。所以 Phase 1 和 Phase 2 之间的窗口越短越好，Phase 2 一好就发 TestFlight。
