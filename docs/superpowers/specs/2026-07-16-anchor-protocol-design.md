# 锚点协议 —— 长按目标随手势结构化上传，提示词回归自然语言

日期：2026-07-16
状态：已与用户对齐（对话中逐点拍板），待实施
两仓库：voicedrop（iOS）+ jianshuo.dev（agent worker）

## 0. 一句话

「你长按的是哪张图/哪一行」由**手势产生、随请求结构化上传、服务端渲染成独立上下文行**给模型；
提示词文本从此写纯自然语言（「把这张照片重画成水彩」），`{{KEY}}/{{LINE}}/{{QUOTE}}`
三个占位符进入退役通道（兼容保留）。

## 1. 动机（用户原话方向 + 今晚的事故）

- 占位符把「内容」和「寻址」揉在一个字符串里，是一整类 bug 的根：2026-07-16 假题图
  （`[[photo:{{KEY}}]]` 被封面提取当成真图）只是最新一例。
- 分享/导入的提示词含占位符，可读性差，且依赖注入端 hack（prompt-share.js 的
  「占位符代表用户所指」解释块）。
- 措辞钉死在客户端/模板里，调优要发版；锚点措辞收到服务端一处，可用现有 prompt eval
  流水线调。

## 2. 拍板的设计决策（对话中逐条确认）

| 问题 | 决策 |
|---|---|
| anchor 传输形态 | **结构化字段**（client→server），不在客户端拼进提示词文本 |
| 给 LLM 的形态 | 服务端渲染成**独立上下文行**，挨着指令，不塞进提示词句子 |
| 占位符 | 退役但**兼容保留**：带占位符的老提示词照常替换；anchor 注入与替换并存（冗余无害） |
| 模板改写 | **Phase B 单独开闸**（见 §7）：老 App 发不了 anchor，模板先不动，等新版覆盖后再把 sys_* 全套换成自然语言 |
| anchor 缺失 | 可选字段。语音自由指令/老 App/码兑换场景没有 anchor → 现状行为（模型尽力），不报错 |
| 服务端校验 | best-effort：image key 不在本文照片里 / 行号越界 → **丢弃 anchor 不注入**（宁缺勿错），不 4xx |

## 3. 协议（iOS → 服务端）

`EditRequest`（AgentSession WS `/agent/edit` 载荷）加可选字段：

```json
{ "text": "把这张照片重画成水彩", "images": [], "articleIndex": 0,
  "anchor": { "type": "image", "key": "photos/2026-07-13-120000/5-x9q.jpg" } }
```

```json
  "anchor": { "type": "line", "line": 7, "quote": "今天在咖啡馆看到" }
```

- `type`: `"image" | "line"`。`key` 是相对 key（与正文 `[[photo:]]` 标记同格式）；
  `line` 是 bodyRows 行号（与 {{LINE}} 同口径），`quote` 是开头 ~15 字（同 quotePrefix）。
- 只在**长按菜单动作**时携带（手势天然产生锚点）；按住说话的自由语音指令没有锚点。
- 老服务端收到多余字段自动忽略（JSON 宽松），新服务端对缺失字段走现状——**双向兼容，
  两端可独立发版**。

## 4. 服务端（jianshuo.dev：agent worker）

### 4.1 edit-turn.js / 相关 DO 管道

- WS 消息解析处透传 `anchor` → `runEditTurn({ ..., anchor })`。
- **校验**（丢弃制）：`image` → key 必须出现在当前文章 photos（或正文标记）里；
  `line` → 行号在正文行数范围内。不合法 → anchor 置 null，console 打点。
- **注入**（varLines，紧挨「这次的语音指令」之前）：
  - image：`用户长按的图片：[[photo:<key>]]（指令里说的「这张图/这张照片」就是它）`
  - line：`用户长按的是第 <N> 行（开头"<quote>"）（指令里说的「这段/这行」就是它）`
- 带占位符的老提示词 + anchor 同时出现 = 双供给，无冲突。

### 4.2 码兑换（prompt-share.js 注入块）

- 注入块的占位符解释保留（老分享码里还有占位符）；another 一句补充：
  「若上下文提供了用户长按的目标，『这张图/这段』即指它」。
- 无改动硬依赖：码兑换发生在语音指令里，通常无 anchor（§2 缺失即现状）。

### 4.3 显式非目标

- 库级命令（LibraryCommandSession）、挖矿、重写：无锚点概念，不动。
- relay 透传：载荷是黑盒，不动。

## 5. iOS（voicedrop）

- `AgentSession.enqueue(_ instruction:, images:, articleIndex:, anchor: EditAnchor? = nil)`；
  `EditRequest` 加 `anchor`（Encodable，随 WS 上传；持久化队列同步编码）。
- `RecordingDetailView`：
  - `presentImageMenu`（:920 附近）：`onPick` 时带 `anchor = .image(key: relKey)`；
    `fill` 的 `{{KEY}}` 替换**保留**（老模板/老自定义提示词还在用）。
  - 文字菜单（:857 附近）同理：`anchor = .line(line, quote)`；`{{LINE}}/{{QUOTE}}` 替换保留。
- 语音自由指令（PushToTalk）与回答追问：不带 anchor（现状）。
- 新建提示词的 placeholder 提示文案：引导写自然语言（「把这张照片…」「把这段…」），
  不再教占位符。

## 6. 测试

- agent：edit-turn 注入行断言（image/line 两态、非法 anchor 丢弃、无 anchor 现状）、
  WS 消息解析透传；占位符+anchor 双供给用例。
- iOS：EditAnchor 编码形状单测；menuConfig fill 与 anchor 并存的回归；
  真机手测：多图文章长按第 2 张图 → 确改第 2 张（这是本项目的验收金标准）。

## 7. Phase B（单独开闸，不在本次实施）

sys_* 模板全套改写成自然语言（去占位符）。前置条件：新 iOS 版本覆盖足够
（老 App 无 anchor + 无占位符模板 = 多图文章退化，宁等不赌）。改法：改
`prompt-template.js` 字面量（或 R2 config 覆盖）+ **同步改 iOS 内置兜底快照**
（STATE.md 记过的手抄坑）。可随时做、可随时回滚，零发版。

## 8. 部署顺序

1. 服务端先行（anchor 可选，老 App 零影响）。
2. iOS 随下一班 TestFlight。
3. Phase B 另行拍板。
