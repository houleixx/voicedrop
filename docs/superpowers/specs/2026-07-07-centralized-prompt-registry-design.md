# 提示词中心化注册表 + 分层可配置 — 设计

日期：2026-07-07
后端代码：`~/code/jianshuo.dev/agent/src/`（Cloudflare Pages/Worker）
相关既有 spec：`2026-07-04-longpress-actions-menu-design.md`（ui-config 三层机制，本设计的直系母版）、`2026-07-03-style-field-schema-design.md`（文风 Style Card = 成文的每用户语气层）

## 一句话

把散落在 8 个文件里的核心提示词全部收进 `prompts/` 一个中心目录、聚成一张带元数据的注册表，并把 ui-config 已经跑通的「内置默认 ← 全局 R2 零部署覆盖 ← 每用户稀疏覆盖」三层机制从「长按菜单指令」扩展到「所有提示词」。每条提示词拆成**锁死的结构骨架** + **可覆盖的语气槽**：结构契约永远改不坏，语气按档位分别开放给管理端（零部署全局调）或每个用户（各自覆盖）。moderation / 工具路由等安全线彻底锁在代码里。**客户端 APP 零改动。**

## 核心决策（已与用户确认）

| 决策 | 选择 | 理由 |
|---|---|---|
| 谁来改、什么粒度 | **两者都要，分层**：管理端零部署集中调全局默认 + 部分安全项开放给用户各自覆盖 | 用户 2026-07-07 确认 |
| 防改坏方式 | **结构/语气两层拆开**：每条提示词 = 锁死结构骨架（JSON 契约/行号/工具说明）+ 可覆盖语气槽 `{{VOICE}}` | 用户 2026-07-07 选定；用户只能换语气那块，成文结构永远改不坏 |
| 成文的每用户语气 | **不另造 per-user 覆盖，继续用文风 `<style>` 注入** | 文风（蒸馏/偷师/restyle）已经是成文的每用户语气层；再造一套会和文风打架。YAGNI |
| moderation / 工具路由 SYSTEM | **归 `locked` 档，永不进配置** | 内容安全线不能被任何配置层削弱；工具路由改错会让 agent 失能 |
| 中央调优台 | **prompt.jianshuo.dev 升级为所有 `global` 档提示词的调优台** | 复用现有 prompt-registry + prompt-lab 桥接；管理端一个地方调全部 |
| 命名空间隔离 | **核心提示词注册表用 `config/prompts.json` + `/agent/prompts`，与 ui-config（`config/ui-config.json` + `/agent/ui-config`）完全分开** | APP 现在唯一跟提示词相关的拉取是 `/agent/ui-config`；隔开命名空间 = APP 契约一字节不变 |
| 写入校验 | **管理端全局写也校验**：骨架关键标记 + `{{VOICE}}` 槽必须保留，缺了拒绝保存 | 给结构契约兜底，管理端手滑也改不崩成文 |

## 现状（调查所得，2026-07-07）

提示词共 ~17 处：
- **已在 `prompts/`（9 处）**：`mine.js`（`MINE_SYSTEM`/`PHOTO_INSTR`/`MINE_SYSTEM_FORCE`/`IMAGE_ONLY_SYSTEM`/`MINE_DEFAULT_STYLE`）、`image-pipeline.js`（`OBSERVE`/`PLAN`/`WRITE`/`REVIEW` 四阶段）。硬编码 `export const`，git 即版本控制。
- **内联散落（8 处）**：`index.js`（`REVISE_SYSTEM` 改稿规则、`SYSTEM` 编辑 agent 主 system）、`command-turn.js`（`COMMAND_SYSTEM` 库级指令）、`tools.js`（merge_articles 内联 system、`add_followups` 追问 desc、`edit_photo`/`new_photo` desc）、`miner.js`（moderation `system` + `MOD_CATEGORIES`）、`style-extract.js`（`DISTILL_SYSTEM` 文风蒸馏）。

