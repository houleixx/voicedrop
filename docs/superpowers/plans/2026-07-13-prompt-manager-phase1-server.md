# Prompt Manager Phase 1（服务端）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把 VoiceDrop 的提示词后端从「系统固定目录 + 稀疏覆盖」换成「用户拥有的一套有序列表」，核心是 **ref → fork**：没动过的条目跟随系统模板（永远吃最新调优版），动过的实体化冻结。

**Architecture:** 新增 `prompt-template.js`（模板真源，R2 可整体覆盖）+ `prompts.js`（纯逻辑：解析 / 校验 / 恢复默认）+ `prompt-classify.js`（纯逻辑，注入 claude）+ 6 个 `/agent/prompts*` 路由。改造 `prompt-share.js`（铸码走新解析器，写穿副本加 appliesTo/kind，新增 GET 读端点）和 `prompt-registry.js`（读写新模板，对外形状不变）。删除 `ui-config.js` / `ui-config-custom.js` 及其路由与测试。

**Tech Stack:** Cloudflare Worker (ES modules)、R2 (`env.FILES`)、D1 (`env.USAGE`)、vitest 2。

**Spec:** `~/code/voicedrop/docs/superpowers/specs/2026-07-13-prompt-manager-redesign.md`

## Global Constraints

- **仓库**：`~/code/jianshuo.dev`（不是 voicedrop）。**该仓库工作区有未提交改动（`a/index.html` + 未跟踪的 `a/voicedrop-mining/`），且本地 main 落后 origin/main 363 个提交。绝对不要 stash / checkout / reset 掉这些改动。** 用 worktree 隔离（见 Task 0）。
- **测试**：`cd <worktree>/agent && npm test`（vitest）。每个 Task 结束时全套必须绿。
- **纯逻辑与 IO 分离**：业务逻辑写成可注入依赖的纯函数（照 `src/style-extract.js` 的 `distillStyle(samples, claude)` 范式），路由层在 `index.js` 里包真实的 R2 / Claude / 计费 / 日志。
- **id 规则**：模板项 `sys_*`（稳定、无语义）；用户实体项 `^p_[a-z0-9]{6,}$`（客户端生成，服务端只校验）。**不得让 id 编码菜单归属**——菜单归属是 `appliesTo` 数据字段。
- **上限（照 spec §6）**：`label` ≤ 40 字，`prompt` ≤ 4000 字，全树条目 ≤ 200，两级封顶（group 不能套 group）。
- **`appliesTo`**：`["text"]` / `["image"]` / `["text","image"]`，action 必须非空；group 不带 `appliesTo` / `prompt`。
- **`kind` / `imageParams`**：本期**存 + 透传，不做 UI**，也不参与任何逻辑分支。
- **计费/日志 best-effort**：任何 `env.USAGE` / `writeLlmLog` 失败**绝不中断**请求（`try/catch` + `if (env.USAGE)`）。
- **提交信息**：中文，结尾带 `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`。

---

### Task 0: 隔离工作区

**Files:** 无（只建 worktree）

**Interfaces:**
- Produces: 一个干净的、基于 `origin/main` 的 worktree 路径，后续所有 Task 都在里面干活。

- [ ] **Step 1: 建 worktree**

用户的 `~/code/jianshuo.dev` 工作区有未提交改动，**不要动它**。

```bash
cd ~/code/jianshuo.dev
git fetch origin
git worktree add -b prompt-manager-server ~/code/jianshuo.dev-prompts origin/main
cd ~/code/jianshuo.dev-prompts/agent && npm install
```

- [ ] **Step 2: 确认基线全绿**

Run: `cd ~/code/jianshuo.dev-prompts/agent && npm test`
Expected: 全部 PASS（这是改动前的基线；记下用例总数）。

**之后所有 Task 的路径都相对 `~/code/jianshuo.dev-prompts/`。**

---

### Task 1: `prompt-template.js` — 模板真源 + R2 覆盖

**Files:**
- Create: `agent/src/prompt-template.js`
- Test: `agent/test/prompt-template.test.js`

**Interfaces:**
- Produces:
  - `DEFAULT_PROMPT_TEMPLATE` — `{schema:1, items:[node]}`，node = `{id, type:"group"|"action", label, prompt?, appliesTo?, kind?, children?}`
  - `loadPromptTemplate(env) -> Promise<template>` — R2 `config/prompt-template.json` 合法则整体覆盖，否则内置
  - `templateIndex(tpl) -> Map<id, node>` — 打平（**含 group 节点**），`children` 不带进 Map 的 value（value 是节点本身的引用，读的时候只取内容字段）

- [ ] **Step 1: 写失败测试**

Create `agent/test/prompt-template.test.js`:

```js
import { describe, it, expect } from "vitest";
import { DEFAULT_PROMPT_TEMPLATE, loadPromptTemplate, templateIndex } from "../src/prompt-template.js";

describe("DEFAULT_PROMPT_TEMPLATE（spec 2026-07-13-prompt-manager-redesign.md §3）", () => {
  const idx = templateIndex(DEFAULT_PROMPT_TEMPLATE);

  it("schema 1；12 个 action + 3 个 group", () => {
    expect(DEFAULT_PROMPT_TEMPLATE.schema).toBe(1);
    const all = [...idx.values()];
    expect(all.filter((n) => n.type === "action").length).toBe(12);
    expect(all.filter((n) => n.type === "group").length).toBe(3);
  });

  it("id 全部 sys_ 前缀，且不编码菜单归属（不含 image./text. 路径段）", () => {
    for (const id of idx.keys()) {
      expect(id).toMatch(/^sys_[a-z0-9_]+$/);
      expect(id).not.toContain("longpress");
    }
  });

  it("六个图片风格：appliesTo=[image]、kind=image、prompt 带 [[photo:{{KEY}}]]", () => {
    for (const id of ["sys_cartoon", "sys_ad", "sys_watercolor", "sys_sketch", "sys_oil", "sys_film"]) {
      const n = idx.get(id);
      expect(n.appliesTo).toEqual(["image"]);
      expect(n.kind).toBe("image");
      expect(n.prompt).toContain("[[photo:{{KEY}}]]");
    }
    expect(idx.get("sys_cartoon").prompt).toContain("宫崎骏");
    expect(idx.get("sys_ad").prompt).toContain("商品广告");
  });

  it("四个改写：appliesTo=[text]、带 {{LINE}}+{{QUOTE}}、无 kind", () => {
    for (const id of ["sys_concise", "sys_casual", "sys_formal", "sys_expand"]) {
      const n = idx.get(id);
      expect(n.appliesTo).toEqual(["text"]);
      expect(n.prompt).toContain("{{LINE}}");
      expect(n.prompt).toContain("{{QUOTE}}");
      expect(n.kind).toBeUndefined();
    }
  });

  it("插入图片两项：appliesTo=[text]（在长按文字里出现）但 kind=image（产出是图）", () => {
    for (const id of ["sys_wechat_cover", "sys_cartoon_explainer"]) {
      const n = idx.get(id);
      expect(n.appliesTo).toEqual(["text"]);
      expect(n.kind).toBe("image");
      expect(n.prompt).not.toContain("{{LINE}}");
    }
    expect(idx.get("sys_wechat_cover").prompt).toContain("2.45:1");
  });

  it("group 无 prompt / appliesTo，children 只装 action（两级封顶）", () => {
    for (const g of [...idx.values()].filter((n) => n.type === "group")) {
      expect(g.prompt).toBeUndefined();
      expect(g.appliesTo).toBeUndefined();
      expect(g.children.length).toBeGreaterThan(0);
      for (const c of g.children) expect(c.type).toBe("action");
    }
  });
});

describe("loadPromptTemplate — R2 整体覆盖，坏数据回退内置", () => {
  const envWith = (text) => ({
    FILES: { get: async (k) => (k === "config/prompt-template.json" && text != null ? { text: async () => text } : null) },
  });

  it("R2 缺失 → 内置", async () => {
    expect(await loadPromptTemplate(envWith(null))).toEqual(DEFAULT_PROMPT_TEMPLATE);
  });

  it("R2 合法 → 整体覆盖", async () => {
    const override = { schema: 1, items: [{ id: "sys_x", type: "action", label: "X", prompt: "p", appliesTo: ["text"] }] };
    expect(await loadPromptTemplate(envWith(JSON.stringify(override)))).toEqual(override);
  });

  it("R2 坏 JSON / 非对象 / 缺 schema / items 非数组 → 内置", async () => {
    expect(await loadPromptTemplate(envWith("{oops"))).toEqual(DEFAULT_PROMPT_TEMPLATE);
    expect(await loadPromptTemplate(envWith('"str"'))).toEqual(DEFAULT_PROMPT_TEMPLATE);
    expect(await loadPromptTemplate(envWith(JSON.stringify({ items: [] })))).toEqual(DEFAULT_PROMPT_TEMPLATE);
    expect(await loadPromptTemplate(envWith(JSON.stringify({ schema: 1 })))).toEqual(DEFAULT_PROMPT_TEMPLATE);
  });
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd agent && npx vitest run test/prompt-template.test.js`
Expected: FAIL — `Failed to resolve import "../src/prompt-template.js"`

- [ ] **Step 3: 实现 `agent/src/prompt-template.js`**

**提示词正文必须从 `agent/src/ui-config.js` 的 `DEFAULT_UI_CONFIG` 逐字拷贝，不要重新打字**（那几段 prompt 是长期调优的产物，改一个字都是回归）。id 映射：

| 新 id | 老路径（在 DEFAULT_UI_CONFIG 里） | type | appliesTo | kind |
|---|---|---|---|---|
| `sys_style` | `longpress.image.style` | group | — | — |
| `sys_cartoon` | `…image.style.cartoon` | action | `["image"]` | `image` |
| `sys_ad` | `…image.style.ad` | action | `["image"]` | `image` |
| `sys_watercolor` | `…image.style.watercolor` | action | `["image"]` | `image` |
| `sys_sketch` | `…image.style.sketch` | action | `["image"]` | `image` |
| `sys_oil` | `…image.style.oil` | action | `["image"]` | `image` |
| `sys_film` | `…image.style.film` | action | `["image"]` | `image` |
| `sys_rewrite` | `longpress.text.rewrite` | group | — | — |
| `sys_concise` | `…text.rewrite.concise` | action | `["text"]` | — |
| `sys_casual` | `…text.rewrite.casual` | action | `["text"]` | — |
| `sys_formal` | `…text.rewrite.formal` | action | `["text"]` | — |
| `sys_expand` | `…text.rewrite.expand` | action | `["text"]` | — |
| `sys_insert` | `longpress.text.insert` | group | — | — |
| `sys_wechat_cover` | `…text.insert.wechat-cover` | action | `["text"]` | `image` |
| `sys_cartoon_explainer` | `…text.insert.cartoon-explainer` | action | `["text"]` | `image` |

group 的 `label` 也照抄（`图片风格` / `改写这段` / `插入图片`）。

```js
// src/prompt-template.js — 提示词系统模板（真源）。
// spec: voicedrop repo docs/superpowers/specs/2026-07-13-prompt-manager-redesign.md
//
// 形状 = 和用户列表一模一样的有序树（两级封顶）。每条 action 自带 appliesTo
// （在哪个长按菜单里出现）和可选 kind（产出什么）——这两件事是分开的：
// 「插入图片·公众号题图」appliesTo=["text"]（长按文字时出现）但 kind="image"（产出是图）。
//
// id 是稳定但【无语义】的键：不编码菜单归属、不编码层级。老设计把菜单路径当主键
// （voice-editor.longpress.image.style.cartoon），导致"改这条出现在哪"= 改主键 = 断掉
// 所有已有覆盖和已铸分享码。这里彻底废掉那套。
//
// 真源 = 下面的字面量；R2 `config/prompt-template.json` 合法则整体覆盖（零部署调优，
// 照 ui-config 先例）。用户没动过的条目在他列表里是 {"ref":"sys_*"}，永远读到这里的最新版。

export const DEFAULT_PROMPT_TEMPLATE = {
  schema: 1,
  items: [
    {
      id: "sys_style", type: "group", label: "图片风格",
      children: [
        { id: "sys_cartoon", type: "action", label: "卡通", appliesTo: ["image"], kind: "image",
          prompt: "<从 ui-config.js image.style.cartoon 逐字拷贝>" },
        { id: "sys_ad", type: "action", label: "广告", appliesTo: ["image"], kind: "image",
          prompt: "<从 ui-config.js image.style.ad 逐字拷贝>" },
        { id: "sys_watercolor", type: "action", label: "水彩", appliesTo: ["image"], kind: "image",
          prompt: "<逐字拷贝>" },
        { id: "sys_sketch", type: "action", label: "素描", appliesTo: ["image"], kind: "image",
          prompt: "<逐字拷贝>" },
        { id: "sys_oil", type: "action", label: "油画", appliesTo: ["image"], kind: "image",
          prompt: "<逐字拷贝>" },
        { id: "sys_film", type: "action", label: "胶片", appliesTo: ["image"], kind: "image",
          prompt: "<逐字拷贝>" },
      ],
    },
    {
      id: "sys_rewrite", type: "group", label: "改写这段",
      children: [
        { id: "sys_concise", type: "action", label: "更简洁", appliesTo: ["text"], prompt: "<逐字拷贝>" },
        { id: "sys_casual", type: "action", label: "更口语", appliesTo: ["text"], prompt: "<逐字拷贝>" },
        { id: "sys_formal", type: "action", label: "更书面", appliesTo: ["text"], prompt: "<逐字拷贝>" },
        { id: "sys_expand", type: "action", label: "扩写一点", appliesTo: ["text"], prompt: "<逐字拷贝>" },
      ],
    },
    {
      id: "sys_insert", type: "group", label: "插入图片",
      children: [
        { id: "sys_wechat_cover", type: "action", label: "公众号题图", appliesTo: ["text"], kind: "image",
          prompt: "<逐字拷贝>" },
        { id: "sys_cartoon_explainer", type: "action", label: "卡通解释图", appliesTo: ["text"], kind: "image",
          prompt: "<逐字拷贝>" },
      ],
    },
  ],
};

/// 模板形状最小校验：{schema, items:[…]}。坏数据一律回退内置（配置错不能打挂线上）。
function looksLikeTemplate(o) {
  return !!o && typeof o === "object" && typeof o.schema === "number" && Array.isArray(o.items);
}

export async function loadPromptTemplate(env) {
  try {
    const obj = await env.FILES.get("config/prompt-template.json");
    if (obj) {
      const parsed = JSON.parse(await obj.text());
      if (looksLikeTemplate(parsed)) return parsed;
    }
  } catch (e) {
    console.error("[prompt-template] bad config/prompt-template.json:", e && e.message);
  }
  return DEFAULT_PROMPT_TEMPLATE;
}

/// 打平成 Map<id, node>，含 group 节点（group 的 label 也要能被 ref 解析到）。
export function templateIndex(tpl) {
  const map = new Map();
  for (const item of tpl.items || []) {
    map.set(item.id, item);
    for (const child of item.children || []) map.set(child.id, child);
  }
  return map;
}
```

