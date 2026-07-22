# 导入件再分享 · 溯源转发（prompt 不变，码就不变）— design

日期：2026-07-22 · 状态：已批准（对话中定稿：方案 A + 原分享已关放行）

相关既有 spec：`2026-07-11-prompt-share-magic-number-design.md`（魔法数字/写穿副本/一辈子一个码）、
`2026-07-13-prompt-manager-redesign.md`（导入 = 独立自建副本，`importedFrom` 标记）。
实现落点：jianshuo.dev repo `agent/src/prompt-share.js`（铸码/关分享路由）。

## 问题

导入别人的提示词得到的是独立副本（`origin:user` + `importedFrom: <原码>`）。现状下
把这个副本**一字未改**直接开分享，走的是普通铸码路径——铸出**新码**，`shares/<新码>`
的 `sub` 是导入者，importCount、市场曝光、奖励全记在导入者头上。一字没改就能把别人
的作品「洗」成自己的。应有的不变量：**prompt 不变，码就不变**（同样的内容全网一个码，
归属原作者）。

## 决定

### 1. 转发判定只发生在「还没有自己的码」时

`POST /agent/prompt-share {id}`：仅当 `byItem[itemId]` 无 entry **且**条目带
`importedFrom` 时进入转发判定。一旦（因为改过正文）铸过自己的码，之后永远走既有
幂等老路——「一条指令一辈子一个码」不破，不做任何「改回原文又变回原码」的聪明追溯。

### 2. 判定口径：只比 instruction 正文，且比的是原码的当前生效内容

取 `shares/<importedFrom>` 活跃副本，与当前 `effectiveLeaf(itemId).instruction`
**严格相等**比较：

- label 改名、appliesTo 调整**不算改过**——正文才是作品本体。
- 比的是原作者**当前**写穿副本：原作者后来改了原件，导入者手里的旧快照就不再等同
  原码指向的内容 → 铸新码。码永远代表「当前指向的内容」，此口径零新增存储。

### 3. 三种结果

| 场景 | 结果 |
|------|------|
| 原分享活着 + 正文一致 | **返回原码**，不铸码、不占日上限、**不写穿** `shares/<原码>` |
| 原分享活着 + 正文改过 | 正常铸自己的新码（衍生作品） |
| 原分享已关（`shares/<原码>` 没了） | 正常铸自己的新码（接力传播；日后原作者重开，两码各指各的副本，不冲突） |

转发响应：`{code: 原码, original: true, author: 原作者名, created: false, sharing: true,
communityShareId: 按原码派生}`。老 iOS 不认识 `original`/`author` 字段，只显示码，不炸。
`author` 走 `readProfileName(…, {fallback:"none"})` 单一真源，读不到为空串。

### 4. borrowed 索引条目（开关状态要能持久）

转发命中时记 `byItem[itemId] = {code: 原码, borrowed: true, createdAt}`（D1 行 + R2
索引双轨，与现行铸码同步口径一致）。iOS 分享开关/分享卡（`shareStates`）对 borrowed
条目照常按 `shares/<原码>` 存活判断 sharing——原作者关了，导入者这边的开关也自然
显示已停止。

**幂等重放的短路（安全点一）**：现有 POST 对已有 code 会无条件重写 `shares/<code>`
（写穿刷新）。borrowed 条目**必须在写穿之前短路**——重新跑一遍转发判定：原分享
仍活且正文仍一致 → 直接返回原码；正文已改（导入者后来改了）→ 铸自己的新码并
**替换** entry（borrowed → 自有）；原分享已死 → 同样铸新码替换。绝不能把原作者的
副本 `sub` 覆盖成导入者。

### 5. DELETE 关分享（安全点二）

现有 DELETE 拿 `byItem[itemId].code` 直接删 `shares/<码>` + 撤帖。borrowed 条目走
这条会**删掉原作者的分享**。必须加分支：`borrowed: true` 只删自己索引里的 entry
（D1 行 + R2 索引同步），不碰 `shares/<原码>`，不触发 `retractPromptPost`。
DELETE 后再 POST → 回到 §1 的判定（原件还一致就再次转发原码）。

### 6. 周边一致性（都不用改）

- `magicForItem` 出图侧：own 路径命中 borrowed 码 = 原码，与 importedFrom 路径殊途
  同归，语义不变。
- 市场/社区：不产生新条目——码是原作者的，条目本就存在（原作者在分享中时市场里
  就是 TA 那一条，热度/importCount 全归 TA）。**实现注意**：prompt-market 的候选
  SQL 枚举 `prompt_shares` 全部行，必须排除 borrowed 行（`WHERE COALESCE(borrowed,0)=0`），
  否则同一个码在列表里出现两次。
- importCount：在原码上自增，天然归原作者。
- 铸码日上限：转发不铸码，不占额度。

### 7. 兼容

- 老索引条目没有 `borrowed` 字段 → 按自有码处理（现状行为），loadIndex/D1 读侧
  对缺字段宽容。
- D1 `prompt_shares` 加可空列 `borrowed INTEGER DEFAULT 0`（migrations-core 增量
  migration；读侧缺列/为 0 都按自有码处理）。R2 索引 JSON 直接加字段。**D1 必须
  持有此标记**——loadIndex 是 D1 优先，若 D1 行丢失 borrowed，读回来会被当成自有
  码，DELETE 就会误删原作者的分享（§5 的安全点靠它）。

## 测试清单

- 未改导入件分享 → 返回原码 + `original:true` + 不写穿原副本 + 不占日上限 + 索引落
  borrowed entry。
- 改过正文再分享 → 铸新码（自有 entry）。
- 原分享已关再分享 → 铸新码。
- borrowed 条目 DELETE → `shares/<原码>` 完好、原作者帖不撤、自己索引 entry 消失。
- borrowed 条目幂等重放 POST → 原件仍一致返回原码且不写穿；导入者已改正文 → 铸新码
  替换 entry。
- 原作者改了原件后导入者再分享 → 铸新码（快照不再等同当前内容）。
- `shareStates`：borrowed 条目 sharing 随 `shares/<原码>` 存活联动。
- 老索引无 borrowed 字段 → 现状行为不变。