已有可配置基础设施（只覆盖菜单指令，不覆盖核心 prompt）：
- **ui-config.js** — `DEFAULT_UI_CONFIG` 字面量 ← R2 `config/ui-config.json` 全局覆盖 ← `users/<sub>/ui-config.json` 每用户稀疏覆盖；`loadUIConfigFor(env, scope)` 三层合并；scope 隔离。
- **prompt-registry.js** — `GET/PUT /agent/prompt-registry`，管理 token（`Bearer FILES_TOKEN`），`flattenPrompts`/`updatePrompt` 打平/回写 ui-config 叶子，PUT 写 R2 零部署上线。
- **组装函数已留形参**：`buildMinePrompt`（`miner.js:536` 有 `systemPrompt` 形参）、`buildStagePayload`（`image-pipeline.js:115`）当前只接受代码内常量，**没接到 R2 读取路径**——这就是要补的那根线。

## 架构

### 1. 中心目录（「合并」）

把 8 处内联提示词搬进 `prompts/`，按域拆文件，源字面量仍是真源（保 git 版本化 + eval harness 字节一致）：

```
agent/src/prompts/
  mine.js            (既有)
  image-pipeline.js  (既有)
  edit.js            (新：REVISE_SYSTEM + 编辑 agent SYSTEM，从 index.js 搬)
  command.js         (新：COMMAND_SYSTEM，从 command-turn.js 搬)
  style.js           (新：DISTILL_SYSTEM，从 style-extract.js 搬)
  moderation.js      (新：moderation system + MOD_CATEGORIES，从 miner.js 搬；locked)
  tool-desc.js       (新：merge/add_followups/edit_photo/new_photo 工具说明)
  index.js           (新：注册表 — 聚合上面所有条目成一张扁平 catalog)
```

### 2. 注册表条目形状

`prompts/index.js` 把每条提示词登记成带元数据的条目。骨架里用 `{{VOICE}}` 标语气槽（`voice` 档才有）：

```js
// 概念形状，非最终字段名
{
  id: "mine.system",              // 稳定路径 id
  label: "挖矿成文 · 主 system",
  tier: "global",                 // locked | global | voice
  skeleton: MINE_SYSTEM,          // 锁死结构骨架（含 JSON 契约、追问块、{{VOICE}} 槽）
  voiceDefault: null,             // voice 档才有：语气槽默认片段
  requiredTokens: ["{{VOICE}}", /* JSON 契约关键标记 */],  // 写入校验用
}
```

三档：
- **`locked`** — 只读源字面量，不读任何 R2/用户层。moderation、工具路由 SYSTEM。
- **`global`** — 默认 ← R2 `config/prompts.json` 覆盖（管理端零部署）。多数核心 system 骨架。
- **`voice`** — 骨架 `global` 层不变，`{{VOICE}}` 槽的片段可被 `users/<sub>/prompts.json` 每用户覆盖。**注意：成文 mine 不设 voice 槽**（语气走文风 `<style>`）；voice 档留给将来特意加语气槽的提示词。

### 3. 分层解析（照抄 ui-config）

```
loadPromptsFor(env, scope):
  base       = DEFAULT catalog（源字面量）
  global     = R2 config/prompts.json（存在且合法则覆盖 global 档的 skeleton）
  perUser    = users/<sub>/prompts.json（只覆盖 voice 档的语气片段，scope 隔离）
  → 合并出该用户生效版
```
`buildMinePrompt` / `buildStagePayload` 改为从 `loadPromptsFor` 取 resolved 骨架，替代硬编码 import。`<style>` 注入逻辑不动。

### 4. 端点（本期几乎零新 API：复用 + 扩展，不新建用户侧端点）

**本期只动一个端点 + 一个新存储文件**，用户已 2026-07-07 确认「复用为主，只多一个独立配置文件，管理端 API 是扩展不是新建」：