- [ ] **Step 4: 拷贝 12 段 prompt 正文**

打开 `agent/src/ui-config.js`，把 12 个叶子的 `instruction` 字符串**逐字**搬到上面对应的 `prompt` 字段（连标点和空格都别改）。

- [ ] **Step 5: 跑测试确认通过**

Run: `cd agent && npx vitest run test/prompt-template.test.js`
Expected: PASS（全部 7 个用例）

- [ ] **Step 6: 提交**

```bash
git add agent/src/prompt-template.js agent/test/prompt-template.test.js
git commit -m "$(cat <<'EOF'
feat(prompts): 提示词系统模板 prompt-template.js —— 无语义 sys_* id + appliesTo

模板形状改成和用户列表一样的有序树（两级封顶）。12 条 prompt 正文从
ui-config.js 逐字搬过来（长期调优产物，一字不改）。菜单归属从 id 路径挪进
appliesTo 数据字段；kind（产出什么）与 appliesTo（在哪出现）分开——
「插入图片·公众号题图」appliesTo=[text] 但 kind=image。

R2 config/prompt-template.json 可整体覆盖（零部署调优，照 ui-config 先例）。

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: 解析器 — `resolveList`（ref → fork 的核心）

**Files:**
- Create: `agent/src/prompts.js`
- Test: `agent/test/prompts.test.js`

**Interfaces:**
- Consumes: `templateIndex` (Task 1)
- Produces:
  - `resolveList(template, userDoc) -> [resolvedNode]`
    - `userDoc` = `null`（用户没文件）→ 返回模板全量，每条 `origin:"system"`
    - resolvedNode = `{id, type, label, prompt?, appliesTo?, kind?, imageParams?, origin, forkedFrom?, children?}`
    - `origin`：`"system"`（来自 ref）/ `"custom"`（实体 + forkedFrom）/ `"user"`（实体，无 forkedFrom）
    - **ref 节点的 `id` = 它引用的 `sys_*` id**（客户端拿它当行 id 用）

- [ ] **Step 1: 写失败测试**

Create `agent/test/prompts.test.js`:

```js
import { describe, it, expect } from "vitest";
import { resolveList } from "../src/prompts.js";

// 小模板，测试自带，不依赖真模板的内容（真模板的内容由 prompt-template.test.js 盯）
const TPL = {
  schema: 1,
  items: [
    { id: "sys_g", type: "group", label: "图片风格", children: [
      { id: "sys_a", type: "action", label: "卡通", prompt: "原始卡通", appliesTo: ["image"], kind: "image" },
      { id: "sys_b", type: "action", label: "水彩", prompt: "原始水彩", appliesTo: ["image"], kind: "image" },
    ]},
    { id: "sys_c", type: "action", label: "更简洁", prompt: "原始简洁", appliesTo: ["text"] },
  ],
};

describe("resolveList — 无用户文档 = 模板全量跟随", () => {
  it("null userDoc → 模板全量，全部 origin=system", () => {
    const out = resolveList(TPL, null);
    expect(out.map((n) => n.id)).toEqual(["sys_g", "sys_c"]);
    expect(out[0].origin).toBe("system");
    expect(out[0].children.map((c) => c.id)).toEqual(["sys_a", "sys_b"]);
    expect(out[0].children[0].origin).toBe("system");
    expect(out[0].children[0].prompt).toBe("原始卡通");
    expect(out[1].origin).toBe("system");
  });
});

describe("resolveList — ref 跟随模板（核心性质）", () => {
  const doc = { schema: 1, items: [
    { ref: "sys_g", children: [{ ref: "sys_a" }] },
    { ref: "sys_c" },
  ]};

  it("ref 项整条读模板内容", () => {
    const out = resolveList(TPL, doc);
    expect(out[0].label).toBe("图片风格");
    expect(out[0].children[0].prompt).toBe("原始卡通");
    expect(out[0].children[0].kind).toBe("image");
    expect(out[1].prompt).toBe("原始简洁");
  });

  it("★ 模板改了 prompt → ref 项跟着变（不折腾的用户永远吃最新）", () => {
    const tuned = JSON.parse(JSON.stringify(TPL));
    tuned.items[0].children[0].prompt = "调优后的卡通";
    tuned.items[1].prompt = "调优后的简洁";
    const out = resolveList(tuned, doc);
    expect(out[0].children[0].prompt).toBe("调优后的卡通");
    expect(out[1].prompt).toBe("调优后的简洁");
  });

  it("用户列表的顺序覆盖模板顺序", () => {
    const reordered = { schema: 1, items: [{ ref: "sys_c" }, { ref: "sys_g", children: [{ ref: "sys_b" }] }] };
    const out = resolveList(TPL, reordered);
    expect(out.map((n) => n.id)).toEqual(["sys_c", "sys_g"]);
    expect(out[1].children.map((c) => c.id)).toEqual(["sys_b"]);
  });

  it("模板删了某条 → 悬空 ref 静默跳过，不崩", () => {
    const shrunk = { schema: 1, items: [TPL.items[0]] };  // 没有 sys_c 了
    const out = resolveList(shrunk, doc);
    expect(out.map((n) => n.id)).toEqual(["sys_g"]);
  });

  it("模板删了组里某条 → 组还在，那个 child 消失", () => {
    const shrunk = JSON.parse(JSON.stringify(TPL));
    shrunk.items[0].children = [shrunk.items[0].children[1]];   // 只剩 sys_b
    const out = resolveList(shrunk, { schema: 1, items: [{ ref: "sys_g", children: [{ ref: "sys_a" }, { ref: "sys_b" }] }] });
    expect(out[0].children.map((c) => c.id)).toEqual(["sys_b"]);
  });
});