| 端点 | 用途 | 认证 | 存储 | 本期 |
|---|---|---|---|---|
| `GET/PUT /agent/prompt-registry`（**扩展**） | 管理端全局调，扩成同时覆盖 ui-config 菜单叶子 + 核心提示词 `global` 档 | `Bearer FILES_TOKEN` | `config/prompts.json`（新，独立于 ui-config） | ✅ 做 |
| `GET /agent/prompts` | 面向客户端拉核心提示词生效版 | 用户 token / scope | — | ⏸ 不做（APP 不拉核心提示词） |
| `PUT /agent/prompts/custom` | 每用户语气覆盖（照 `ui-config-custom.js`） | 用户 token / scope 隔离 | `users/<sub>/prompts.json` | ⏸ 不做（本期 voice 档 0 个） |

**为什么不塞进 ui-config 那个文件/端点**：`/agent/ui-config` 是 **APP 会下载**的（渲染长按菜单）。把服务端 system prompt 塞进同文件，APP 每次拉都会把它们全下载走——白白变胖，且 **moderation 安全线会随之下发到客户端**。故存储必须分开：核心提示词走独立 R2 `config/prompts.json`，不进 APP 下载路径。

**为什么用户侧两端点本期不做**：本期 voice 档 0 个（成文语气走文风），没有任何核心提示词开放给用户各自改，APP 也不拉核心提示词——这两个端点无消费者。等**将来出现第一条 voice 提示词**时再加，直接复刻 `ui-config-custom.js`。

prompt.jianshuo.dev 消费 `/agent/prompt-registry` 的扩展列表，成为所有提示词的中央调优台（前端零改动，自动多出核心提示词条目）。

### 5. 写入校验

`PUT` 写回前跑校验：resolved 结果必须包含该条目 `requiredTokens` 全部标记（`{{VOICE}}` 槽、JSON 契约关键串、行号规则串等）。缺任一 → 400 拒绝，不落 R2。管理端全局写、用户语气写都过这道闸。

## 客户端 APP 影响

**零改动。** 理由：
- 成文/改稿/文风蒸馏/图片流水线全在服务端执行，APP 只传音频、读文章，感知不到提示词变化。
- per-user 语气要的两个入口 APP 已有：「设置 → 写作风格」（文风）+ 长按菜单自定义（`ui-config-custom`）。方案故意复用，不新增设置页。
- 核心提示词注册表用独立存储 `config/prompts.json`（不进 APP 下载路径），APP 现在唯一相关拉取 `/agent/ui-config` 保持不动。本期不新增任何面向客户端的端点。
- **唯一会动 APP 的将来情况**（本期范围外）：给某条提示词加一个既不属于文风也不属于菜单的新语气槽、且要 APP 内编辑——才需复刻 `InstructionSettingsView` 加设置页。

## 迁移与测试

- **搬迁保字节一致**：8 处内联搬进 `prompts/` 时，源字面量内容一字不改。加**快照测试**：对每条提示词 resolved 结果做 golden 快照，搬迁前后 diff 必须为空（eval harness 依赖挖矿 prompt 字节稳定）。
- **接线低风险**：`buildMinePrompt`/`buildStagePayload` 早有形参，改的是调用点取值来源。
- **端点/UI 大量复用** ui-config / prompt-registry / ui-config-custom 现成代码。
- **champion 提升可选零部署化**：`wjs-evaling-voicedrop-prompts` 的 champion 现在走 git 改 `mine.js`；接入后可选走 R2 `config/prompts.json` 零部署上线（也可继续走 git，两条路都通）。

## 非目标（YAGNI）

- 不给成文造第二套 per-user 语气（用文风）。
- 不把 moderation / 工具路由做成可配置。
- 不做 SDUI 富组件、不改 APP UI。
- 不改 ui-config 现有形状与端点。
- 本期不新增任何 voice 档实例（只把机制和档位立起来；voice 槽等有真实需求再逐条加）。

## 分档清单（初稿，实现时逐条定档）

| 提示词 | 档 |
|---|---|
| mine.system / mine.force / image-only | global |
| image-pipeline observe/plan/write/review | global |
| edit.revise / edit.system | global |
| command.system | global |
| style.distill | global |
| merge / add_followups / edit_photo / new_photo 工具说明 | global |
| moderation system + 类别 | **locked** |
| 编辑 agent 工具路由核心（若与 edit.system 可分离的路由骨架） | **locked** |
| voice 档实例 | 本期 0 个（机制预留） |