describe("resolveList — 实体（fork / 自建）", () => {
  it("fork 一条：只有那条冻结，其余仍跟随模板", () => {
    const doc = { schema: 1, items: [
      { ref: "sys_g", children: [
        { id: "p_abc123", type: "action", label: "卡通风", prompt: "我改过的", appliesTo: ["image"], forkedFrom: "sys_a" },
        { ref: "sys_b" },
      ]},
    ]};
    const tuned = JSON.parse(JSON.stringify(TPL));
    tuned.items[0].children[0].prompt = "调优后的卡通";   // 被 fork 的那条，模板变了
    tuned.items[0].children[1].prompt = "调优后的水彩";   // 没 fork 的那条

    const out = resolveList(tuned, doc);
    expect(out[0].children[0].prompt).toBe("我改过的");        // 冻结
    expect(out[0].children[0].origin).toBe("custom");
    expect(out[0].children[0].forkedFrom).toBe("sys_a");
    expect(out[0].children[1].prompt).toBe("调优后的水彩");    // 仍跟随
    expect(out[0].children[1].origin).toBe("system");
  });

  it("纯自建（无 forkedFrom）→ origin=user", () => {
    const doc = { schema: 1, items: [
      { id: "p_zq1f6e", type: "action", label: "写成小红书", prompt: "口语、emoji…", appliesTo: ["text"] },
    ]};
    const out = resolveList(TPL, doc);
    expect(out[0].origin).toBe("user");
    expect(out[0].forkedFrom).toBeUndefined();
  });

  it("★ 轻度触碰不冻结全局：新增一条自建，系统项仍是 ref、仍跟随", () => {
    const doc = { schema: 1, items: [
      { ref: "sys_c" },
      { id: "p_zq1f6e", type: "action", label: "写成小红书", prompt: "我的", appliesTo: ["text"] },
    ]};
    const tuned = JSON.parse(JSON.stringify(TPL));
    tuned.items[1].prompt = "调优后的简洁";
    const out = resolveList(tuned, doc);
    expect(out[0].prompt).toBe("调优后的简洁");   // 系统项照样跟随
    expect(out[1].prompt).toBe("我的");
  });

  it("fork 一个 group：label 冻结，children 照常解析", () => {
    const doc = { schema: 1, items: [
      { id: "p_grp001", type: "group", label: "我的图片风格", forkedFrom: "sys_g", children: [{ ref: "sys_a" }] },
    ]};
    const out = resolveList(TPL, doc);
    expect(out[0].label).toBe("我的图片风格");
    expect(out[0].origin).toBe("custom");
    expect(out[0].children[0].prompt).toBe("原始卡通");
  });

  it("空 items → 空列表（用户把所有条目都删了）", () => {
    expect(resolveList(TPL, { schema: 1, items: [] })).toEqual([]);
  });
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd agent && npx vitest run test/prompts.test.js`
Expected: FAIL — `Failed to resolve import "../src/prompts.js"`

- [ ] **Step 3: 实现 `resolveList`**

Create `agent/src/prompts.js`:

```js
// src/prompts.js — 提示词列表的纯逻辑：解析（ref→fork）/ 校验 / 恢复默认。
// spec: voicedrop repo docs/superpowers/specs/2026-07-13-prompt-manager-redesign.md
//
// 用户列表里每一项只有两种形态：
//   {"ref":"sys_*"}  → 我没动过，整条读模板（模板一调优，用户立刻吃到最新）
//   完整实体          → 这条是我的，冻结
// 解析没有"合并"、没有"打补丁"——ref 是整条取模板，不是取底子再盖字段。
//
// 默认全是 ref，所以【不写 prompt 的大多数用户永远拿到最新最好的 prompt】；
// 新建/导入只是多一条实体，其余系统项仍是 ref、仍跟随（轻度触碰不冻结全局）。
import { templateIndex } from "./prompt-template.js";

/// 实体节点 → 对外的解析结果（origin 由 forkedFrom 推出）。
function fromEntity(node) {
  const out = {
    id: node.id, type: node.type, label: node.label,
    origin: node.forkedFrom ? "custom" : "user",
  };
  if (node.forkedFrom) out.forkedFrom = node.forkedFrom;
  if (node.type === "action") {
    out.prompt = node.prompt;
    out.appliesTo = node.appliesTo;
    if (node.kind !== undefined) out.kind = node.kind;
    if (node.imageParams !== undefined) out.imageParams = node.imageParams;
  }
  return out;
}

/// 模板节点 → 对外的解析结果（origin=system；children 不在这里展开）。
function fromTemplate(node) {
  const out = { id: node.id, type: node.type, label: node.label, origin: "system" };
  if (node.type === "action") {
    out.prompt = node.prompt;
    out.appliesTo = node.appliesTo;
    if (node.kind !== undefined) out.kind = node.kind;
    if (node.imageParams !== undefined) out.imageParams = node.imageParams;
  }
  return out;
}

/// 一个列表节点（ref 或实体）→ 解析结果；悬空 ref（模板已删）→ null（调用方丢掉）。
function resolveNode(node, idx) {
  if (node.ref) {
    const t = idx.get(node.ref);
    return t ? fromTemplate(t) : null;
  }
  return fromEntity(node);
}

/// 模板全量 → 解析结果（用户还没有 prompts.json 时走这条）。
function resolveWholeTemplate(template) {
  return (template.items || []).map((item) => {
    const out = fromTemplate(item);
    if (item.type === "group") out.children = (item.children || []).map(fromTemplate);
    return out;
  });
}

export function resolveList(template, userDoc) {
  if (!userDoc || !Array.isArray(userDoc.items)) return resolveWholeTemplate(template);
  const idx = templateIndex(template);
  const out = [];
  for (const node of userDoc.items) {
    const resolved = resolveNode(node, idx);
    if (!resolved) continue;                       // 悬空 ref：模板删了这条
    if (resolved.type === "group") {
      resolved.children = (node.children || [])
        .map((c) => resolveNode(c, idx))
        .filter(Boolean);
    }
    out.push(resolved);
  }
  return out;
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd agent && npx vitest run test/prompts.test.js`
Expected: PASS（12 个用例）

- [ ] **Step 5: 提交**

```bash
git add agent/src/prompts.js agent/test/prompts.test.js
git commit -m "$(cat <<'EOF'
feat(prompts): 解析器 resolveList —— ref 跟随模板 / 实体冻结

用户列表每项两种形态：{"ref":"sys_*"} 整条读模板（模板一调优立刻生效），
或完整实体（我的，冻结）。没有合并、没有打补丁。

关键性质（已单测钉死）：
- 无用户文档 → 模板全量，全部 origin=system
- 模板改 prompt → ref 项跟着变
- fork 一条 → 只冻结那条，其余仍跟随
- 新增自建 → 系统项仍是 ref、仍跟随（轻度触碰不冻结全局）
- 模板删条目 → 悬空 ref 静默跳过，不崩

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: 校验 — `validateList`

**Files:**
- Modify: `agent/src/prompts.js`（追加）
- Modify: `agent/test/prompts.test.js`（追加 describe 块）

**Interfaces:**
- Consumes: `templateIndex` (Task 1)
- Produces: `validateList(template, items) -> string | null` — 返回**错误信息字符串**（给 400 的 body 用）或 `null`（通过）

**约束（spec §6 / Global Constraints）**：两级封顶、ref 必须存在于模板、实体 id `^p_[a-z0-9]{6,}$` 且全树唯一、action 的 `appliesTo` 非空且 ⊆ `{text,image}`、group 不带 `appliesTo`/`prompt`、`label` ≤ 40、`prompt` ≤ 4000、全树条目 ≤ 200。

- [ ] **Step 1: 写失败测试**

追加到 `agent/test/prompts.test.js`（文件顶部 import 改成 `import { resolveList, validateList } from "../src/prompts.js";`）：

```js
describe("validateList — PUT 的守门人", () => {
  const ok = (items) => validateList(TPL, items);
  const entity = (over = {}) => ({ id: "p_abc123", type: "action", label: "我的", prompt: "内容", appliesTo: ["text"], ...over });

  it("合法列表 → null", () => {
    expect(ok([{ ref: "sys_g", children: [{ ref: "sys_a" }] }, entity()])).toBeNull();
  });

  it("非数组 → 报错", () => {
    expect(validateList(TPL, null)).toMatch(/items/);
    expect(validateList(TPL, "nope")).toMatch(/items/);
  });

  it("未知 ref → 报错", () => {
    expect(ok([{ ref: "sys_nope" }])).toMatch(/unknown ref/);
  });

  it("实体 id 格式非法 → 报错", () => {
    expect(ok([entity({ id: "abc" })])).toMatch(/id/);
    expect(ok([entity({ id: "p_AB" })])).toMatch(/id/);       // 大写 + 太短
    expect(ok([entity({ id: "sys_a" })])).toMatch(/id/);      // 不许冒充 sys_
  });

  it("id 全树重复 → 报错（含跨层级）", () => {
    expect(ok([entity(), entity()])).toMatch(/duplicate/);
    expect(ok([
      { id: "p_grp001", type: "group", label: "组", children: [entity()] },
      entity(),
    ])).toMatch(/duplicate/);
  });

  it("两级封顶：group 套 group → 报错", () => {
    expect(ok([{
      id: "p_grp001", type: "group", label: "外", children: [
        { id: "p_grp002", type: "group", label: "内", children: [] },
      ],
    }])).toMatch(/two levels|group/);
  });

  it("action 的 appliesTo 空 / 非法值 → 报错", () => {
    expect(ok([entity({ appliesTo: [] })])).toMatch(/appliesTo/);
    expect(ok([entity({ appliesTo: ["video"] })])).toMatch(/appliesTo/);
    expect(ok([entity({ appliesTo: "text" })])).toMatch(/appliesTo/);
  });

  it("group 不许带 prompt / appliesTo → 报错", () => {
    expect(ok([{ id: "p_grp001", type: "group", label: "组", prompt: "x", children: [] }])).toMatch(/group/);
    expect(ok([{ id: "p_grp001", type: "group", label: "组", appliesTo: ["text"], children: [] }])).toMatch(/group/);
  });

  it("label > 40 / prompt > 4000 → 报错", () => {
    expect(ok([entity({ label: "长".repeat(41) })])).toMatch(/label/);
    expect(ok([entity({ prompt: "长".repeat(4001) })])).toMatch(/prompt/);
  });

  it("空 label → 报错", () => {
    expect(ok([entity({ label: "  " })])).toMatch(/label/);
  });

  it("未知 type → 报错", () => {
    expect(ok([entity({ type: "widget" })])).toMatch(/type/);
  });

  it("超过 200 条 → 报错", () => {
    const many = Array.from({ length: 201 }, (_, i) => entity({ id: `p_x${String(i).padStart(5, "0")}` }));
    expect(ok(many)).toMatch(/too many/);
  });

  it("空列表合法（用户可以删光）", () => {
    expect(ok([])).toBeNull();
  });
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd agent && npx vitest run test/prompts.test.js`
Expected: FAIL — `validateList is not a function`

- [ ] **Step 3: 实现 `validateList`**

> ⚠️ **加固要求（下面的参考代码是骨架，这四条必须做到，缺一条就是可利用的洞）。**
> 这是**唯一**挡在恶意客户端和 R2 存储之间的东西，它收的是 `JSON.parse` 的原始产物。
>
> 1. **`validateList` 必须是 total —— 任何 JSON 输入都只返回 `string|null`，绝不 throw。**
>    校验器一抛，本该的 400 就变成 500。外面套一层 `try/catch` 兜底。
> 2. **`children` 存在时必须是数组。** `for (const c of node.children || [])` 遇到 `children:{}`
>    会抛 `TypeError`（`{}` 是 truthy 但不可迭代）。`children: 5` / `true` 同理。
> 3. **长度量的是【原串】，不是 trim 后的。** `label` 用 `node.label.length`，否则
>    `" ".repeat(10000)+"A"` 直接绕过 40 字上限。（`prompt` 的检查本来就是对的，照它写。）
> 4. **字段白名单（spec §3「有 `ref` 就没有其他内容字段」）。** 白名单外的键一律拒绝：
>    - ref-to-action：`{ref}`；ref-to-group：`{ref, children}`
>    - 实体 action：`{id, type, label, prompt, appliesTo, kind, imageParams, forkedFrom}`
>    - 实体 group：`{id, type, label, children, forkedFrom}`
>
>    没有白名单，**200 条上限根本不是体积上限**——单条塞一个 5MB 的陌生键名就整包进了存储
>    （`{ref:"sys_cartoon", notChildren:"X".repeat(5e6)}` 会通过）。有了白名单，最坏情况
>    ≈ 200 × (40 label + 4000 prompt) ≈ 800KB，够用了，**不用再加单独的字节上限**。
>
> 白名单同时也顺手封死了「action 挂 children」这个走私通道（`children` 不在 action 的白名单里）。

追加到 `agent/src/prompts.js`：

```js
// ── 校验（PUT /agent/prompts 的守门人）────────────────────────────────────────
export const MAX_ITEMS = 200;
export const MAX_LABEL = 40;
export const MAX_PROMPT = 4000;
const USER_ID_RE = /^p_[a-z0-9]{6,}$/;
const APPLIES = new Set(["text", "image"]);

// 字段白名单 —— 见上面「加固要求 4」。
const REF_ACTION_KEYS = new Set(["ref"]);
const REF_GROUP_KEYS = new Set(["ref", "children"]);
const ENTITY_ACTION_KEYS = new Set(["id", "type", "label", "prompt", "appliesTo", "kind", "imageParams", "forkedFrom"]);
const ENTITY_GROUP_KEYS = new Set(["id", "type", "label", "children", "forkedFrom"]);

/// 返回错误信息字符串（→ 400 body）或 null（通过）。
export function validateList(template, items) {
  if (!Array.isArray(items)) return "items must be an array";

  const idx = templateIndex(template);
  const seen = new Set();
  let count = 0;

  // depth 0 = 顶层，1 = 组内。两级封顶 = depth 1 不许再出现 group。
  const walk = (node, depth) => {
    count++;
    if (count > MAX_ITEMS) return `too many items (max ${MAX_ITEMS})`;
    if (!node || typeof node !== "object") return "bad node";

    if (node.ref) {
      if (!idx.has(node.ref)) return `unknown ref: ${node.ref}`;
      if (seen.has(node.ref)) return `duplicate id: ${node.ref}`;
      seen.add(node.ref);
      const t = idx.get(node.ref);
      if (t.type === "group") {
        if (depth > 0) return "groups may only appear at the top level (two levels max)";
        for (const c of node.children || []) {
          const err = walk(c, 1);
          if (err) return err;
        }
      } else if (node.children !== undefined) {
        // ⚠️ action 挂 children 必须显式报错。否则那个数组【既不校验也不计数】——
        // {ref:"sys_cartoon", children:[500 条垃圾]} 会整包混进存储并绕过 200 条上限。
        return "action must not carry children";
      }
      return null;
    }

    // 实体
    if (!USER_ID_RE.test(node.id || "")) return `bad id: ${node.id} (want ^p_[a-z0-9]{6,}$)`;
    if (seen.has(node.id)) return `duplicate id: ${node.id}`;
    seen.add(node.id);

    if (node.type !== "action" && node.type !== "group") return `bad type: ${node.type}`;
    const label = typeof node.label === "string" ? node.label.trim() : "";
    if (!label) return "label must not be empty";
    // ⚠️ 长度必须量【原串】而不是 trim 后的：否则 " ".repeat(10000)+"A" 能绕过上限。
    if (node.label.length > MAX_LABEL) return `label too long (max ${MAX_LABEL})`;
    if (node.forkedFrom !== undefined && !idx.has(node.forkedFrom)) return `unknown forkedFrom: ${node.forkedFrom}`;

    if (node.type === "group") {
      if (depth > 0) return "groups may only appear at the top level (two levels max)";
      if (node.prompt !== undefined) return "group must not carry a prompt";
      if (node.appliesTo !== undefined) return "group must not carry appliesTo";
      for (const c of node.children || []) {
        const err = walk(c, 1);
        if (err) return err;
      }
      return null;
    }

    // action
    if (node.children !== undefined) return "action must not carry children";   // 同上：不校验不计数的走私通道
    if (typeof node.prompt !== "string" || !node.prompt.trim()) return "prompt must not be empty";
    if (node.prompt.length > MAX_PROMPT) return `prompt too long (max ${MAX_PROMPT})`;
    if (!Array.isArray(node.appliesTo) || node.appliesTo.length === 0) return "appliesTo must be a non-empty array";
    for (const a of node.appliesTo) if (!APPLIES.has(a)) return `bad appliesTo value: ${a}`;
    return null;
  };

  for (const node of items) {
    const err = walk(node, 0);
    if (err) return err;
  }
  return null;
}
```

**注意** `walk` 里的 `count > MAX_ITEMS` 检查要在**递归之前**，否则 201 条的 case 会在计数到位前就返回 null。上面的写法已经是先 `count++` 再判。

- [ ] **Step 4: 跑测试确认通过**

Run: `cd agent && npx vitest run test/prompts.test.js`
Expected: PASS（12 + 13 = 25 个用例）

- [ ] **Step 5: 提交**

```bash
git add agent/src/prompts.js agent/test/prompts.test.js
git commit -m "$(cat <<'EOF'
feat(prompts): validateList —— PUT 的守门人

两级封顶 / 未知 ref / 实体 id 格式(^p_[a-z0-9]{6,}$)+全树唯一 /
action 的 appliesTo 非空且 ⊆{text,image} / group 不带 prompt+appliesTo /
label≤40 / prompt≤4000 / 全树≤200 条。空列表合法（用户可以删光）。

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: `restoreDefaults` —「恢复默认提示词」

**Files:**
- Modify: `agent/src/prompts.js`（追加）
- Modify: `agent/test/prompts.test.js`（追加 describe 块）

**Interfaces:**
- Produces: `restoreDefaults(template, items) -> [item]` — 返回**新的用户列表**（不是解析结果），把模板里**缺的**顶层项按模板顺序追加到末尾。

**「缺」的定义**：一个模板顶层项 `sys_X` 算"已有"，当且仅当列表里存在 `{ref:"sys_X"}` **或** 存在 `forkedFrom === "sys_X"` 的实体。（否则「恢复默认」会把用户 fork 过的条目再补一份进来 → 重复。）

组内的模板 action 同理：ref 或 forkedFrom 命中就算有；缺的补回**该组**末尾（前提是那个组本身还在列表里；组都没了就跟着组一起整体补回来）。

- [ ] **Step 1: 写失败测试**

追加到 `agent/test/prompts.test.js`（import 改成 `import { resolveList, validateList, restoreDefaults } from "../src/prompts.js";`）：

```js
describe("restoreDefaults — 补回模板里缺的（后悔药 + 拿系统新 prompt）", () => {
  it("删光了 → 补回模板全量（全是 ref）", () => {
    const out = restoreDefaults(TPL, []);
    expect(out).toEqual([
      { ref: "sys_g", children: [{ ref: "sys_a" }, { ref: "sys_b" }] },
      { ref: "sys_c" },
    ]);
  });

  it("只删了组内一条 → 只补那一条，补回该组末尾", () => {
    const items = [{ ref: "sys_g", children: [{ ref: "sys_b" }] }, { ref: "sys_c" }];
    const out = restoreDefaults(TPL, items);
    expect(out[0].children).toEqual([{ ref: "sys_b" }, { ref: "sys_a" }]);
    expect(out[1]).toEqual({ ref: "sys_c" });
  });

  it("★ 已 fork 的不重复补（认 forkedFrom）", () => {
    const forked = { id: "p_abc123", type: "action", label: "卡通风", prompt: "我的", appliesTo: ["image"], forkedFrom: "sys_a" };
    const items = [{ ref: "sys_g", children: [forked] }, { ref: "sys_c" }];
    const out = restoreDefaults(TPL, items);
    // sys_a 已被 fork → 不补；sys_b 缺 → 补
    expect(out[0].children).toEqual([forked, { ref: "sys_b" }]);
  });

  it("fork 过的 group 不重复补，但组内缺的照补", () => {
    const items = [{ id: "p_grp001", type: "group", label: "我的风格", forkedFrom: "sys_g", children: [{ ref: "sys_a" }] }];
    const out = restoreDefaults(TPL, items);
    expect(out[0].id).toBe("p_grp001");
    expect(out[0].children).toEqual([{ ref: "sys_a" }, { ref: "sys_b" }]);
    expect(out[1]).toEqual({ ref: "sys_c" });   // 顶层缺的也补
  });

  it("自建条目原样保留，不受影响", () => {
    const mine = { id: "p_zq1f6e", type: "action", label: "写成小红书", prompt: "我的", appliesTo: ["text"] };
    const out = restoreDefaults(TPL, [mine]);
    expect(out[0]).toEqual(mine);
    expect(out.slice(1)).toEqual([
      { ref: "sys_g", children: [{ ref: "sys_a" }, { ref: "sys_b" }] },
      { ref: "sys_c" },
    ]);
  });

  it("★ 模板新增一条系统 prompt → 补进来（这是老用户拿到新 prompt 的唯一入口）", () => {
    const grown = JSON.parse(JSON.stringify(TPL));
    grown.items.push({ id: "sys_new", type: "action", label: "新功能", prompt: "新的", appliesTo: ["text"] });
    const items = [{ ref: "sys_g", children: [{ ref: "sys_a" }, { ref: "sys_b" }] }, { ref: "sys_c" }];
    const out = restoreDefaults(grown, items);
    expect(out[out.length - 1]).toEqual({ ref: "sys_new" });
  });

  it("什么都不缺 → 原样返回", () => {
    const items = [{ ref: "sys_g", children: [{ ref: "sys_a" }, { ref: "sys_b" }] }, { ref: "sys_c" }];
    expect(restoreDefaults(TPL, items)).toEqual(items);
  });
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd agent && npx vitest run test/prompts.test.js`
Expected: FAIL — `restoreDefaults is not a function`

- [ ] **Step 3: 实现 `restoreDefaults`**

追加到 `agent/src/prompts.js`：

```js
// ── 恢复默认（一个按钮两个用途：删多了的后悔药 + 拿系统新出的 prompt）──────────
//
// 【为什么不做"模板新增项自动追加"】自动追加会把用户【主动删掉】的条目塞回来，
// 要修就得引入 deleted:[] 墓碑列表——多一个字段，换一个用户不可控的行为。
// 一个显式按钮既是后悔药，又是新 prompt 的入口。见 spec §4。

/// 这个模板 id 在列表里是否"已有"：被 ref，或被某个实体 fork。
function covers(nodes, sysId) {
  return (nodes || []).some((n) => n.ref === sysId || n.forkedFrom === sysId);
}

/// 返回【新的用户列表】（不是解析结果）：模板里缺的按模板顺序补回末尾。
export function restoreDefaults(template, items) {
  const out = (items || []).map((n) => (n.children ? { ...n, children: [...n.children] } : { ...n }));

  for (const t of template.items || []) {
    if (covers(out, t.id)) {
      // 顶层已有。若它是组，把组内缺的 action 补回该组末尾。
      if (t.type === "group") {
        const g = out.find((n) => n.ref === t.id || n.forkedFrom === t.id);
        g.children = g.children || [];
        for (const c of t.children || []) {
          if (!covers(g.children, c.id)) g.children.push({ ref: c.id });
        }
      }
      continue;
    }
    // 顶层缺失 → 整个补回来（组的话连子项一起）。
    out.push(t.type === "group"
      ? { ref: t.id, children: (t.children || []).map((c) => ({ ref: c.id })) }
      : { ref: t.id });
  }
  return out;
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd agent && npx vitest run test/prompts.test.js`
Expected: PASS（25 + 7 = 32 个用例）

- [ ] **Step 5: 提交**

```bash
git add agent/src/prompts.js agent/test/prompts.test.js
git commit -m "$(cat <<'EOF'
feat(prompts): restoreDefaults —— 补回模板里缺的

一个按钮两个用途：用户删多了的后悔药 + 老用户拿到系统新出的 prompt。
「缺」= 既没被 ref 也没被任何实体 forkedFrom —— 所以已 fork 的条目不会被
重复补进来。组内缺的补回该组末尾。

不做「模板新增项自动追加」：那会把用户主动删掉的条目塞回来，要修就得引入
deleted[] 墓碑列表。显式按钮更简单也更可控。

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: 路由 `GET/PUT /agent/prompts` + `POST /agent/prompts/restore-defaults`

**Files:**
- Create: `agent/src/prompt-routes.js`
- Modify: `agent/src/index.js`（加 import + 路由分支）
- Modify: `agent/test/prompts.test.js`（追加 route describe 块）

**Interfaces:**
- Consumes: `loadPromptTemplate` (Task 1)、`resolveList` / `validateList` / `restoreDefaults` (Task 2–4)
- Produces:
  - `loadUserPrompts(env, scope) -> Promise<doc|null>` — 读 `users/<sub>/prompts.json`，坏文件当没有
  - `saveUserPrompts(env, scope, items) -> Promise<void>`
  - `handlePromptsRoute(request, env, scope, url) -> Promise<Response>` — 处理 `/agent/prompts` 与 `/agent/prompts/restore-defaults`

R2 key = `${scope}prompts.json`（`scope` 形如 `users/<sub>/`）。

响应形状：`GET`/`PUT`/`restore-defaults` 都返回 `{schema:1, items:[已解析, 带 origin]}`。

- [ ] **Step 1: 写失败测试**

追加到 `agent/test/prompts.test.js`（文件顶部加）：

```js
import { vi } from "vitest";
vi.mock("agents", () => ({ Agent: class Agent {}, getAgentByName: async () => ({}) }));
import worker from "../src/index.js";
import { fakeEnv } from "./fakes.js";
import { DEFAULT_PROMPT_TEMPLATE } from "../src/prompt-template.js";

const TOKEN = "Bearer anon_testtoken1234567890";
const SCOPE_KEY = (env) => [...env.FILES._store.keys()].find((k) => k.endsWith("prompts.json"));
const GET = (env) => worker.fetch(new Request("https://jianshuo.dev/agent/prompts", { headers: { Authorization: TOKEN } }), env);
const PUT = (env, items) => worker.fetch(new Request("https://jianshuo.dev/agent/prompts", {
  method: "PUT", headers: { Authorization: TOKEN, "content-type": "application/json" },
  body: JSON.stringify({ items }),
}), env);
```

然后追加：

```js
describe("GET /agent/prompts", () => {
  it("无 token → 401", async () => {
    const res = await worker.fetch(new Request("https://jianshuo.dev/agent/prompts"), fakeEnv());
    expect(res.status).toBe(401);
  });

  it("新用户（无 prompts.json）→ 模板全量，全部 origin=system", async () => {
    const res = await GET(fakeEnv());
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.schema).toBe(1);
    expect(body.items.length).toBe(DEFAULT_PROMPT_TEMPLATE.items.length);
    expect(body.items.every((i) => i.origin === "system")).toBe(true);
  });

  it("★ 读盘不落盘：GET 不该给新用户创建 prompts.json", async () => {
    const env = fakeEnv();
    await GET(env);
    expect(SCOPE_KEY(env)).toBeUndefined();
  });

  it("坏 prompts.json → 当没有，回退模板（不 500）", async () => {
    const env = fakeEnv();
    const res0 = await PUT(env, []);          // 先建出 key，拿到真实 scope 路径
    expect(res0.status).toBe(200);
    env.FILES._store.set(SCOPE_KEY(env), "{oops");
    const res = await GET(env);
    expect(res.status).toBe(200);
    expect((await res.json()).items.length).toBe(DEFAULT_PROMPT_TEMPLATE.items.length);
  });
});

describe("PUT /agent/prompts", () => {
  it("整树写入 → 200 + 返回解析结果；GET 读回一致", async () => {
    const env = fakeEnv();
    const items = [{ id: "p_zq1f6e", type: "action", label: "写成小红书", prompt: "我的", appliesTo: ["text"] }];
    const put = await PUT(env, items);
    expect(put.status).toBe(200);
    const putBody = await put.json();
    expect(putBody.items).toHaveLength(1);
    expect(putBody.items[0].origin).toBe("user");

    const got = await (await GET(env)).json();
    expect(got.items).toEqual(putBody.items);
  });

  it("校验失败 → 400 且不落盘", async () => {
    const env = fakeEnv();
    const res = await PUT(env, [{ ref: "sys_nope" }]);
    expect(res.status).toBe(400);
    expect((await res.json()).error).toMatch(/unknown ref/);
    expect(SCOPE_KEY(env)).toBeUndefined();
  });

  it("body 不是 {items:[...]} → 400", async () => {
    const env = fakeEnv();
    const res = await worker.fetch(new Request("https://jianshuo.dev/agent/prompts", {
      method: "PUT", headers: { Authorization: TOKEN, "content-type": "application/json" }, body: "{oops",
    }), env);
    expect(res.status).toBe(400);
  });

  it("空列表可写（用户删光）", async () => {
    const env = fakeEnv();
    expect((await PUT(env, [])).status).toBe(200);
    expect((await (await GET(env)).json()).items).toEqual([]);
  });

  it("DELETE → 405", async () => {
    const res = await worker.fetch(new Request("https://jianshuo.dev/agent/prompts", {
      method: "DELETE", headers: { Authorization: TOKEN },
    }), fakeEnv());
    expect(res.status).toBe(405);
  });
});

describe("POST /agent/prompts/restore-defaults", () => {
  const RESTORE = (env) => worker.fetch(new Request("https://jianshuo.dev/agent/prompts/restore-defaults", {
    method: "POST", headers: { Authorization: TOKEN },
  }), env);

  it("删光后恢复 → 模板全量回来", async () => {
    const env = fakeEnv();
    await PUT(env, []);
    const res = await RESTORE(env);
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(body.items.length).toBe(DEFAULT_PROMPT_TEMPLATE.items.length);
    expect(body.items.every((i) => i.origin === "system")).toBe(true);
    // 落盘了，GET 读回一致
    expect((await (await GET(env)).json()).items).toEqual(body.items);
  });

  it("自建条目保留在前，补回来的排后面", async () => {
    const env = fakeEnv();
    await PUT(env, [{ id: "p_zq1f6e", type: "action", label: "写成小红书", prompt: "我的", appliesTo: ["text"] }]);
    const body = await (await RESTORE(env)).json();
    expect(body.items[0].origin).toBe("user");
    expect(body.items.length).toBe(1 + DEFAULT_PROMPT_TEMPLATE.items.length);
  });

  it("无 token → 401", async () => {
    expect((await worker.fetch(new Request("https://jianshuo.dev/agent/prompts/restore-defaults", { method: "POST" }), fakeEnv())).status).toBe(401);
  });
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd agent && npx vitest run test/prompts.test.js`
Expected: FAIL — `/agent/prompts` 路由不存在，GET 返回 404 而非 200

- [ ] **Step 3: 实现 `agent/src/prompt-routes.js`**

```js
// src/prompt-routes.js — /agent/prompts* 的 IO 层（纯逻辑在 prompts.js）。
// spec: voicedrop repo docs/superpowers/specs/2026-07-13-prompt-manager-redesign.md
//
// 存储：users/<sub>/prompts.json = { schema:1, items:[…] }（ref 或实体，两级封顶）。
// 【没有这个文件 = 全跟随模板】——GET 绝不为新用户落盘，否则就把他冻结了。
//
// 写操作只有【整树 PUT】：新建/删除/改名/改词/排序/分组/fork 全走它。客户端本来就
// 整棵树拿在手里，所以不存在局部更新竞态。
import { loadPromptTemplate } from "./prompt-template.js";
import { resolveList, validateList, restoreDefaults } from "./prompts.js";

const J = (o, status = 200) => new Response(JSON.stringify(o), { status, headers: { "content-type": "application/json" } });

const docKey = (scope) => `${scope}prompts.json`;

/// 读用户列表；没有 / 坏文件 → null（= 全跟随模板）。坏文件绝不能 500。
export async function loadUserPrompts(env, scope) {
  try {
    const obj = await env.FILES.get(docKey(scope));
    if (!obj) return null;
    const doc = JSON.parse(await obj.text());
    if (doc && Array.isArray(doc.items)) return doc;
  } catch (e) {
    console.error("[prompts] bad prompts.json:", e && e.message);
  }
  return null;
}

export async function saveUserPrompts(env, scope, items) {
  await env.FILES.put(docKey(scope), JSON.stringify({ schema: 1, items }, null, 2), {
    httpMetadata: { contentType: "application/json" },
  });
}

const resolved = (tpl, items) => J({ schema: 1, items: resolveList(tpl, { schema: 1, items }) });

export async function handlePromptsRoute(request, env, scope, url) {
  const tpl = await loadPromptTemplate(env);

  // POST /agent/prompts/restore-defaults —— 补回模板里缺的（后悔药 + 拿新 prompt）
  if (url.pathname === "/agent/prompts/restore-defaults") {
    if (request.method !== "POST") return J({ error: "method not allowed" }, 405);
    const doc = await loadUserPrompts(env, scope);
    // 还没有自己的文件 = 本来就全跟随模板，恢复默认是 no-op，也不落盘。
    if (!doc) return J({ schema: 1, items: resolveList(tpl, null) });
    const next = restoreDefaults(tpl, doc.items);
    await saveUserPrompts(env, scope, next);
    return resolved(tpl, next);
  }

  if (request.method === "GET") {
    const doc = await loadUserPrompts(env, scope);
    return J({ schema: 1, items: resolveList(tpl, doc) });   // doc=null → 模板全量，【不落盘】
  }

  if (request.method === "PUT") {
    let body;
    try { body = await request.json(); } catch { body = null; }
    if (!body || !Array.isArray(body.items)) return J({ error: "expected {items: [...]}" }, 400);
    const err = validateList(tpl, body.items);
    if (err) return J({ error: err }, 400);
    await saveUserPrompts(env, scope, body.items);
    return resolved(tpl, body.items);
  }

  return J({ error: "method not allowed" }, 405);
}
```

- [ ] **Step 4: 接进 `agent/src/index.js`**

在 import 区（`import { handleUIConfigCustom } from "./ui-config-custom.js";` 附近）加：

```js
import { handlePromptsRoute } from "./prompt-routes.js";
```

在路由区（`/agent/ui-config` 分支旁边）加：

```js
    // ── /agent/prompts ── 用户的一套有序提示词列表（ref 跟随模板 / 实体冻结）。
    // GET 读解析后的列表；PUT 整树写（新建/删除/改名/排序/分组/fork 全走它）；
    // POST /restore-defaults 补回模板里缺的。spec 2026-07-13-prompt-manager-redesign.md
    if (url.pathname === "/agent/prompts" || url.pathname === "/agent/prompts/restore-defaults") {
      const scope = await resolveScope(bearerToken(request), env);
      if (!scope) return J({ error: "unauthorized" }, 401);
      return handlePromptsRoute(request, env, scope, url);
    }
```

**注意**：这个分支必须放在任何 `/agent/prompt-...` 前缀分支之前还是之后都行（路径不重叠），但**必须**在通配/兜底 404 之前。照 `/agent/ui-config` 的位置放即可。

- [ ] **Step 5: 跑测试确认通过**

Run: `cd agent && npx vitest run test/prompts.test.js`
Expected: PASS（32 + 12 = 44 个用例）

Run: `cd agent && npm test`
Expected: 全套 PASS（老的 ui-config 测试这时候还在，也该绿）

- [ ] **Step 6: 提交**

```bash
git add agent/src/prompt-routes.js agent/src/index.js agent/test/prompts.test.js
git commit -m "$(cat <<'EOF'
feat(prompts): GET/PUT /agent/prompts + restore-defaults

存储 users/<sub>/prompts.json。写操作只有整树 PUT —— 新建/删除/改名/改词/
排序/分组/fork 全走它（客户端本来就整棵树在手，无局部更新竞态）。

关键：GET 绝不为新用户落盘。没有这个文件 = 全跟随模板 = 永远吃最新调优版；
一落盘就把他冻结了。坏 prompts.json 当没有（回退模板，不 500）。

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: `POST /agent/prompt-classify` — AI 建议 appliesTo

**Files:**
- Create: `agent/src/prompt-classify.js`
- Create: `agent/test/prompt-classify.test.js`
- Modify: `agent/src/index.js`（加 import + 路由分支）

**Interfaces:**
- Produces:
  - `CLASSIFY_SYSTEM` — system prompt 字面量
  - `classifyAppliesTo(prompt, claude) -> Promise<{appliesTo, reason}>` — **纯逻辑，注入 claude**（照 `style-extract.js` 的 `distillStyle(samples, claude)` 范式）。`claude({system, messages}) -> string`。
  - **任何异常 / 解析失败 → 回退 `{appliesTo:["text","image"], reason:""}`，绝不抛。**

**为什么必须回退**（spec §7）：分类只是给 5c 一个预勾选的起点。Claude 挂了、算力不足、返回了垃圾——**都不能挡住用户新建提示词**。回退到「都行」+ 空 reason，客户端就不渲染那条琥珀提示条。

- [ ] **Step 1: 写失败测试**

Create `agent/test/prompt-classify.test.js`:

```js
import { vi, describe, it, expect } from "vitest";
vi.mock("agents", () => ({ Agent: class Agent {}, getAgentByName: async () => ({}) }));
import { classifyAppliesTo } from "../src/prompt-classify.js";
import worker from "../src/index.js";
import { fakeEnv } from "./fakes.js";

const claudeSaying = (s) => async () => s;

describe("classifyAppliesTo — 纯逻辑（注入 claude）", () => {
  it("模型说 text → {appliesTo:[text], reason}", async () => {
    const r = await classifyAppliesTo("把这段改得更简洁", claudeSaying('{"appliesTo":["text"],"reason":"这条像是改文字的"}'));
    expect(r.appliesTo).toEqual(["text"]);
    expect(r.reason).toBe("这条像是改文字的");
  });

  it("模型说 image → {appliesTo:[image]}", async () => {
    const r = await classifyAppliesTo("把这张图重画成水彩", claudeSaying('{"appliesTo":["image"],"reason":"改图的"}'));
    expect(r.appliesTo).toEqual(["image"]);
  });

  it("模型说都行 → 两个都要", async () => {
    const r = await classifyAppliesTo("解释一下", claudeSaying('{"appliesTo":["text","image"],"reason":"都行"}'));
    expect(new Set(r.appliesTo)).toEqual(new Set(["text", "image"]));
  });

  it("模型套了 ``` 围栏 → 照样解析", async () => {
    const r = await classifyAppliesTo("x", claudeSaying('```json\n{"appliesTo":["text"],"reason":"r"}\n```'));
    expect(r.appliesTo).toEqual(["text"]);
  });

  it("★ claude 抛异常 → 回退都行 + 空 reason（绝不挡住新建）", async () => {
    const r = await classifyAppliesTo("x", async () => { throw new Error("no credit"); });
    expect(new Set(r.appliesTo)).toEqual(new Set(["text", "image"]));
    expect(r.reason).toBe("");
  });

  it("★ 模型返回垃圾 / 空 / 非法值 → 回退都行 + 空 reason", async () => {
    for (const junk of ["", "我不知道", "{}", '{"appliesTo":[]}', '{"appliesTo":["video"]}', '{"appliesTo":"text"}']) {
      const r = await classifyAppliesTo("x", claudeSaying(junk));
      expect(new Set(r.appliesTo)).toEqual(new Set(["text", "image"]));
      expect(r.reason).toBe("");
    }
  });

  it("模型混入非法值 → 只留合法的", async () => {
    const r = await classifyAppliesTo("x", claudeSaying('{"appliesTo":["text","video"],"reason":"r"}'));
    expect(r.appliesTo).toEqual(["text"]);
  });

  it("reason 超长 → 截断（琥珀条放不下）", async () => {
    const r = await classifyAppliesTo("x", claudeSaying(JSON.stringify({ appliesTo: ["text"], reason: "长".repeat(200) })));
    expect(r.reason.length).toBeLessThanOrEqual(60);
  });
});

describe("POST /agent/prompt-classify route", () => {
  const TOKEN = "Bearer anon_testtoken1234567890";

  it("无 token → 401", async () => {
    const res = await worker.fetch(new Request("https://jianshuo.dev/agent/prompt-classify", { method: "POST" }), fakeEnv());
    expect(res.status).toBe(401);
  });

  it("GET → 405", async () => {
    const res = await worker.fetch(new Request("https://jianshuo.dev/agent/prompt-classify", { headers: { Authorization: TOKEN } }), fakeEnv());
    expect(res.status).toBe(405);
  });

  it("缺 prompt → 400", async () => {
    const res = await worker.fetch(new Request("https://jianshuo.dev/agent/prompt-classify", {
      method: "POST", headers: { Authorization: TOKEN, "content-type": "application/json" }, body: JSON.stringify({}),
    }), fakeEnv());
    expect(res.status).toBe(400);
  });

  it("★ 没有 CLAUDE_API_KEY（调用必挂）→ 仍 200 + 回退都行，绝不 500", async () => {
    const res = await worker.fetch(new Request("https://jianshuo.dev/agent/prompt-classify", {
      method: "POST", headers: { Authorization: TOKEN, "content-type": "application/json" },
      body: JSON.stringify({ prompt: "把这段改简洁" }),
    }), fakeEnv());
    expect(res.status).toBe(200);
    const body = await res.json();
    expect(new Set(body.appliesTo)).toEqual(new Set(["text", "image"]));
    expect(body.reason).toBe("");
  });
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd agent && npx vitest run test/prompt-classify.test.js`
Expected: FAIL — `Failed to resolve import "../src/prompt-classify.js"`

- [ ] **Step 3: 实现 `agent/src/prompt-classify.js`**

```js
// src/prompt-classify.js — 读一条提示词，猜它该在长按【文字】还是【图片】时出现。
// spec: voicedrop repo docs/superpowers/specs/2026-07-13-prompt-manager-redesign.md §7
//
// 纯逻辑 + 注入 claude（照 style-extract.js 范式），路由层包真实调用/计费/日志。
//
// 【绝不能挡住用户新建提示词】——它只是给 5c 两个开关一个预勾选的起点。Claude 挂了、
// 算力不足、模型返回垃圾，一律回退「都行」+ 空 reason（客户端就不渲染那条琥珀提示条）。
// 所以这个函数【永不抛异常】。

export const CLASSIFY_SYSTEM = `你在给一条"提示词"判断它的适用范围。

用户在文章里长按一段【文字】或一张【图片】，会弹出菜单选一条提示词来执行。
你要判断这条提示词应该出现在哪种长按菜单里：

- "text"：作用于一段文字（改写、润色、扩写、翻译、改成某种文体…）
- "image"：作用于一张图片（重画、换风格、调色…）
- 两个都要：既能作用于文字也能作用于图片（比如"解释一下"）

注意：提示词的【产出】是什么不重要，重要的是它【作用于】什么。
比如"给这篇文章画一张题图"作用于文字（用户长按正文时用它），产出才是图 —— 它是 "text"。

只输出 JSON，不要任何别的字：
{"appliesTo":["text"],"reason":"一句话说明，20 字以内，口语"}`;

const VALID = ["text", "image"];
const FALLBACK = { appliesTo: ["text", "image"], reason: "" };
const MAX_REASON = 60;

/// 从模型输出里抠 JSON：容忍 ```json 围栏和前后废话。
function extractJSON(raw) {
  const s = String(raw || "");
  const start = s.indexOf("{");
  const end = s.lastIndexOf("}");
  if (start < 0 || end <= start) return null;
  try { return JSON.parse(s.slice(start, end + 1)); } catch { return null; }
}

export async function classifyAppliesTo(prompt, claude) {
  try {
    const raw = await claude({
      system: CLASSIFY_SYSTEM,
      messages: [{ role: "user", content: String(prompt || "").slice(0, 4000) }],
    });
    const parsed = extractJSON(raw);
    if (!parsed || !Array.isArray(parsed.appliesTo)) return { ...FALLBACK };
    const appliesTo = parsed.appliesTo.filter((a) => VALID.includes(a));
    if (!appliesTo.length) return { ...FALLBACK };
    const reason = typeof parsed.reason === "string" ? parsed.reason.trim().slice(0, MAX_REASON) : "";
    return { appliesTo, reason };
  } catch (e) {
    console.error("[prompt-classify] fell back to 都行:", e && e.message);
    return { ...FALLBACK };
  }
}
```

- [ ] **Step 4: 接路由进 `agent/src/index.js`**

import 区加：

```js
import { classifyAppliesTo } from "./prompt-classify.js";
```

路由区加（放在 `/agent/prompts` 分支后面）：

```js
    // ── /agent/prompt-classify ── AI 猜这条提示词该在长按文字还是图片时出现（5c 的
    // 预勾选 + 琥珀提示条）。best-effort：Claude 挂 / 无算力 / 返回垃圾 → 回退「都行」
    // + 空 reason，【绝不挡住用户新建提示词】。spec §7
    if (url.pathname === "/agent/prompt-classify") {
      if (request.method !== "POST") return J({ error: "method not allowed" }, 405);
      const scope = await resolveScope(bearerToken(request), env);
      if (!scope) return J({ error: "unauthorized" }, 401);
      const body = await request.json().catch(() => ({}));
      if (typeof body.prompt !== "string" || !body.prompt.trim()) return J({ error: "expected {prompt}" }, 400);

      const CLASSIFY_MODEL = "claude-haiku-4-5";
      const usageSum = { input_tokens: 0, output_tokens: 0, cache_creation_input_tokens: 0, cache_read_input_tokens: 0 };
      const claude = async ({ system, messages }) => {
        const reqBody = { model: CLASSIFY_MODEL, max_tokens: 200, system, messages };
        const t0 = Date.now();
        const r = await callAnthropic(env, reqBody);
        const j = r.json;
        await writeLlmLog(env, {
          ts: t0, source: "agent", user_scope: scope, model: CLASSIFY_MODEL,
          latency_ms: Date.now() - t0, http_status: r.status, ok: r.ok,
          via: r.via, ...(r.colo ? { colo: r.colo } : {}),
          step: 0, request: reqBody, response: r.ok ? j : undefined,
          error: r.ok ? undefined : r.errorText,
          meta: { kind: "prompt-classify" },
        });
        if (!r.ok) throw new Error(`Claude HTTP ${r.status}`);
        const u = j.usage || {};
        usageSum.input_tokens += u.input_tokens || 0;
        usageSum.output_tokens += u.output_tokens || 0;
        usageSum.cache_creation_input_tokens += u.cache_creation_input_tokens || 0;
        usageSum.cache_read_input_tokens += u.cache_read_input_tokens || 0;
        return (j.content || []).filter((b) => b.type === "text").map((b) => b.text).join("");
      };

      // classifyAppliesTo 永不抛（内部已回退），所以这里必定 200。
      const result = await classifyAppliesTo(body.prompt, claude);

      // 计费 best-effort：失败绝不影响响应。
      try {
        if (env.USAGE && usageSum.input_tokens) {
          await ensureAccount(env.USAGE, scope, Date.now());
          const cost = claudeCostUY(CLASSIFY_MODEL, usageSum.input_tokens, usageSum.output_tokens,
                                    usageSum.cache_creation_input_tokens, usageSum.cache_read_input_tokens);
          await debit(env.USAGE, scope, cost, "prompt-classify", {}, Date.now());
        }
      } catch (_) {}

      return J(result);
    }
```

**检查 import**：`callAnthropic` / `writeLlmLog` / `ensureAccount` / `debit` / `claudeCostUY` 在 `index.js` 里应该已经 import 过了（`/agent/style/extract` 用了同样这套）。如果某个没有，照 style/extract 的 import 补上。

- [ ] **Step 5: 跑测试确认通过**

Run: `cd agent && npx vitest run test/prompt-classify.test.js`
Expected: PASS（12 个用例）

Run: `cd agent && npm test`
Expected: 全套 PASS

- [ ] **Step 6: 提交**

```bash
git add agent/src/prompt-classify.js agent/src/index.js agent/test/prompt-classify.test.js
git commit -m "$(cat <<'EOF'
feat(prompts): POST /agent/prompt-classify —— AI 建议 appliesTo

读一条提示词，猜它该在长按文字还是图片时出现（5c 两个开关的预勾选 + 琥珀
提示条的理由）。纯逻辑 + 注入 claude，路由层包真实调用/llmlog/计费（haiku）。

关键：永不抛、永不 500。Claude 挂 / 无算力 / 模型返回垃圾 → 一律回退「都行」
+ 空 reason（客户端不渲染琥珀条）。分类绝不能挡住用户新建提示词。

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: `GET /agent/prompt-share/<code>` — 4b 的导入预览

**Files:**
- Create: `functions/lib/profile.js`（把 `readProfileName` 从 Pages Function 提出来共用）
- Modify: `functions/files/api/[[path]].js`（改成 import 那个共用函数）
- Modify: `agent/src/prompt-share.js`（`sharedDocFor` 加 `appliesTo`/`kind`；新增 GET 分支）
- Modify: `agent/test/prompt-share.test.js`（追加）

**Interfaces:**
- Produces:
  - `functions/lib/profile.js`: `readProfileName(env, scope) -> Promise<string>`（读不到 → `""`）
  - `GET /agent/prompt-share/<code>` → `{label, prompt, appliesTo, kind, author, importCount}`；查无 / 非 prompt 条目 → 404 `{error:"not-found"}`
  - **公开、无需 token**（导入前你还没登录也该能预览；和落地页同源同权）

**老副本兼容**：老 `shares/<码>` 文档没有 `appliesTo` → 预览回退 `["text","image"]`（都行）。`importCount` 缺 → `0`。

- [ ] **Step 1: 写失败测试**

追加到 `agent/test/prompt-share.test.js`：

```js
describe("GET /agent/prompt-share/<code> — 4b 导入预览（公开，无需 token）", () => {
  const shareDoc = (over = {}) => JSON.stringify({
    type: "prompt", sub: "anon-abc", itemId: "p_zq1f6e",
    label: "改写成播客口播稿", instruction: "把文章改写成适合朗读的口播稿…",
    appliesTo: ["text"], importCount: 128,
    createdAt: "2026-07-01T00:00:00Z", updatedAt: "2026-07-01T00:00:00Z",
    ...over,
  });
  const GETC = (env, code) => worker.fetch(new Request(`https://jianshuo.dev/agent/prompt-share/${code}`), env);

  it("有效码 → 200 + 预览负载（无需 Authorization）", async () => {
    const env = fakeEnv({ "shares/4820135": shareDoc(), "users/anon-abc/CLAUDE.md": "老周\n文风…" });
    const res = await GETC(env, "4820135");
    expect(res.status).toBe(200);
    const b = await res.json();
    expect(b.label).toBe("改写成播客口播稿");
    expect(b.prompt).toContain("口播稿");
    expect(b.appliesTo).toEqual(["text"]);
    expect(b.importCount).toBe(128);
    expect(b.author).toBe("老周");
  });

  it("★ 老副本没有 appliesTo → 回退都行；没有 importCount → 0", async () => {
    const env = fakeEnv({ "shares/4820135": shareDoc({ appliesTo: undefined, importCount: undefined }) });
    const b = await (await GETC(env, "4820135")).json();
    expect(new Set(b.appliesTo)).toEqual(new Set(["text", "image"]));
    expect(b.importCount).toBe(0);
  });

  it("读不到作者名 → author 为空串（客户端不渲染「来自」行）", async () => {
    const env = fakeEnv({ "shares/4820135": shareDoc() });
    expect((await (await GETC(env, "4820135")).json()).author).toBe("");
  });

  it("查无此码 → 404", async () => {
    expect((await GETC(fakeEnv(), "9999999")).status).toBe(404);
  });

  it("码指向的是文章分享（纯字符串值），不是提示词 → 404", async () => {
    const env = fakeEnv({ "shares/4820135": "users/anon-x/articles/foo.json" });
    expect((await GETC(env, "4820135")).status).toBe(404);
  });

  it("码格式非法 → 404", async () => {
    expect((await GETC(fakeEnv(), "abc")).status).toBe(404);
    expect((await GETC(fakeEnv(), "0123456")).status).toBe(404);   // 首位 0
  });
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd agent && npx vitest run test/prompt-share.test.js`
Expected: FAIL — GET 返回 405/404-from-fallthrough 而非预期负载

- [ ] **Step 3: 提取 `readProfileName` 到 `functions/lib/profile.js`**

先在 `functions/files/api/[[path]].js` 里找到 `readProfileName` 的定义（`grep -n "readProfileName" functions/files/api/'[[path]].js'`），把函数体**原样**搬到新文件：

```js
// functions/lib/profile.js — 用户显示名（从 CLAUDE.md / CLAUDE.json 读）。
// 原先内联在 functions/files/api/[[path]].js（社区帖的 author 字段），现在
// agent worker 的 GET /agent/prompt-share/<code> 也要用（4b 的「来自 X」），
// 所以提到共用 lib —— worker 已经在 import functions/lib/auth.js，路径通。
export async function readProfileName(env, scope) {
  // <把 [[path]].js 里的实现原样搬来>
}
```

然后在 `[[path]].js` 里删掉原定义，改成 `import { readProfileName } from '../../lib/profile.js';`（相对路径按该文件实际层级调整）。

**跑一次全套确认没搬坏**：`cd agent && npm test`（社区测试会覆盖到 author）。

- [ ] **Step 4: 改 `agent/src/prompt-share.js`**

(a) `sharedDocFor` 带上 `appliesTo` / `kind` / 保留 `importCount`：

```js
function sharedDocFor(scope, itemId, leaf, createdAt, importCount = 0) {
  const now = new Date().toISOString();
  return JSON.stringify({
    type: "prompt", sub: scope.slice("users/".length, -1), itemId,
    label: leaf.label, instruction: leaf.instruction,
    appliesTo: leaf.appliesTo, ...(leaf.kind !== undefined ? { kind: leaf.kind } : {}),
    importCount,
    createdAt: createdAt || now, updatedAt: now,
  }, null, 2);
}
```

`refreshPromptShare` 里读旧文档时**连 `importCount` 一起保留**（和现有的 `createdAt` 一样）：

```js
    let createdAt, importCount = 0;
    try {
      const prev = JSON.parse(await existing.text());
      createdAt = prev.createdAt;
      importCount = prev.importCount || 0;
    } catch { /* 重建 */ }
    ...
    await env.FILES.put(`shares/${code}`, sharedDocFor(scope, itemId, leaf, createdAt, importCount));
```

(b) `resolvePromptShare` 回传新字段（老副本回退）：

```js
export async function resolvePromptShare(env, code) {
  try {
    const o = await env.FILES.get(`shares/${code}`);
    if (!o) return null;
    const doc = JSON.parse(await o.text());
    if (!doc || doc.type !== "prompt" || typeof doc.instruction !== "string") return null;
    return {
      code, sub: doc.sub, itemId: doc.itemId,
      label: doc.label || "分享指令", instruction: doc.instruction,
      // 老副本（本次重构之前铸的码）没有 appliesTo → 回退「都行」。
      appliesTo: Array.isArray(doc.appliesTo) && doc.appliesTo.length ? doc.appliesTo : ["text", "image"],
      ...(doc.kind !== undefined ? { kind: doc.kind } : {}),
      importCount: doc.importCount || 0,
    };
  } catch { return null; }
}
```

(c) `handlePromptShareRoutes` 加 GET 分支（公开，不验 token）：

```js
import { readProfileName } from "../../functions/lib/profile.js";

const CODE_PATH_RE = /^\/agent\/prompt-share\/([1-9][0-9]{6})$/;

export async function handlePromptShareRoutes(url, request, env) {
  // GET /agent/prompt-share/<code> —— 4b 的导入预览。【公开、无需 token】：导入前
  // 用户可能还没登录，且落地页早就把同样的内容公开了，这里不引入新的暴露面。
  const m = request.method === "GET" && url.pathname.match(CODE_PATH_RE);
  if (m) {
    const hit = await resolvePromptShare(env, m[1]);
    if (!hit) return J({ error: "not-found" }, 404);
    let author = "";
    try { author = await readProfileName(env, `users/${hit.sub}/`) || ""; } catch { /* 无名不影响预览 */ }
    return J({
      label: hit.label, prompt: hit.instruction, appliesTo: hit.appliesTo,
      ...(hit.kind !== undefined ? { kind: hit.kind } : {}),
      author, importCount: hit.importCount,
    });
  }

  const isPost = url.pathname === "/agent/prompt-share" && request.method === "POST";
  const isDelete = url.pathname.startsWith("/agent/prompt-share/") && request.method === "DELETE";
  // …现有逻辑不变…
```

**注意**：`GET` 分支必须在 `isDelete` 的 `startsWith` 判断之前（方法不同不冲突，但顺序上先处理 GET 更清楚）。同时确认 `index.js` 里 `/agent/prompt-share` 的路由分支**不会在 GET 时先撞上 401 鉴权**——如果现有分支是先 `resolveScope` 再进 `handlePromptShareRoutes`，要把 GET 提到鉴权之前。

- [ ] **Step 5: 跑测试确认通过**

Run: `cd agent && npx vitest run test/prompt-share.test.js`
Expected: PASS

Run: `cd agent && npm test`
Expected: 全套 PASS

- [ ] **Step 6: 提交**

```bash
git add functions/lib/profile.js "functions/files/api/[[path]].js" agent/src/prompt-share.js agent/test/prompt-share.test.js
git commit -m "$(cat <<'EOF'
feat(prompts): GET /agent/prompt-share/<code> —— 4b 的导入预览

公开无需 token（导入前用户可能还没登录；落地页早已公开同样内容）。返回
{label, prompt, appliesTo, kind, author, importCount}。

写穿副本 sharedDocFor 补 appliesTo/kind/importCount，refreshPromptShare 保留
importCount（和 createdAt 一样）。老副本（重构前铸的码）没有 appliesTo →
预览回退「都行」，没有 importCount → 0。老魔法数字继续能兑换。

readProfileName 从 functions/files/api/[[path]].js 提到 functions/lib/profile.js
共用（worker 已经在 import functions/lib/auth.js，路径通）。

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: `POST /agent/prompts/import` — 存成自建副本

**Files:**
- Modify: `agent/src/prompt-routes.js`（追加）
- Modify: `agent/src/index.js`（路由分支扩到 `/agent/prompts/import`）
- Modify: `agent/test/prompts.test.js`（追加 describe 块）

**Interfaces:**
- Consumes: `resolvePromptShare` (Task 7)、`loadUserPrompts` / `saveUserPrompts` (Task 5)
- Produces: `POST /agent/prompts/import` body `{code}` → `{item}`（新追加的那条解析结果）

**语义**（spec §8）：导入 = **独立自建副本**（实体，`origin:"user"`，**无 `forkedFrom`**——它不是从系统模板 fork 的），可改名/改词/删；**原作者之后的修改不影响你**。追加到列表**末尾**。`importCount` +1（best-effort，R2 无原子自增，并发偶尔丢计数 —— 已在 spec 里接受）。

**注意**：用户如果还没有 `prompts.json`（全跟随模板），导入时要先把**当前解析出的模板列表**物化成他的列表（全 ref），再追加这条 —— 否则一 PUT 就把模板项全丢了。

- [ ] **Step 1: 写失败测试**

追加到 `agent/test/prompts.test.js`：

```js
describe("POST /agent/prompts/import — 魔法数字导入（4b）", () => {
  const IMPORT = (env, code) => worker.fetch(new Request("https://jianshuo.dev/agent/prompts/import", {
    method: "POST", headers: { Authorization: TOKEN, "content-type": "application/json" },
    body: JSON.stringify({ code }),
  }), env);
  const seedShare = (over = {}) => ({
    "shares/4820135": JSON.stringify({
      type: "prompt", sub: "anon-other", itemId: "p_orig01",
      label: "改写成播客口播稿", instruction: "把文章改写成口播稿…",
      appliesTo: ["text"], importCount: 128, ...over,
    }),
  });

  it("★ 导入 → 追加一条实体副本（origin=user，无 forkedFrom）", async () => {
    const env = fakeEnv(seedShare());
    const res = await IMPORT(env, "4820135");
    expect(res.status).toBe(200);
    const { item } = await res.json();
    expect(item.label).toBe("改写成播客口播稿");
    expect(item.prompt).toContain("口播稿");
    expect(item.appliesTo).toEqual(["text"]);
    expect(item.origin).toBe("user");
    expect(item.forkedFrom).toBeUndefined();
    expect(item.id).toMatch(/^p_[a-z0-9]{6,}$/);
  });

  it("★ 首次导入（用户还没 prompts.json）→ 模板项被物化成 ref，一条都不丢", async () => {
    const env = fakeEnv(seedShare());
    await IMPORT(env, "4820135");
    const got = await (await GET(env)).json();
    expect(got.items.length).toBe(DEFAULT_PROMPT_TEMPLATE.items.length + 1);
    // 模板项仍是 system（= 仍是 ref、仍跟随最新），没被冻结
    expect(got.items.filter((i) => i.origin === "system").length).toBe(DEFAULT_PROMPT_TEMPLATE.items.length);
    expect(got.items[got.items.length - 1].origin).toBe("user");
  });

  it("已有列表 → 追加到末尾", async () => {
    const env = fakeEnv(seedShare());
    await PUT(env, []);
    await IMPORT(env, "4820135");
    const got = await (await GET(env)).json();
    expect(got.items).toHaveLength(1);
    expect(got.items[0].origin).toBe("user");
  });

  it("importCount +1 写回 shares/<码>", async () => {
    const env = fakeEnv(seedShare());
    await IMPORT(env, "4820135");
    const doc = JSON.parse(env.FILES._store.get("shares/4820135"));
    expect(doc.importCount).toBe(129);
  });

  it("老副本无 appliesTo → 导入成「都行」", async () => {
    const env = fakeEnv(seedShare({ appliesTo: undefined }));
    const { item } = await (await IMPORT(env, "4820135")).json();
    expect(new Set(item.appliesTo)).toEqual(new Set(["text", "image"]));
  });

  it("无效码 → 404，不落盘", async () => {
    const env = fakeEnv();
    expect((await IMPORT(env, "9999999")).status).toBe(404);
    expect(SCOPE_KEY(env)).toBeUndefined();
  });

  it("缺 code → 400；无 token → 401；GET → 405", async () => {
    const env = fakeEnv(seedShare());
    expect((await worker.fetch(new Request("https://jianshuo.dev/agent/prompts/import", {
      method: "POST", headers: { Authorization: TOKEN, "content-type": "application/json" }, body: "{}",
    }), env)).status).toBe(400);
    expect((await worker.fetch(new Request("https://jianshuo.dev/agent/prompts/import", { method: "POST" }), env)).status).toBe(401);
    expect((await worker.fetch(new Request("https://jianshuo.dev/agent/prompts/import", { headers: { Authorization: TOKEN } }), env)).status).toBe(405);
  });

  it("导入两次 → 两条独立副本（各自 id 不同）", async () => {
    const env = fakeEnv(seedShare());
    const a = (await (await IMPORT(env, "4820135")).json()).item;
    const b = (await (await IMPORT(env, "4820135")).json()).item;
    expect(a.id).not.toBe(b.id);
    expect((await (await GET(env)).json()).items.filter((i) => i.origin === "user")).toHaveLength(2);
  });
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd agent && npx vitest run test/prompts.test.js`
Expected: FAIL — `/agent/prompts/import` 未接，返回 404

- [ ] **Step 3: 实现导入**

在 `agent/src/prompt-routes.js` 顶部加 import：

```js
import { resolvePromptShare } from "./prompt-share.js";
```

追加函数：

```js
/// 新实体 id：p_ + 8 位 base36。客户端也生成同格式的 id（validateList 校验格式）。
function newUserId() {
  const a = new Uint32Array(2);
  crypto.getRandomValues(a);
  return "p_" + (a[0].toString(36) + a[1].toString(36)).replace(/[^a-z0-9]/g, "").slice(0, 8).padEnd(8, "0");
}

/// 把「当前生效的列表」物化成一份【用户列表】（不是解析结果）。
/// 用户还没有 prompts.json 时，他的生效列表 = 模板全量 → 物化成全 ref，
/// 【这样模板项仍然跟随最新，只是现在显式列在他的文件里】。
function materialize(tpl, doc) {
  if (doc && Array.isArray(doc.items)) return doc.items;
  return (tpl.items || []).map((t) => (t.type === "group"
    ? { ref: t.id, children: (t.children || []).map((c) => ({ ref: c.id })) }
    : { ref: t.id }));
}

/// POST /agent/prompts/import {code} —— 导入 = 独立自建副本（origin:user，无 forkedFrom）。
/// 原作者之后的修改【不影响你】——这正是它区别于 ref 的地方。
export async function handlePromptImport(request, env, scope) {
  if (request.method !== "POST") return J({ error: "method not allowed" }, 405);
  const body = await request.json().catch(() => ({}));
  const code = String(body.code || "").trim();
  if (!/^[1-9][0-9]{6}$/.test(code)) return J({ error: "expected {code}" }, 400);

  const hit = await resolvePromptShare(env, code);
  if (!hit) return J({ error: "not-found" }, 404);

  const tpl = await loadPromptTemplate(env);
  const doc = await loadUserPrompts(env, scope);
  const items = materialize(tpl, doc);

  const item = {
    id: newUserId(), type: "action",
    label: (hit.label || "导入的提示词").slice(0, 40),
    prompt: hit.instruction,
    appliesTo: hit.appliesTo,
    ...(hit.kind !== undefined ? { kind: hit.kind } : {}),
  };
  items.push(item);

  const err = validateList(tpl, items);
  if (err) return J({ error: err }, 400);
  await saveUserPrompts(env, scope, items);

  // importCount +1 —— best-effort。R2 没有原子自增，并发导入偶尔丢计数（虚荣数字，
  // spec §8 已接受）。失败不影响导入本身。
  try {
    const obj = await env.FILES.get(`shares/${code}`);
    if (obj) {
      const share = JSON.parse(await obj.text());
      share.importCount = (share.importCount || 0) + 1;
      await env.FILES.put(`shares/${code}`, JSON.stringify(share, null, 2));
    }
  } catch (e) { console.error("[prompts] importCount bump failed:", e && e.message); }

  const resolvedItems = resolveList(tpl, { schema: 1, items });
  return J({ item: resolvedItems[resolvedItems.length - 1] });
}
```

- [ ] **Step 4: 接进 `index.js`**

把 Task 5 加的路由分支扩成：

```js
import { handlePromptsRoute, handlePromptImport } from "./prompt-routes.js";
```

```js
    if (url.pathname === "/agent/prompts" || url.pathname === "/agent/prompts/restore-defaults"
        || url.pathname === "/agent/prompts/import") {
      const scope = await resolveScope(bearerToken(request), env);
      if (!scope) return J({ error: "unauthorized" }, 401);
      if (url.pathname === "/agent/prompts/import") return handlePromptImport(request, env, scope);
      return handlePromptsRoute(request, env, scope, url);
    }
```

- [ ] **Step 5: 跑测试确认通过**

Run: `cd agent && npm test`
Expected: 全套 PASS

- [ ] **Step 6: 提交**

```bash
git add agent/src/prompt-routes.js agent/src/index.js agent/test/prompts.test.js
git commit -m "$(cat <<'EOF'
feat(prompts): POST /agent/prompts/import —— 魔法数字导入成自建副本

导入 = 独立实体副本（origin:user，无 forkedFrom）：可改名/改词/删，
原作者之后的修改不影响你。追加到列表末尾，importCount +1（best-effort，
R2 无原子自增，并发偶尔丢计数——虚荣数字，spec §8 已接受）。

关键：用户还没有 prompts.json 时先把模板【物化成全 ref】再追加——这样
模板项仍然跟随最新，只是显式列进了他的文件；否则一写就把模板项全丢了。

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: 改造铸码 — 自建提示词也能分享

**Files:**
- Modify: `agent/src/prompt-share.js`（`effectiveLeaf` 改走新解析器）
- Modify: `agent/test/prompt-share.test.js`（追加）

**Interfaces:**
- Consumes: `loadPromptTemplate` (Task 1)、`resolveList` (Task 2)、`loadUserPrompts` (Task 5)
- Produces: `effectiveLeaf(env, scope, itemId) -> Promise<{label, instruction, appliesTo, kind?}|null>` —— 从**解析后的用户列表**里找 `itemId`（可以是 `sys_*` 也可以是 `p_*`），返回生效内容。

**为什么必须改**（spec §6）：今天的 `effectiveLeaf` 是 `flattenPrompts(loadUIConfig)` 里找 —— 自建项不在系统目录里，铸码直接返回 null 而失败。**而没有这个，导入功能根本没有意义**（你只能导入系统项？那导入个啥）。

- [ ] **Step 1: 写失败测试**

追加到 `agent/test/prompt-share.test.js`：

```js
describe("铸码 POST /agent/prompt-share — 新模型（自建项也能铸）", () => {
  const TOKEN = "Bearer anon_testtoken1234567890";
  const MINT = (env, id) => worker.fetch(new Request("https://jianshuo.dev/agent/prompt-share", {
    method: "POST", headers: { Authorization: TOKEN, "content-type": "application/json" },
    body: JSON.stringify({ id }),
  }), env);
  const PUTP = (env, items) => worker.fetch(new Request("https://jianshuo.dev/agent/prompts", {
    method: "PUT", headers: { Authorization: TOKEN, "content-type": "application/json" },
    body: JSON.stringify({ items }),
  }), env);
  const shareDocOf = (env) => {
    const k = [...env.FILES._store.keys()].find((x) => x.startsWith("shares/"));
    return k ? JSON.parse(env.FILES._store.get(k)) : null;
  };

  it("★ 自建项能铸码（老实现会失败）", async () => {
    const env = fakeEnv();
    await PUTP(env, [{ id: "p_zq1f6e", type: "action", label: "写成小红书", prompt: "口语、emoji…", appliesTo: ["text"] }]);
    const res = await MINT(env, "p_zq1f6e");
    expect(res.status).toBe(200);
    expect((await res.json()).code).toMatch(/^[1-9][0-9]{6}$/);
    const doc = shareDocOf(env);
    expect(doc.label).toBe("写成小红书");
    expect(doc.instruction).toContain("口语");
    expect(doc.appliesTo).toEqual(["text"]);
  });

  it("ref 系统项能铸码，副本里是模板【当前】内容", async () => {
    const env = fakeEnv();
    const res = await MINT(env, "sys_cartoon");      // 用户还没 prompts.json，全跟随模板
    expect(res.status).toBe(200);
    const doc = shareDocOf(env);
    expect(doc.label).toBe("卡通");
    expect(doc.instruction).toContain("宫崎骏");
    expect(doc.appliesTo).toEqual(["image"]);
    expect(doc.kind).toBe("image");
  });

  it("fork 过的系统项 → 副本里是【我改过的】内容", async () => {
    const env = fakeEnv();
    await PUTP(env, [{ id: "p_abc123", type: "action", label: "卡通风", prompt: "我改过的卡通", appliesTo: ["image"], forkedFrom: "sys_cartoon" }]);
    await MINT(env, "p_abc123");
    const doc = shareDocOf(env);
    expect(doc.label).toBe("卡通风");
    expect(doc.instruction).toBe("我改过的卡通");
  });

  it("不存在的 id → 404", async () => {
    expect((await MINT(fakeEnv(), "p_nosuch")).status).toBe(404);
  });

  it("group 不能铸码 → 404（组没有 prompt）", async () => {
    expect((await MINT(fakeEnv(), "sys_style")).status).toBe(404);
  });
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd agent && npx vitest run test/prompt-share.test.js`
Expected: FAIL — 自建项铸码返回 404（`effectiveLeaf` 在系统目录里找不到）

- [ ] **Step 3: 改 `effectiveLeaf`**

在 `agent/src/prompt-share.js` 里，把 import 换掉：

```js
// 删掉：
// import { loadUIConfig, loadUserOverrides } from "./ui-config.js";
// import { flattenPrompts } from "./prompt-registry.js";
// 换成：
import { loadPromptTemplate } from "./prompt-template.js";
import { resolveList } from "./prompts.js";
import { loadUserPrompts } from "./prompt-routes.js";
```

替换 `effectiveLeaf`：

```js
/// 该用户此刻某条提示词的生效内容（走新解析器：ref 读模板 / 实体读自己）。
/// itemId 可以是 sys_*（ref 的系统项）也可以是 p_*（自建或 fork）。
/// 【这是「自建提示词也能铸码分享」的关键】——老实现在系统目录里找，自建项必然 null。
/// group 没有 prompt → 返回 null（不能分享一个空壳）。
async function effectiveLeaf(env, scope, itemId) {
  const tpl = await loadPromptTemplate(env);
  const doc = await loadUserPrompts(env, scope);
  const flat = [];
  for (const n of resolveList(tpl, doc)) {
    flat.push(n);
    for (const c of n.children || []) flat.push(c);
  }
  const hit = flat.find((n) => n.id === itemId);
  if (!hit || hit.type !== "action") return null;
  return {
    label: hit.label, instruction: hit.prompt,
    appliesTo: hit.appliesTo,
    ...(hit.kind !== undefined ? { kind: hit.kind } : {}),
  };
}
```

**循环依赖检查**：`prompt-routes.js` import 了 `prompt-share.js`（Task 8 的 `resolvePromptShare`），现在 `prompt-share.js` 又 import `prompt-routes.js`（`loadUserPrompts`）——这是 ESM 循环。**必须消除**：把 `loadUserPrompts` / `saveUserPrompts` 从 `prompt-routes.js` 挪到一个新的叶子模块 `agent/src/prompt-store.js`，两边都 import 它。

创建 `agent/src/prompt-store.js`：

```js
// src/prompt-store.js — users/<sub>/prompts.json 的读写（叶子模块，无业务依赖）。
// 单独成文件是为了打断 prompt-routes ↔ prompt-share 的 ESM 循环依赖。
const docKey = (scope) => `${scope}prompts.json`;

/// 没有 / 坏文件 → null（= 全跟随模板）。坏文件绝不能 500。
export async function loadUserPrompts(env, scope) {
  try {
    const obj = await env.FILES.get(docKey(scope));
    if (!obj) return null;
    const doc = JSON.parse(await obj.text());
    if (doc && Array.isArray(doc.items)) return doc;
  } catch (e) {
    console.error("[prompts] bad prompts.json:", e && e.message);
  }
  return null;
}

export async function saveUserPrompts(env, scope, items) {
  await env.FILES.put(docKey(scope), JSON.stringify({ schema: 1, items }, null, 2), {
    httpMetadata: { contentType: "application/json" },
  });
}
```

然后：
- `prompt-routes.js`：删掉自己的 `docKey`/`loadUserPrompts`/`saveUserPrompts` 定义，改成 `import { loadUserPrompts, saveUserPrompts } from "./prompt-store.js";` 并**继续 re-export** 它们（`export { loadUserPrompts, saveUserPrompts };`），这样 Task 5/8 里已写的用法不变。
- `prompt-share.js`：`import { loadUserPrompts } from "./prompt-store.js";`

- [ ] **Step 4: 跑测试确认通过**

Run: `cd agent && npm test`
Expected: 全套 PASS

- [ ] **Step 5: 提交**

```bash
git add agent/src/prompt-store.js agent/src/prompt-routes.js agent/src/prompt-share.js agent/test/prompt-share.test.js
git commit -m "$(cat <<'EOF'
refactor(prompts): 铸码走新解析器 —— 自建提示词第一次能被分享

effectiveLeaf 从「系统目录里找」改成「解析后的用户列表里找」。老实现对自建项
必然返回 null → 铸码失败；而没有这个，魔法数字导入根本没有意义（只能导入系统项？）。

ref 系统项铸出的副本 = 模板当前内容；fork 过的 = 我改过的内容。group 不能铸（无 prompt）。

新增叶子模块 prompt-store.js 存放 loadUserPrompts/saveUserPrompts，打断
prompt-routes ↔ prompt-share 的 ESM 循环依赖。

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 10: 改造 `prompt-registry` — 读写新模板

**Files:**
- Modify: `agent/src/prompt-registry.js`
- Modify: `agent/test/prompt-registry.test.js`

**Interfaces:**
- Consumes: `loadPromptTemplate` / `DEFAULT_PROMPT_TEMPLATE` (Task 1)
- Produces（**对外形状不变**，`prompt.jianshuo.dev` 调优页零改动）：
  - `GET /agent/prompt-registry` → `{prompts: [{id, label, instruction}]}`（管理 token）
  - `PUT /agent/prompt-registry` body `{id, instruction}` → 改一条并整体写回 R2 `config/prompt-template.json`
  - `flattenTemplate(tpl) -> [{id, label, instruction}]`（只收 action；group 无 instruction 不收）
  - `updateTemplatePrompt(tpl, id, instruction) -> tpl|null`

`id` 从语义路径变成 `sys_*`。调优页把 id 当**不透明串**用（列出来 → 改 instruction → PUT 回去），所以不受影响。

**写回目标从 `config/ui-config.json` 换成 `config/prompt-template.json`。**

- [ ] **Step 1: 改测试**

打开 `agent/test/prompt-registry.test.js`，把里面对老 `flattenPrompts` / `updatePrompt` / `DEFAULT_UI_CONFIG` 的引用换成新的。核心用例（若已有等价的就改 id，没有就加）：

```js
import { describe, it, expect } from "vitest";
import { flattenTemplate, updateTemplatePrompt } from "../src/prompt-registry.js";
import { DEFAULT_PROMPT_TEMPLATE } from "../src/prompt-template.js";

describe("flattenTemplate — 对外形状不变 {id,label,instruction}", () => {
  const flat = flattenTemplate(DEFAULT_PROMPT_TEMPLATE);

  it("只收 action（12 条），group 不收（无 instruction）", () => {
    expect(flat.length).toBe(12);
    for (const p of flat) {
      expect(typeof p.id).toBe("string");
      expect(typeof p.label).toBe("string");
      expect(typeof p.instruction).toBe("string");
    }
  });

  it("id 是 sys_*，label 带父组前缀（和老的 `父 · 叶` 一致，调优页靠它认人）", () => {
    const cartoon = flat.find((p) => p.id === "sys_cartoon");
    expect(cartoon.label).toBe("图片风格 · 卡通");
    expect(cartoon.instruction).toContain("宫崎骏");
    const cover = flat.find((p) => p.id === "sys_wechat_cover");
    expect(cover.label).toBe("插入图片 · 公众号题图");
  });
});

describe("updateTemplatePrompt", () => {
  it("改一条 → 返回改过的深拷贝，原对象不动", () => {
    const next = updateTemplatePrompt(DEFAULT_PROMPT_TEMPLATE, "sys_cartoon", "新的卡通指令");
    const idOf = (t, id) => flattenTemplate(t).find((p) => p.id === id).instruction;
    expect(idOf(next, "sys_cartoon")).toBe("新的卡通指令");
    expect(idOf(DEFAULT_PROMPT_TEMPLATE, "sys_cartoon")).toContain("宫崎骏");   // 原对象没被改
  });

  it("改顶层 action（不在组里）也行", () => {
    const tpl = { schema: 1, items: [{ id: "sys_top", type: "action", label: "顶层", prompt: "旧", appliesTo: ["text"] }] };
    expect(flattenTemplate(updateTemplatePrompt(tpl, "sys_top", "新"))[0].instruction).toBe("新");
  });

  it("id 不存在 → null", () => {
    expect(updateTemplatePrompt(DEFAULT_PROMPT_TEMPLATE, "sys_nope", "x")).toBeNull();
  });

  it("group id → null（组没有 instruction 可改）", () => {
    expect(updateTemplatePrompt(DEFAULT_PROMPT_TEMPLATE, "sys_style", "x")).toBeNull();
  });
});
```

**路由测试**（若原文件已有，改成断言写回 `config/prompt-template.json`）：

```js
import { vi } from "vitest";
vi.mock("agents", () => ({ Agent: class Agent {}, getAgentByName: async () => ({}) }));
import worker from "../src/index.js";
import { fakeEnv } from "./fakes.js";

describe("/agent/prompt-registry 路由（管理 token）", () => {
  const ADMIN = { FILES_TOKEN: "admintok" };
  const H = { Authorization: "Bearer admintok" };

  it("GET → {prompts:[…]}（12 条）", async () => {
    const env = { ...fakeEnv(), ...ADMIN };
    const res = await worker.fetch(new Request("https://jianshuo.dev/agent/prompt-registry", { headers: H }), env);
    expect(res.status).toBe(200);
    expect((await res.json()).prompts.length).toBe(12);
  });

  it("PUT → 写回 config/prompt-template.json，GET 立刻读到新值", async () => {
    const env = { ...fakeEnv(), ...ADMIN };
    const put = await worker.fetch(new Request("https://jianshuo.dev/agent/prompt-registry", {
      method: "PUT", headers: { ...H, "content-type": "application/json" },
      body: JSON.stringify({ id: "sys_cartoon", instruction: "调优后的卡通" }),
    }), env);
    expect(put.status).toBe(200);
    expect(env.FILES._store.has("config/prompt-template.json")).toBe(true);

    const res = await worker.fetch(new Request("https://jianshuo.dev/agent/prompt-registry", { headers: H }), env);
    const hit = (await res.json()).prompts.find((p) => p.id === "sys_cartoon");
    expect(hit.instruction).toBe("调优后的卡通");
  });

  it("非管理 token → 401", async () => {
    const env = { ...fakeEnv(), ...ADMIN };
    const res = await worker.fetch(new Request("https://jianshuo.dev/agent/prompt-registry", {
      headers: { Authorization: "Bearer anon_testtoken1234567890" },
    }), env);
    expect(res.status).toBe(401);
  });
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd agent && npx vitest run test/prompt-registry.test.js`
Expected: FAIL — `flattenTemplate is not exported`

- [ ] **Step 3: 改 `agent/src/prompt-registry.js`**

把 import 从 `./ui-config.js` 换成 `./prompt-template.js`，用下面两个函数替换 `flattenPrompts` / `updatePrompt`，并把写回的 R2 key 改成 `config/prompt-template.json`：

```js
import { loadPromptTemplate } from "./prompt-template.js";

// 打平成 [{id, label, instruction}] —— 只收 action（group 没有 instruction）。
// label 带父组前缀（`图片风格 · 卡通`），和老的层级 label 一致：调优页靠它认人。
export function flattenTemplate(tpl) {
  const out = [];
  for (const item of tpl.items || []) {
    if (item.type === "action") {
      out.push({ id: item.id, label: item.label, instruction: item.prompt });
    }
    for (const c of item.children || []) {
      if (c.type === "action") {
        out.push({ id: c.id, label: `${item.label} · ${c.label}`, instruction: c.prompt });
      }
    }
  }
  return out;
}

// 返回替换了目标 action 的 prompt 的深拷贝；id 找不到 / 是 group → null。
export function updateTemplatePrompt(tpl, id, instruction) {
  const next = JSON.parse(JSON.stringify(tpl));
  for (const item of next.items || []) {
    if (item.id === id) return item.type === "action" ? ((item.prompt = instruction), next) : null;
    for (const c of item.children || []) {
      if (c.id === id) return c.type === "action" ? ((c.prompt = instruction), next) : null;
    }
  }
  return null;
}
```

路由体里：`loadUIConfig(env)` → `loadPromptTemplate(env)`；`flattenPrompts` → `flattenTemplate`；`updatePrompt` → `updateTemplatePrompt`；`env.FILES.put("config/ui-config.json", …)` → `env.FILES.put("config/prompt-template.json", …)`。

- [ ] **Step 4: 跑测试确认通过**

Run: `cd agent && npx vitest run test/prompt-registry.test.js`
Expected: PASS

- [ ] **Step 5: 提交**

```bash
git add agent/src/prompt-registry.js agent/test/prompt-registry.test.js
git commit -m "$(cat <<'EOF'
refactor(prompts): prompt-registry 读写新模板

零部署 prompt 调优闭环（prompt.jianshuo.dev）指向 config/prompt-template.json。
对外响应形状 {prompts:[{id,label,instruction}]} 不变，只是 id 从语义路径变成
sys_*（调优页把 id 当不透明串用，不受影响）。label 保留 `父 · 叶` 前缀。

这条链之所以要保住：ref 项永远读模板最新版 —— 调优页一改，所有没 fork 过
这条的用户立刻吃到。

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 11: 删除 `ui-config` / `ui-config-custom`

**Files:**
- Delete: `agent/src/ui-config.js`、`agent/src/ui-config-custom.js`
- Delete: `agent/test/ui-config.test.js`、`agent/test/ui-config-custom.test.js`
- Modify: `agent/src/index.js`（删 import + 两个路由分支）

**前置**：Task 9 和 10 已经把 `prompt-share.js` / `prompt-registry.js` 对 `ui-config.js` 的依赖切干净了。删之前先确认没人再 import 它。

**影响（spec §6，用户已确认接受）**：老 app 拉 `GET /agent/ui-config` 会 404 → `UIConfigStore.refresh()` 的失败路径是**静默保留现值** → 退回 app 内置的默认菜单（不崩）。老设置页（`/agent/ui-config/custom`）会显示"加载失败"——那个页面正是 Phase 2 要换掉的。**所以 Phase 1 和 Phase 2 之间的窗口越短越好。**

- [ ] **Step 1: 确认没有残留 import**

Run:
```bash
cd ~/code/jianshuo.dev-prompts
grep -rn "ui-config" agent/src agent/test functions | grep -v "^agent/src/ui-config" | grep -v "^agent/test/ui-config"
```
Expected: **无输出**。有输出就说明还有引用没切干净，先切掉再继续。

- [ ] **Step 2: 删文件 + 路由**

```bash
git rm agent/src/ui-config.js agent/src/ui-config-custom.js \
       agent/test/ui-config.test.js agent/test/ui-config-custom.test.js
```

在 `agent/src/index.js` 里删掉：
- `import { loadUIConfigFor } from "./ui-config.js";`
- `import { handleUIConfigCustom } from "./ui-config-custom.js";`
- `if (url.pathname === "/agent/ui-config/custom") { … }` 整个分支
- `if (url.pathname === "/agent/ui-config") { … }` 整个分支

- [ ] **Step 3: 跑全套确认绿**

Run: `cd agent && npm test`
Expected: 全套 PASS。用例数 = 基线（Task 0 记的） − (ui-config.test 的用例数 + ui-config-custom.test 的用例数) + 本次新增（prompt-template 7 + prompts 44+9 + prompt-classify 12 + prompt-share 新增 + prompt-registry 改写）。

- [ ] **Step 4: 起本地 worker 冒烟**

```bash
cd agent && npx wrangler dev --local
```
另开一个终端：
```bash
curl -s localhost:8787/agent/prompts -H "Authorization: Bearer anon_smoketoken1234567890" | head -c 400
```
Expected: `{"schema":1,"items":[{"id":"sys_style","type":"group",…"origin":"system"…`

```bash
curl -s localhost:8787/agent/ui-config -H "Authorization: Bearer anon_smoketoken1234567890" -o /dev/null -w "%{http_code}\n"
```
Expected: `404`（老端点已删）

- [ ] **Step 5: 提交**

```bash
git add -A
git commit -m "$(cat <<'EOF'
refactor(prompts)!: 删掉 ui-config / ui-config-custom

老模型（系统固定目录 + 稀疏覆盖 + 语义 id）整体退役，由 prompt-template +
prompts.json 的 ref/fork 模型取代。

BREAKING：GET /agent/ui-config 与 GET/PUT /agent/ui-config/custom 不再存在。
已装机的老 app 长按菜单会静默退回 app 内置默认（UIConfigStore.refresh 失败路径
= 保留现值，不崩）；老设置页显示加载失败——那个页面正是 Phase 2 要换掉的。
所以 Phase 1 与 Phase 2 之间的窗口要尽量短。用户已确认接受。

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
EOF
)"
```

---

### Task 12: 部署 + 更新 STATE.md

**Files:**
- Modify: `~/code/voicedrop/STATE.md`

- [ ] **Step 1: 合回 main 并部署 worker**

```bash
cd ~/code/jianshuo.dev-prompts
git push -u origin prompt-manager-server
# 用户 review / 合并后：
cd agent && npx wrangler deploy
```

**⚠️ 部署后线上就没有 `/agent/ui-config` 了。** 确认 Phase 2 的 iOS 工作紧接着排上。

- [ ] **Step 2: 线上冒烟**

```bash
TOK=<一个有效的 anon token>
curl -s https://jianshuo.dev/agent/prompts -H "Authorization: Bearer $TOK" | python3 -m json.tool | head -30
curl -s https://jianshuo.dev/agent/prompt-share/9999999 -o /dev/null -w "%{http_code}\n"   # 期望 404
curl -s -X POST https://jianshuo.dev/agent/prompt-classify \
  -H "Authorization: Bearer $TOK" -H "content-type: application/json" \
  -d '{"prompt":"把这段改得更简洁"}'   # 期望 {"appliesTo":["text"],"reason":"…"}
```

- [ ] **Step 3: 更新 `~/code/voicedrop/STATE.md`**

把「## 新功能：指令分享码「魔法数字」」那节下面（或新起一节）写清楚新模型，**至少覆盖**：

- 提示词后端已换成 **ref/fork 模型**：模板 `agent/src/prompt-template.js`（R2 `config/prompt-template.json` 可整体覆盖，零部署调优）+ 每用户 `users/<sub>/prompts.json`。
- **用户列表每项两种形态**：`{"ref":"sys_*"}`（跟随模板最新）或完整实体（冻结）。**没有 prompts.json = 全跟随** —— 所以 GET **绝不为新用户落盘**，改这条前先想清楚。
- **老的语义 id 和 `/agent/ui-config*` 全部废除**；`prompt-registry` 现在读写 `config/prompt-template.json`。
- 端点：`GET/PUT /agent/prompts`、`POST /agent/prompts/{restore-defaults,import}`、`POST /agent/prompt-classify`、`GET /agent/prompt-share/<code>`（公开）。
- **老魔法数字继续能兑换**（写穿副本不依赖 itemId），但不再自动同步。
- **Phase 2（iOS）未做**：老 app 的长按菜单当前退回内置默认。spec/plan 路径。

```bash
cd ~/code/voicedrop && git add STATE.md && git commit -m "docs(state): 提示词后端换成 ref/fork 模型（Phase 1 服务端上线）"
```

---

## Self-Review

**Spec 覆盖检查：**

| Spec 段 | Task |
|---|---|
| §2 ref→fork 模型 | Task 2（`resolveList` + 核心性质单测）|
| §3 数据结构（模板 / 用户文档 / 字段 / group fork）| Task 1、2、3 |
| §4 解析 + 不做自动追加 | Task 2、4 |
| §5 过滤 | **不在 Phase 1**（spec 已注明：过滤只存在于 iOS）|
| §6 六个端点 | Task 5（GET/PUT/restore）、6（classify）、7（share GET）、8（import）|
| §6 PUT 校验 | Task 3 |
| §6 改造 registry / share | Task 10、9 |
| §6 删除 ui-config* | Task 11 |
| §6 老码继续兑换 | Task 7（`resolvePromptShare` 回退 appliesTo）|
| §7 classify 回退 | Task 6 |
| §8 导入语义 + author + importCount | Task 7、8 |
| §9 iOS | **Phase 2，不在本计划** |
| §11 测试清单 | 各 Task 的 Step 1 |
| §12 分期 | Task 12 |

**类型一致性检查：**
- `resolveList(template, userDoc)` —— userDoc 是 `{schema, items}` 或 `null`。Task 5/8/9 调用时都包成 `{schema:1, items}` 或直接传 `loadUserPrompts` 的返回值（`doc|null`）。✓
- `validateList(template, items)` —— 第二参是**裸数组**（不是 doc）。Task 5、8 调用时传的是 `body.items` / `items`。✓
- `restoreDefaults(template, items)` → 返回**裸的用户列表数组**（不是解析结果），Task 5 拿它去 `saveUserPrompts` + `resolved()`。✓
- `loadUserPrompts` / `saveUserPrompts` 最终住在 `prompt-store.js`（Task 9 建，为打断循环依赖），`prompt-routes.js` re-export，所以 Task 5/8 写的调用不用改。✓
- `effectiveLeaf` 返回 `{label, instruction, appliesTo, kind?}`，`sharedDocFor(scope, itemId, leaf, createdAt, importCount)` 消费它。✓

**已知的计划内返工：** Task 5 先把 `loadUserPrompts`/`saveUserPrompts` 写在 `prompt-routes.js`，Task 9 再挪到 `prompt-store.js`。这是**故意**的——循环依赖要到 Task 9 引入 `prompt-share` → `prompt-routes` 的反向 import 时才出现，提前抽会让 Task 5 平白多一个文件。Task 9 的 Step 3 已写明怎么挪。
