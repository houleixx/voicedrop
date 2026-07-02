# VoiceDrop 语音指令 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 长按「我的录音」底部红键 → 列表浮序号 → 对讲机式说一句自然语言指令 → Claude 理解并对文章库执行（合并/删除/换风格/归类…）。

**Architecture:** 复用现有「语音编辑」栈——iOS `SpeechDictation` + `/agent/asr` 火山代理 + `runAgentLoop` + `ArticleQueue` + 反馈气泡全部原样用；抽出共享 `PushToTalkBar` + `VoiceAgentSession` 协议；库级新增一层：`/agent/command` WS + `LibraryAgent` DO + `runCommandTurn` + 库级工具集 + `meteredCommandGate`。两套 agent（`ArticleEditor` per-stem 与 `LibraryAgent` per-user）本期并存，完全统一留后续。

**Tech Stack:** Cloudflare Workers（Durable Objects / Agents SDK / R2 `env.FILES` / D1 `env.USAGE`）、Vitest、Claude tool-use、火山（豆包）流式 ASR、SwiftUI + `@Observable`、xcodegen。

**分两阶段**：Phase 1（服务端，Task 1–9）自成可测可上线的 `/agent/command`；Phase 2（iOS，Task 10–14）消费该端点。Phase 1 可先单独 ship。

## Global Constraints

- 所有 UI 文案中文。
- ASR = 火山（豆包）流式，走现有 `/agent/asr`，服务端持凭证；客户端只把已转写文本发给 `/agent/command`。
- LLM = Claude（Anthropic-only，`resolveEditModel`），用最新型号。
- 写文章一律走版本化 Files API `PUT ${origin}/files/api/articles/${stem}`，不直接 R2 put 文章 JSON；沿用 `doc.lastEditId` exactly-once。
- 「我的录音」列表锚在 `.m4a` 上：任何"无录音的独立文章"（合并产物）必须**先写 `articles/<stem>.json`、再写 0s 静音 `<stem>.m4a`**，新 stem 不带 `Task` token。
- 计费走 `USAGE` D1（`ensureAccount`/`debit`），reason 用 `"command"`。
- 新增 iOS 文件后跑 `xcodegen generate`（`project.yml` 是真源）。
- 服务端测试放 `agent/test/`，跑 `cd ~/code/jianshuo.dev/agent && npm test`。
- 合并 = 非破坏（留原文）→ 直接执行；唯一破坏性动作 = `delete_article` → 走 confirm 流。

---

# Phase 1 — 服务端 command agent（`~/code/jianshuo.dev/agent`）

## File Structure（Phase 1）

- `src/loop.js`（改）— `runAgentLoop` 支持传入 `tools` / `terminalTools`，收集工具的 `pending`。
- `src/tools.js`（改）— 新增库级工具 `merge_articles` / `delete_article` / `restyle_article` / `tag_article`；导出 `COMMAND_TOOL_NAMES`、`toolDefsFor(names)`、`deleteArticleFiles`。
- `src/command-turn.js`（新）— `runCommandTurn`（mirror `edit-turn.js`）。
- `src/index.js`（改）— `meteredCommandGate`、`LibraryAgent` DO（clone `ArticleEditor`）、`/agent/command` 路由。
- `wrangler.jsonc`（改）— `LibraryAgent` DO 绑定 + migration v5。
- 测试：`test/command-tools.test.js`、`test/command-turn.test.js`、`test/usage-command.test.js`（新）。

---

## Task 1: `runAgentLoop` 支持可选工具集 + 收集 pending

**Files:**
- Modify: `src/loop.js`
- Test: `test/loop-tools.test.js`（新）

**Interfaces:**
- Produces: `runAgentLoop({ callClaude, ctx, system, userContent, history, maxSteps, tools, terminalTools })` — `tools` 默认 `TOOL_DEFS`，`terminalTools` 默认 `TERMINAL_TOOLS`。返回值新增 `pending`（数组，来自任何工具 result 里的 `pending` 字段）。

- [ ] **Step 1: 写失败测试** —— `test/loop-tools.test.js`

```js
import { describe, it, expect } from "vitest";
import { runAgentLoop } from "../src/loop.js";

// 一个假 Claude：第一次调用返回对 fake_tool 的 tool_use，第二次返回纯文本收尾。
function fakeClaude(seq) { let i = 0; return async () => seq[i++]; }

describe("runAgentLoop tools/terminalTools/pending", () => {
  it("只把传入的 tools 交给 callClaude，并透传 pending", async () => {
    let sawTools = null;
    const call = async ({ tools }) => {
      sawTools = tools;
      return { content: [
        { type: "text", text: "好的" },
        { type: "tool_use", id: "t1", name: "stage_thing", input: { x: 1 } },
      ] };
    };
    // stage_thing 不是真工具；用注入的 runTool? loop 用全局 runTool，所以注册一个假的。
    const { pending } = await runAgentLoop({
      callClaude: call, ctx: {}, system: "s", userContent: "u",
      tools: [{ name: "stage_thing", description: "d", input_schema: { type: "object", properties: {} } }],
      terminalTools: new Set(["stage_thing"]),
    });
    expect(sawTools.map((t) => t.name)).toEqual(["stage_thing"]);
    expect(pending).toEqual([{ action: "thing" }]);
  });
});
```
> 注：`stage_thing` 需在 `tools.js` 注册一个返回 `{ ok:true, pending:{action:"thing"} }` 的最小工具，或改测试用 `merge_articles` 等真工具。实现 Step 3 时把该桩换成真工具后删掉桩。为让本测试独立通过，Step 3 先在 `tools.js` 注册一个 `__test_stage`（仅测试用）返回 `{ok:true, pending:{action:"thing"}}` —— 不，YAGNI。改法见 Step 3。

- [ ] **Step 2: 跑测试确认失败**

Run: `cd ~/code/jianshuo.dev/agent && npx vitest run test/loop-tools.test.js`
Expected: FAIL（`runAgentLoop` 目前不接受 `tools`/`terminalTools`，也不返回 `pending`）。

- [ ] **Step 3: 改 `runAgentLoop`**

在 `src/loop.js` 把签名与循环体改为（保留原有逻辑，仅参数化 tools/terminal 并收集 pending）：

```js
export async function runAgentLoop({ callClaude, ctx, system, userContent, history = [], maxSteps = 8, tools = TOOL_DEFS, terminalTools = TERMINAL_TOOLS }) {
  const messages = [...history, { role: "user", content: userContent }];
  const calledTools = [];
  const toolRuns = [];
  const pending = [];                       // 工具暂存、待客户端确认的破坏性动作
  let finalText = "";
  let hadError = false;
  let steps = 0;
  while (steps < maxSteps) {
    const resp = await callClaude({ system, messages, tools });     // ← 用传入的 tools
    steps++;
    const { text, toolUses } = parseAssistant(resp);
    messages.push({ role: "assistant", content: resp.content });
    if (!toolUses.length) { finalText = text; break; }
    const results = [];
    let terminalDone = false;
    for (const tu of toolUses) {
      calledTools.push(tu.name);
      const result = await runTool(tu.name, tu.input, ctx);
      toolRuns.push({ step: steps - 1, name: tu.name, input: tu.input, result, ok: !(result && result.error) });
      if (result && result.error) hadError = true;
      if (result && result.pending) pending.push(result.pending);  // ← 收集 pending
      if (result && result.ok === true && terminalTools.has(tu.name)) terminalDone = true;
      results.push({ type: "tool_result", tool_use_id: tu.id, content: JSON.stringify(result) });
    }
    messages.push({ role: "user", content: results });
    if (terminalDone && !hadError) { finalText = text; break; }
  }
  return { calledTools, toolRuns, finalText, steps, hadError, pending };
}
```

同时把 `const TERMINAL_TOOLS = ...` 保持不变（默认值）。

对 Step 1 测试的桩：把测试改成用一个内联注册的工具——在测试顶部：
```js
import { register } from "../src/tools.js";
register({ name: "stage_thing", description: "d", input_schema: { type: "object", properties: {} } },
  async () => ({ ok: true, pending: { action: "thing" } }));
```
（`register` 幂等追加到全局，测试进程内可用。）

- [ ] **Step 4: 跑测试确认通过**

Run: `npx vitest run test/loop-tools.test.js`  →  Expected: PASS

- [ ] **Step 5: 全量回归**（确保没破坏现有编辑流）

Run: `npm test`  →  Expected: 全绿（原有用例不受影响，默认参数不变）。

- [ ] **Step 6: Commit**

```bash
git add src/loop.js test/loop-tools.test.js
git commit -m "feat(agent): runAgentLoop 支持可选 tools/terminalTools + 收集 pending（为库级 agent 铺路）"
```

---

## Task 2: 库级工具 `merge_articles` / `restyle_article` / `tag_article`

**Files:**
- Modify: `src/tools.js`
- Test: `test/command-tools.test.js`（新）

**Interfaces:**
- Consumes: `register` (`src/tools.js`)、`restyleArticle(env, scope, stem, styleV)` (`src/miner.js:777`)、`silentM4aBytes()` (`src/silent-m4a.js`)、`readStyleText`（`functions/lib/style-store.js`）。
- Produces: 三个已注册工具，ctx 需含 `{ env, scope, token, origin, callClaude, turnId }`。`merge_articles` 产出新 stem `VoiceDrop-merged-<ts>`。

- [ ] **Step 1: 写失败测试** —— `test/command-tools.test.js`

```js
import { describe, it, expect, vi } from "vitest";
import { runTool } from "../src/tools.js";

// 极简 env.FILES（内存 R2），够工具读写。
function memFiles(seed = {}) {
  const store = new Map(Object.entries(seed));
  return {
    _store: store,
    async get(k) { return store.has(k) ? { async text() { return store.get(k); }, async json() { return JSON.parse(store.get(k)); } } : null; },
    async put(k, v) { store.set(k, typeof v === "string" ? v : "BYTES"); },
    async head(k) { return store.has(k) ? {} : null; },
    async delete(k) { store.delete(k); },
    async list({ prefix }) { return { objects: [...store.keys()].filter((k) => k.startsWith(prefix)).map((key) => ({ key })) }; },
  };
}
const SCOPE = "users/abc/";
function art(stem, title, body, extra = {}) { return JSON.stringify({ schema: 2, articles: [{ title, body }], transcript: "", createdAt: 1, ...extra }); }

describe("merge_articles", () => {
  it("读多篇→Claude 揉成一篇→写新文章+静音 m4a→原文保留", async () => {
    const env = { FILES: memFiles({
      [`${SCOPE}articles/A.json`]: art("A", "甲", "甲的正文"),
      [`${SCOPE}articles/B.json`]: art("B", "乙", "乙的正文"),
    }) };
    // ctx.callClaude 返回合并结果（第一行标题，其余正文）
    const callClaude = vi.fn(async () => ({ content: [{ type: "text", text: "合璧\n甲乙合一的正文" }], usage: {} }));
    // 拦截 Files API PUT（新文章写回）
    const fetchSpy = vi.fn(async () => ({ ok: true, status: 200 }));
    vi.stubGlobal("fetch", fetchSpy);

    const r = await runTool("merge_articles", { stems: ["A", "B"] },
      { env, scope: SCOPE, token: "tk", origin: "https://jianshuo.dev", callClaude });

    expect(r.ok).toBe(true);
    expect(r.newStem).toMatch(/^VoiceDrop-merged-/);
    // 新文章通过 Files API PUT 写出，标题「合璧」
    const put = fetchSpy.mock.calls.find(([u, o]) => o?.method === "PUT" && String(u).includes(`/files/api/articles/${r.newStem}`));
    expect(put).toBeTruthy();
    expect(JSON.parse(put[1].body).articles[0].title).toBe("合璧");
    // 静音 m4a 锚点写了
    expect(env.FILES._store.has(`${SCOPE}${r.newStem}.m4a`)).toBe(true);
    // 原文保留
    expect(env.FILES._store.has(`${SCOPE}articles/A.json`)).toBe(true);
    expect(env.FILES._store.has(`${SCOPE}articles/B.json`)).toBe(true);
    vi.unstubAllGlobals();
  });
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `npx vitest run test/command-tools.test.js`  →  Expected: FAIL（`unknown_tool`）。

- [ ] **Step 3: 实现三个工具** —— 在 `src/tools.js` 末尾追加

```js
import { restyleArticle } from "./miner.js";
import { silentM4aBytes } from "./silent-m4a.js";
import { readStyleText } from "../../functions/lib/style-store.js";

// 生成合并/新文章的 stem。ts 用调用时刻（普通 Worker 运行时，Date 可用）。
function mergedStem() {
  const d = new Date();
  const p = (n) => String(n).padStart(2, "0");
  return `VoiceDrop-merged-${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}-${p(d.getHours())}${p(d.getMinutes())}${p(d.getSeconds())}`;
}

// 把一篇「无录音的独立文章」写进库并让它出现在「我的录音」：先写 article JSON（版本化
// Files API），再写 0s 静音 m4a 锚点。返回 { ok, stem } 或 { error }。
async function writeStandaloneArticle({ env, scope, token, origin }, stem, title, body) {
  const doc = { schema: 2, id: stem, sourceAudio: `${stem}.m4a`, createdAt: new Date().toISOString(), transcript: "", srt: "", articles: [{ title, body }], status: "ready", model: "merge" };
  const resp = await globalThis.fetch(`${origin}/files/api/articles/${stem}`, {
    method: "PUT", headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" }, body: JSON.stringify(doc),
  });
  if (!resp.ok) return { error: `upload_failed_${resp.status}` };
  await env.FILES.put(`${scope}${stem}.m4a`, silentM4aBytes(), { httpMetadata: { contentType: "audio/mp4" } });
  return { ok: true, stem };
}

register(
  { name: "merge_articles", destructive: false,
    description: "把若干篇文章揉成一篇连贯的新文章（保持用户文风、去重、顺逻辑），另存为新一条，原文保留。用于「把第3和第4篇合并」。stems 传要合并的文章 stem 数组。",
    input_schema: { type: "object", properties: { stems: { type: "array", items: { type: "string" } }, guidance: { type: "string", description: "可选，合并侧重" } }, required: ["stems"], additionalProperties: false } },
  async ({ stems, guidance }, ctx) => {
    const { env, scope, callClaude } = ctx;
    if (!Array.isArray(stems) || stems.length < 2) return { error: "need_two_stems" };
    const parts = [];
    for (const stem of stems) {
      if (badStem(stem)) return { error: "bad_stem" };
      const obj = await env.FILES.get(`${scope}articles/${stem}.json`);
      if (!obj) return { error: `not_found:${stem}` };
      let doc; try { doc = JSON.parse(await obj.text()); } catch { return { error: `bad_article:${stem}` }; }
      const a = resolveArticles(doc)[0] || {};
      parts.push(`《${a.title || "(无题)"}》\n${a.body || ""}`);
    }
    const style = (await readStyleText(env, `${scope}CLAUDE.json`).catch(() => "")) || "";
    const system = `你是${"王建硕"}的写作助手。把用户给的几篇文章揉成一篇连贯的新文章：去重、顺逻辑、保持下面这套写作风格。第一行只写标题（不加书名号/引号），其余为正文。\n\n【写作风格】\n${style}`.trim();
    const user = `${guidance ? `合并侧重：${guidance}\n\n` : ""}请把以下 ${parts.length} 篇合并成一篇：\n\n${parts.join("\n\n---\n\n")}`;
    const resp = await callClaude({ system, messages: [{ role: "user", content: user }] });
    const text = (resp.content || []).filter((b) => b.type === "text").map((b) => b.text).join("").trim();
    if (!text) return { error: "empty_merge" };
    const nl = text.indexOf("\n");
    const title = (nl === -1 ? text : text.slice(0, nl)).trim().slice(0, 40) || "合并文章";
    const body = (nl === -1 ? "" : text.slice(nl + 1)).trim();
    const stem = mergedStem();
    const w = await writeStandaloneArticle(ctx, stem, title, body);
    if (w.error) return w;
    return { ok: true, newStem: stem, title, merged: stems.length };
  }
);

register(
  { name: "restyle_article", destructive: false,
    description: "用当前写作风格把某篇文章重写一遍（换个风格/口吻）。stem 是要重写的文章。",
    input_schema: { type: "object", properties: { stem: { type: "string" } }, required: ["stem"], additionalProperties: false } },
  async ({ stem }, { env, scope }) => {
    if (badStem(stem)) return { error: "bad_stem" };
    const r = await restyleArticle(env, scope, stem, null);   // null → 用当前文风 head
    return r && r.ok === false ? { error: r.error || "restyle_failed" } : { ok: true, stem };
  }
);

register(
  { name: "tag_article", destructive: false,
    description: "给一篇或多篇文章打标签/归类。stems 是文章数组，tag 是标签名。",
    input_schema: { type: "object", properties: { stems: { type: "array", items: { type: "string" } }, tag: { type: "string" } }, required: ["stems", "tag"], additionalProperties: false } },
  async ({ stems, tag }, { env, scope, token, origin }) => {
    if (!Array.isArray(stems) || !stems.length || !tag) return { error: "bad_args" };
    for (const stem of stems) {
      if (badStem(stem)) return { error: "bad_stem" };
      const obj = await env.FILES.get(`${scope}articles/${stem}.json`);
      if (!obj) continue;
      let doc; try { doc = JSON.parse(await obj.text()); } catch { continue; }
      doc.tags = Array.from(new Set([...(doc.tags || []), String(tag)]));
      const resp = await globalThis.fetch(`${origin}/files/api/articles/${stem}`, {
        method: "PUT", headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" }, body: JSON.stringify(doc),
      });
      if (!resp.ok) return { error: `upload_failed_${resp.status}` };
    }
    return { ok: true, tagged: stems.length, tag };
  }
);
```

> 注：`restyleArticle` 的返回值以 `src/miner.js:777` 实际实现为准；若它抛错则包在 try/catch。实现时读一眼确认返回形状（成功返回含 `ok`/文章，失败抛错或 `{error}`），据此调整该工具的判定。

- [ ] **Step 4: 跑测试确认通过** — `npx vitest run test/command-tools.test.js` → PASS

- [ ] **Step 5: Commit**

```bash
git add src/tools.js test/command-tools.test.js
git commit -m "feat(agent): 库级工具 merge_articles/restyle_article/tag_article（合并留原文+静音锚点）"
```

---

## Task 3: `delete_article`（暂存 pending，不在 loop 内删）+ `deleteArticleFiles`

**Files:**
- Modify: `src/tools.js`
- Test: `test/command-tools.test.js`（追加）

**Interfaces:**
- Produces: `delete_article` 工具（`destructive:true`，返回 `{ ok:true, pending:{action:"delete", stem, title} }`，**不删任何东西**）；导出 `deleteArticleFiles(env, scope, stem)`（真正删除，供 DO confirm 调用）。

- [ ] **Step 1: 追加失败测试** —— `test/command-tools.test.js`

```js
import { deleteArticleFiles } from "../src/tools.js";

describe("delete_article 暂存 + deleteArticleFiles 执行", () => {
  it("delete_article 只暂存 pending，不删文件", async () => {
    const env = { FILES: memFiles({ [`${SCOPE}articles/A.json`]: art("A", "甲", "x"), [`${SCOPE}A.m4a`]: "BYTES" }) };
    const r = await runTool("delete_article", { stem: "A" }, { env, scope: SCOPE });
    expect(r).toEqual({ ok: true, pending: { action: "delete", stem: "A", title: "甲" } });
    expect(env.FILES._store.has(`${SCOPE}articles/A.json`)).toBe(true);  // 没删
  });
  it("deleteArticleFiles 删文章 JSON + m4a 锚点", async () => {
    const env = { FILES: memFiles({ [`${SCOPE}articles/A.json`]: art("A", "甲", "x"), [`${SCOPE}A.m4a`]: "BYTES" }) };
    await deleteArticleFiles(env, SCOPE, "A");
    expect(env.FILES._store.has(`${SCOPE}articles/A.json`)).toBe(false);
    expect(env.FILES._store.has(`${SCOPE}A.m4a`)).toBe(false);
  });
});
```

- [ ] **Step 2: 跑测试确认失败** — `npx vitest run test/command-tools.test.js` → FAIL

- [ ] **Step 3: 实现** —— `src/tools.js` 追加

```js
register(
  { name: "delete_article", destructive: true,
    description: "删除一篇文章（破坏性，需用户确认后才真正删）。stem 是要删的文章。",
    input_schema: { type: "object", properties: { stem: { type: "string" } }, required: ["stem"], additionalProperties: false } },
  async ({ stem }, { env, scope }) => {
    if (badStem(stem)) return { error: "bad_stem" };
    const obj = await env.FILES.get(`${scope}articles/${stem}.json`);
    let title = stem;
    if (obj) { try { title = resolveArticles(JSON.parse(await obj.text()))[0]?.title || stem; } catch {} }
    // 破坏性：只暂存，等 DO 收到 confirm 再删。
    return { ok: true, pending: { action: "delete", stem, title } };
  }
);

// 真正删除一篇文章：文章 JSON + 其 m4a 锚点 + 常见 marker。供 DO 的 confirm 执行。
export async function deleteArticleFiles(env, scope, stem) {
  const keys = [
    `${scope}articles/${stem}.json`,
    `${scope}${stem}.m4a`,
    `${scope}articles/${stem}.empty`,
    `${scope}articles/${stem}.asr.json`,
  ];
  for (const k of keys) { try { await env.FILES.delete(k); } catch {} }
}
```

- [ ] **Step 4: 跑测试确认通过** — `npx vitest run test/command-tools.test.js` → PASS

- [ ] **Step 5: Commit**

```bash
git add src/tools.js test/command-tools.test.js
git commit -m "feat(agent): delete_article 暂存 pending（不在 loop 内删）+ deleteArticleFiles 执行器"
```

---

## Task 4: 库级工具集 `COMMAND_TOOL_NAMES` + `toolDefsFor`

**Files:**
- Modify: `src/tools.js`
- Test: `test/command-tools.test.js`（追加）

**Interfaces:**
- Produces: `export const COMMAND_TOOL_NAMES = [...]`、`export const COMMAND_TERMINAL = new Set([...])`、`export function toolDefsFor(names)`（从 `TOOL_DEFS` 里挑子集）。

- [ ] **Step 1: 追加失败测试**

```js
import { toolDefsFor, COMMAND_TOOL_NAMES } from "../src/tools.js";
describe("命令工具子集", () => {
  it("toolDefsFor 只返回指定工具，且命令集不含单篇编辑工具", () => {
    const defs = toolDefsFor(COMMAND_TOOL_NAMES);
    const names = defs.map((d) => d.name);
    expect(names).toContain("merge_articles");
    expect(names).toContain("delete_article");
    expect(names).toContain("list_articles");
    expect(names).not.toContain("edit_current_article");   // 单篇编辑不进命令集
    expect(names).not.toContain("write_article");
  });
});
```

- [ ] **Step 2: 跑测试确认失败** → FAIL

- [ ] **Step 3: 实现** —— `src/tools.js` 追加（放在所有 `register` 之后）

```js
// 库级（命令）agent 能用的工具：多篇读、合并、删除、重写、归类、风格、发布/分享。
// 刻意不含 edit_current_article / write_article（那两个绑定单一 articleKey）。
export const COMMAND_TOOL_NAMES = [
  "list_articles", "read_article",
  "merge_articles", "delete_article", "restyle_article", "tag_article",
  "read_style", "write_style", "publish_wechat", "share_to_community",
];
export const COMMAND_TERMINAL = new Set([
  "merge_articles", "delete_article", "restyle_article", "tag_article",
  "write_style", "publish_wechat", "share_to_community",
]);
export function toolDefsFor(names) {
  const set = new Set(names);
  return TOOL_DEFS.filter((d) => set.has(d.name));
}
```

- [ ] **Step 4: 跑测试确认通过** → PASS
- [ ] **Step 5: Commit**

```bash
git add src/tools.js test/command-tools.test.js
git commit -m "feat(agent): COMMAND_TOOL_NAMES/toolDefsFor —— 库级 agent 的工具子集"
```

---

## Task 5: `runCommandTurn`（`src/command-turn.js`）+ 编号→stem 解析

**Files:**
- Create: `src/command-turn.js`
- Test: `test/command-turn.test.js`（新）

**Interfaces:**
- Consumes: `runAgentLoop`（Task 1）、`toolDefsFor`/`COMMAND_TOOL_NAMES`/`COMMAND_TERMINAL`（Task 4）、`readStyleText`。
- Produces: `runCommandTurn({ env, scope, token, origin, turnId, instruction, refs, callClaude })` → `{ ok, reply, pending, toolRuns, hadError }`。`refs` = `[{ n, stem, title }]`；把「第N篇」映射进 prompt。

- [ ] **Step 1: 写失败测试** —— `test/command-turn.test.js`

```js
import { describe, it, expect, vi } from "vitest";
import { runCommandTurn } from "../src/command-turn.js";

describe("runCommandTurn", () => {
  it("把 refs 编号清单喂进 prompt，并驱动命令工具集", async () => {
    let sawToolNames = null, sawUser = null;
    const callClaude = vi.fn(async ({ tools, messages }) => {
      sawToolNames = tools.map((t) => t.name);
      sawUser = JSON.stringify(messages);
      // 直接收尾（纯文本），不调工具
      return { content: [{ type: "text", text: "好的" }], usage: {} };
    });
    const env = { FILES: { async get() { return null; } } };
    const r = await runCommandTurn({
      env, scope: "users/x/", token: "tk", origin: "https://jianshuo.dev", turnId: "T1",
      instruction: "把③和④合并", refs: [
        { n: 1, stem: "S1", title: "一" }, { n: 2, stem: "S2", title: "二" },
        { n: 3, stem: "S3", title: "三" }, { n: 4, stem: "S4", title: "四" },
      ], callClaude,
    });
    expect(r.ok).toBe(true);
    expect(sawToolNames).toContain("merge_articles");
    expect(sawToolNames).not.toContain("edit_current_article");
    expect(sawUser).toContain("第3篇");   // 编号清单出现在 prompt
    expect(sawUser).toContain("S3");       // stem 映射可见
    expect(sawUser).toContain("把③和④合并");
  });

  it("透传工具 pending（破坏性删除待确认）", async () => {
    const callClaude = vi.fn(async () => ({ content: [
      { type: "text", text: "要删第②篇吗" },
      { type: "tool_use", id: "d1", name: "delete_article", input: { stem: "S2" } },
    ], usage: {} }));
    const env = { FILES: { async get(k) { return k.endsWith("S2.json") ? { async text() { return JSON.stringify({ articles: [{ title: "二", body: "x" }] }); } } : null; } } };
    const r = await runCommandTurn({
      env, scope: "users/x/", token: "tk", origin: "https://jianshuo.dev", turnId: "T2",
      instruction: "删掉第②篇", refs: [{ n: 2, stem: "S2", title: "二" }], callClaude,
    });
    expect(r.pending).toEqual([{ action: "delete", stem: "S2", title: "二" }]);
  });
});
```

- [ ] **Step 2: 跑测试确认失败** → FAIL（文件不存在）

- [ ] **Step 3: 实现** —— `src/command-turn.js`

```js
// 跑一条「库级语音指令」端到端：构造 prompt（用户文风作缓存前缀 + 编号清单 + 指令）、
// 驱动命令工具集的 agent loop、返回结果。破坏性动作以 pending 返回，由 DO 走确认。
import { runAgentLoop } from "./loop.js";
import { toolDefsFor, COMMAND_TOOL_NAMES, COMMAND_TERMINAL } from "./tools.js";
import { readStyleText } from "../../functions/lib/style-store.js";

const COMMAND_SYSTEM = [
  "你是 VoiceDrop 的语音指挥助手。用户在「我的录音」列表长按红键、对着编号说一句指令，",
  "你要理解意图并用工具执行。列表里每篇文章都有一个编号（第N篇）——用户说「第N篇/第③篇」时，",
  "严格按下面给出的『编号清单』把编号映射到对应的 stem，再调用工具。不确定指代时，用文字回问，别乱猜、别动数据。",
  "合并用 merge_articles（另存新篇、原文保留）；删除用 delete_article（会等用户确认）；",
  "换风格重写用 restyle_article；归类用 tag_article。只做用户要求的操作。",
].join("");

export async function runCommandTurn({ env, scope, token, origin, turnId, instruction, refs = [], callClaude }) {
  const style = (await readStyleText(env, `${scope}CLAUDE.json`).catch(() => "")) || "";
  const refLines = refs.map((r) => `第${r.n}篇 → stem=${r.stem}｜标题：${r.title}`).join("\n") || "（列表为空）";
  const systemBlocks = [
    { type: "text", text: COMMAND_SYSTEM, cache_control: { type: "ephemeral" } },
    { type: "text", text: `用户的写作风格（合并/重写时保持）：\n${style || "（未设置）"}`, cache_control: { type: "ephemeral" } },
  ];
  const userContent = [
    "编号清单（用户此刻在屏幕上看到的顺序，第N篇 ↔ stem）：",
    refLines,
    "",
    "这次的语音指令：",
    instruction,
  ].join("\n");

  // ctx 带 callClaude —— merge_articles 需要内部再调一次 Claude 做揉合成。
  const ctx = { env, scope, token, origin, turnId, callClaude, refs };
  const result = await runAgentLoop({
    callClaude, ctx, system: systemBlocks, userContent,
    tools: toolDefsFor(COMMAND_TOOL_NAMES), terminalTools: COMMAND_TERMINAL,
  });

  const summary = (result.finalText || "").trim();
  const didAct = (result.calledTools || []).some((n) => COMMAND_TERMINAL.has(n));
  const reply = summary || (result.hadError ? "操作没完成" : (didAct ? "好了" : ""));
  return { ok: !result.hadError, reply, pending: result.pending || [], toolRuns: result.toolRuns || [], hadError: !!result.hadError };
}
```

- [ ] **Step 4: 跑测试确认通过** — `npx vitest run test/command-turn.test.js` → PASS
- [ ] **Step 5: Commit**

```bash
git add src/command-turn.js test/command-turn.test.js
git commit -m "feat(agent): runCommandTurn —— 库级语音指令 turn（编号→stem + 命令工具集 + pending）"
```

---

## Task 6: `meteredCommandGate`（余额门，无每篇上限）

**Files:**
- Modify: `src/index.js`
- Test: `test/usage-command.test.js`（新）

**Interfaces:**
- Consumes: `ensureAccount`（`usage_store.js`）、`editGate`（`usage.js`，余额部分）。
- Produces: `export async function meteredCommandGate(db, scope, now)` → `"ok" | "no-credit"`。

- [ ] **Step 1: 写失败测试** —— `test/usage-command.test.js`

```js
import { describe, it, expect } from "vitest";
import { meteredCommandGate } from "../src/index.js";

describe("meteredCommandGate", () => {
  it("无 USAGE 绑定 → fail-open ok", async () => {
    expect(await meteredCommandGate(undefined, "users/x/", Date.now())).toBe("ok");
  });
});
```
> 余额不足分支在集成层覆盖（需 D1 fake）；此处先锁 fail-open 契约。

- [ ] **Step 2: 跑测试确认失败** → FAIL（未导出）
- [ ] **Step 3: 实现** —— `src/index.js`（`meteredEditGate` 旁边）

```js
// 库级指令门：只看余额，不设每文章上限（指令是库级、不按篇计）。fail-open。
export async function meteredCommandGate(db, scope, now) {
  if (!db) return "ok";
  try {
    const bal = await ensureAccount(db, scope, now);
    return bal > 0 ? "ok" : "no-credit";
  } catch { return "ok"; }
}
```

- [ ] **Step 4: 跑测试确认通过** → PASS
- [ ] **Step 5: Commit**

```bash
git add src/index.js test/usage-command.test.js
git commit -m "feat(agent): meteredCommandGate —— 库级指令余额门（无每篇上限）"
```

---

## Task 7: `LibraryAgent` DO（clone `ArticleEditor`）+ confirm/cancel + wrangler 绑定

**Files:**
- Modify: `src/index.js`（新增 `LibraryAgent` class）、`wrangler.jsonc`
- Test: 复用 `test/command-turn.test.js` 逻辑；DO 装配靠 Task 9 冒烟验证。

**Interfaces:**
- Consumes: `runCommandTurn`（Task 5）、`meteredCommandGate`（Task 6）、`deleteArticleFiles`（Task 3）、`ArticleQueue`/`makeSqlStore`（`src/queue.js`）、`resolveEditModel`/`loadModelConfig`。
- Produces: DO class `LibraryAgent`，`onConnect` 存 `scope`/`token`；`onMessage` 处理 `instruct` / `confirm` / `cancel`；`runTurn(row)` → `runCommandTurn`；pending 破坏性动作存 config 表，confirm 时 `deleteArticleFiles` 执行。

- [ ] **Step 1: 实现 DO** —— 在 `src/index.js` 里 clone `ArticleEditor`（`:100-305`）为 `LibraryAgent`，改动点如下（其余逐行照抄）：

`onStart`：三张表（config/history/queue）照抄。

`onConnect`：只存 `scope`/`token`（**无 articleKey**）：
```js
onConnect(connection, ctx) {
  const scope = ctx.request.headers.get("x-vd-scope");
  const token = (ctx.request.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  const set = (k, v) => { if (v) this.sql`INSERT INTO config (k, v) VALUES (${k}, ${v}) ON CONFLICT(k) DO UPDATE SET v = excluded.v`; };
  set("scope", scope); set("token", token);
  // 库级无单一 doc，snapshot 只回队列状态。
  try { connection.send(JSON.stringify({ type: "snapshot", queue: this._queue.snapshot() })); } catch (_) {}
}
```

`get _queue`：`loadDoc: async () => null`（库级没有单一 doc），其余（store/broadcast/schedule/runTurn）照抄。

`runTurn(row)`：
```js
async runTurn(row) {
  const { scope, token } = this._config();
  if (!scope) return { ok: false, error: "会话未初始化" };
  const decision = await meteredCommandGate(this.env.USAGE, scope, Date.now());
  if (decision === "no-credit") return { ok: false, error: "算力不足" };

  const turnId = `${Date.now()}-${rand6()}`;
  const model = resolveEditModel(await loadModelConfig(this.env));
  const callClaude = this._makeLoggedCall({ turnId, scope, stem: "", instruction: row.text, model });
  const refs = row.images ? (() => { try { return JSON.parse(row.images); } catch { return []; } })() : [];  // 复用 images 列存 refs（见下）
  const res = await runCommandTurn({
    env: this.env, scope, token, origin: "https://jianshuo.dev", turnId,
    instruction: row.text, refs, callClaude,
  });
  // 破坏性 pending → 存起来、发 confirm，不落地。
  if (res.pending && res.pending.length) {
    this.sql`INSERT INTO config (k, v) VALUES (${"pending:" + row.id}, ${JSON.stringify(res.pending)}) ON CONFLICT(k) DO UPDATE SET v = excluded.v`;
    const p = res.pending[0];
    this.broadcast(JSON.stringify({ type: "confirm", id: row.id, summary: `要删掉《${p.title}》吗？`, action: p }));
    return { ok: true, reply: res.reply, article: null, _pending: true };
  }
  this.sql`INSERT INTO history (instruction, reply, created_at) VALUES (${row.text}, ${res.reply || "（已处理）"}, ${Date.now()})`;
  return { ok: res.ok, reply: res.reply, error: res.hadError ? (res.reply || "操作没完成") : undefined, article: null };
}
```
> `refs` 走 queue 的 `images` 列（`ArticleQueue.submit({images})` 已有）——把客户端发来的 `refs` 数组 JSON 存进 `images`，`runTurn` 读回。避免动 queue schema。

`onMessage`：在 `instruct` 分支把 `refs` 存进 `images` 列：
```js
async onMessage(connection, message) {
  let msg; try { msg = JSON.parse(typeof message === "string" ? message : ""); } catch { return; }
  if (!msg) return;
  if (msg.type === "confirm") return this._resolvePending(connection, msg.id, true);
  if (msg.type === "cancel")  return this._resolvePending(connection, msg.id, false);
  if (msg.type !== "instruct") return;
  const instruction = String(msg.text || "").trim();
  if (!instruction) { connection.send(JSON.stringify({ type: "error", message: "空指令" })); return; }
  const id = (typeof msg.id === "string" && msg.id) ? msg.id : `srv-${Date.now()}-${rand6()}`;
  const refs = Array.isArray(msg.refs) ? msg.refs.filter((r) => r && r.stem) : [];
  const r = await this._queue.submit({ id, text: instruction, images: refs, article_index: 0 });
  if (r.kind === "replay") {
    const row = r.row;
    if (row.status === "done") { if (row.reply) connection.send(JSON.stringify({ type: "reply", id, text: row.reply, ok: true })); }
    else if (row.status === "error") connection.send(JSON.stringify({ type: "error", id, message: row.error || "操作没完成" }));
    else connection.send(JSON.stringify({ type: "status", state: "working", id }));
    return;
  }
  connection.send(JSON.stringify({ type: "status", state: "working", id }));
  this.schedule(0, "drainQueue");
}

// 确认/取消一个暂存的破坏性动作。
async _resolvePending(connection, id, ok) {
  const { scope } = this._config();
  const rows = this.sql`SELECT v FROM config WHERE k = ${"pending:" + id}`;
  const raw = rows[0]?.v; if (!raw) return;
  this.sql`DELETE FROM config WHERE k = ${"pending:" + id}`;
  if (!ok) { connection.send(JSON.stringify({ type: "reply", id, text: "已取消", ok: true })); return; }
  let actions = []; try { actions = JSON.parse(raw); } catch {}
  for (const a of actions) { if (a.action === "delete") await deleteArticleFiles(this.env, scope, a.stem); }
  this.sql`INSERT INTO history (instruction, reply, created_at) VALUES (${"（确认删除）"}, ${"已删除"}, ${Date.now()})`;
  connection.send(JSON.stringify({ type: "reply", id, text: "已删除", ok: true }));
  this.broadcast(JSON.stringify({ type: "updated", id, article: null }));   // 客户端据此刷新列表
}
```
`_callClaudeRaw` / `_makeLoggedCall` / `drainQueue` / `_config`：照抄 `ArticleEditor`。顶部 import 补：`import { runCommandTurn } from "./command-turn.js";`、`import { deleteArticleFiles } from "./tools.js";`、`meteredCommandGate` 同文件。

- [ ] **Step 2: wrangler.jsonc 绑定 + migration** —— `wrangler.jsonc`

```jsonc
// durable_objects.bindings 追加：
{ "name": "LibraryAgent", "class_name": "LibraryAgent" }
// migrations 追加：
{ "tag": "v5", "new_sqlite_classes": ["LibraryAgent"] }
```

- [ ] **Step 3: 全量回归** — `npm test` → 全绿（新 DO 不影响现有用例）。

- [ ] **Step 4: Commit**

```bash
git add src/index.js wrangler.jsonc
git commit -m "feat(agent): LibraryAgent DO（每用户一个，复用 ArticleQueue）+ confirm/cancel 破坏性动作 + wrangler v5"
```

---

## Task 8: `/agent/command` WS 路由

**Files:**
- Modify: `src/index.js`
- Test: Task 9 冒烟

**Interfaces:**
- Consumes: `resolveScope`、`sanitizeName`、`getAgentByName`、`env.LibraryAgent`。

- [ ] **Step 1: 实现** —— `src/index.js`（`/agent/edit` 路由旁边）

```js
// ── /agent/command ── 库级语音指令 agent（每用户一个 DO，无 stem）───────────
if (url.pathname === "/agent/command") {
  if (request.headers.get("Upgrade") !== "websocket") return new Response("expected websocket", { status: 426 });
  const token = (request.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
  const scope = await resolveScope(token, env);
  if (!scope) return new Response("unauthorized", { status: 401 });
  const agent = await getAgentByName(env.LibraryAgent, sanitizeName(scope + ":command"));
  const fwd = new Request(request);
  fwd.headers.set("x-vd-scope", scope);
  return agent.fetch(fwd);
}
```

- [ ] **Step 2: 全量回归** — `npm test` → 全绿
- [ ] **Step 3: Commit**

```bash
git add src/index.js
git commit -m "feat(agent): /agent/command WS 路由 → LibraryAgent（每用户一个 DO）"
```

---

## Task 9: 部署 + 冒烟

- [ ] **Step 1: 全量测试** — `cd ~/code/jianshuo.dev/agent && npm test` → 全绿。
- [ ] **Step 2: 部署 Worker** — `npx wrangler deploy`（注意 migration v5 会创建 `LibraryAgent`）。Expected: `Deployed voicedrop-agent`，输出 version id。
- [ ] **Step 3: 冒烟**（用 `wjs-voicedrop` skill 的 token 或已登录 token）：建一个 WS 到 `wss://voicedrop-agent.jianshuo.workers.dev/agent/command`（带 `Authorization: Bearer <token>`），发 `{type:"instruct", id:"smoke1", text:"把第1篇和第2篇合并", refs:[{n:1,stem:"<真stem1>",title:"..."},{n:2,stem:"<真stem2>",title:"..."}]}`，期望收到 `status:working` → 稍后 `reply`；到 `jianshuo.dev/files` 看到一条 `VoiceDrop-merged-*` 新文章、原两篇还在。
- [ ] **Step 4: Commit**（如冒烟需要微调）。

---

# Phase 2 — iOS（`~/code/voicedrop`）

## File Structure（Phase 2）

- `VoiceDropApp/VoiceAgentSession.swift`（新）— `VoiceAgentSession` 协议。
- `VoiceDropApp/AgentSession.swift`（改）— `ArticleAgentSession` conform 协议（行为不变）。
- `VoiceDropApp/PushToTalkBar.swift`（新）— 从 `RecordingDetailView` 抽出的按住说话 bar。
- `VoiceDropApp/RecordingDetailView.swift`（改）— 改用 `PushToTalkBar`。
- `VoiceDropApp/LibraryCommandSession.swift`（新）— 库级会话（连 `/agent/command`）。
- `VoiceDropApp/CommandQueueStore.swift`（新）— scope 级队列持久化。
- `VoiceDropApp/LibraryView.swift`（改）— 红键长按、序号 overlay、reply + confirm UI。
- 新增文件后 `xcodegen generate`。

---

## Task 10: `VoiceAgentSession` 协议 + `ArticleAgentSession` conform

**Files:**
- Create: `VoiceDropApp/VoiceAgentSession.swift`
- Modify: `VoiceDropApp/AgentSession.swift`

**Interfaces:**
- Produces: 协议
```swift
@MainActor protocol VoiceAgentSession: AnyObject {
    var state: AgentState { get }
    var queue: [ArticleAgentSession.EditRequest] { get }   // 复用现有 EditRequest 形状
    var onReply: ((String, Bool) -> Void)? { get set }
    var onUpdate: ((ArticleDoc?) -> Void)? { get set }     // 库级可能 nil doc（列表刷新）
    func enqueue(_ instruction: String, images: [AgentImage], articleIndex: Int)
    func disconnect()
}
```

- [ ] **Step 1: 建协议文件** —— `VoiceDropApp/VoiceAgentSession.swift`（内容如上 Interfaces）。
  > `onUpdate` 从 `((ArticleDoc)->Void)` 放宽为 `((ArticleDoc?)->Void)`：库级删除/刷新时传 `nil`。同步改 `ArticleAgentSession.onUpdate` 与 `RecordingDetailView` 里的 `agent.onUpdate = { doc in ... }`（`doc` 变 optional，解包后再用）。
- [ ] **Step 2: 让 `ArticleAgentSession` conform** —— `AgentSession.swift` 声明 `: VoiceAgentSession`；`onUpdate` 类型改 optional 版；`handle` 的 `"updated"` 分支解包。
- [ ] **Step 3: xcodegen + build**

```bash
cd ~/code/voicedrop && xcodegen generate
xcodebuild -project VoiceDrop.xcodeproj -scheme VoiceDrop -destination 'generic/platform=iOS' -configuration Debug build CODE_SIGNING_ALLOWED=NO 2>&1 | grep -E "BUILD SUCCEEDED|BUILD FAILED|error:"
```
Expected: BUILD SUCCEEDED。

- [ ] **Step 4: 手动回归** — 跑 app，进一篇文章详情，按住说话改一句，确认编辑流不变。
- [ ] **Step 5: Commit**

```bash
git add VoiceDropApp/VoiceAgentSession.swift VoiceDropApp/AgentSession.swift VoiceDropApp/RecordingDetailView.swift VoiceDrop.xcodeproj
git commit -m "refactor(ios): 抽 VoiceAgentSession 协议，ArticleAgentSession conform（编辑流不变）"
```

---

## Task 11: 抽 `PushToTalkBar`（RecordingDetailView 改用）

**Files:**
- Create: `VoiceDropApp/PushToTalkBar.swift`
- Modify: `VoiceDropApp/RecordingDetailView.swift`

**Interfaces:**
- Produces:
```swift
struct PushToTalkBar: View {
    let dictation: SpeechDictation
    let session: any VoiceAgentSession
    var highlightLocators: Bool = false        // 第N行/图N 染色，仅文章编辑开
    var articleIndex: () -> Int = { 0 }         // 文章编辑传当前篇；库级传 0
    var onWillSend: (() -> Void)? = nil
    // 内部持有 willCancel 状态；holdGesture / pill / darkBubble / queueRow / replyBubble 全搬进来
}
```

- [ ] **Step 1: 搬运** —— 把 `RecordingDetailView.swift:735-882` 的 `voiceBar/queueRow/pill/replyBubble/darkBubble/highlightedTranscript/holdGesture` 整体搬进 `PushToTalkBar.swift`，参数化两处文章耦合：
  - `highlightedTranscript`：`highlightLocators == false` 时直接返回原文（不染色）。
  - `holdGesture` 的 `onEnded`：`session.enqueue(text, images: [], articleIndex: articleIndex())`。
- [ ] **Step 2: RecordingDetailView 改用** —— 底部换成 `PushToTalkBar(dictation: dictation, session: agent, highlightLocators: true, articleIndex: { articleIndex })`。
- [ ] **Step 3: xcodegen + build** → BUILD SUCCEEDED
- [ ] **Step 4: 手动回归** — 文章详情按住说话改一句，行为与之前一致（含上滑取消、排队、reply 气泡）。
- [ ] **Step 5: Commit**

```bash
git add VoiceDropApp/PushToTalkBar.swift VoiceDropApp/RecordingDetailView.swift VoiceDrop.xcodeproj
git commit -m "refactor(ios): 抽出 PushToTalkBar（RecordingDetailView 改用，回归通过）"
```

---

## Task 12: `LibraryCommandSession` + `CommandQueueStore`

**Files:**
- Create: `VoiceDropApp/LibraryCommandSession.swift`、`VoiceDropApp/CommandQueueStore.swift`

**Interfaces:**
- Produces: `LibraryCommandSession: VoiceAgentSession`（`@MainActor @Observable`），连 `API.agentWS + "/command"`（**无 stem**）；`enqueue` 发 `{type:"instruct", id, text, refs}`（`refs` 由调用方通过一个 `setRefs([Ref])` 先塞进去，或 `enqueue(_,refs:)` 重载）；处理 `status/reply/error/updated/confirm/snapshot`；`onConfirm: ((id, summary) -> Void)?` 暴露给 UI 弹确认卡；`confirm(id)` / `cancel(id)` 发回。队列持久化用 `CommandQueueStore`（key `commandQueue.<scope>`）。

- [ ] **Step 1: 建 `CommandQueueStore`** —— 仿 `EditQueueStore.swift`，key 改 `"commandQueue.\(scopeKey)"`，`PersistedEdit` 去掉 `articleIndex`、加 `refsJSON: String?`。
- [ ] **Step 2: 建 `LibraryCommandSession`** —— 仿 `ArticleAgentSession`，删掉 `stem`/`Recording` 依赖：`openSocket()` 只需 token，URL = `\(API.agentWS)/command`；`send` 发 `{type,id,text,refs}`；`handle` 增加 `"confirm"` → `onConfirm?(id, summary)`；新增 `confirm(id)`/`cancel(id)` 发 `{type:"confirm"/"cancel", id}`。conform `VoiceAgentSession`。
- [ ] **Step 3: xcodegen + build** → BUILD SUCCEEDED
- [ ] **Step 4: Commit**

```bash
git add VoiceDropApp/LibraryCommandSession.swift VoiceDropApp/CommandQueueStore.swift VoiceDrop.xcodeproj
git commit -m "feat(ios): LibraryCommandSession（连 /agent/command，无 stem）+ scope 级队列"
```

---

## Task 13: `LibraryView` 接线（长按红键 + 序号 overlay + reply/confirm UI）

**Files:**
- Modify: `VoiceDropApp/LibraryView.swift`

**Interfaces:**
- Consumes: `PushToTalkBar`/`SpeechDictation`/`LibraryCommandSession`。
- Produces: 红键 `recordButton`（`:368-384`）加长按手势进入命令态；`rowCard`（`:209` 附近）命令态显示圈序号；顶部 reply 气泡 + 破坏性确认 `.alert`。

- [ ] **Step 1: 状态** —— `@State private var commandMode = false`、`@State private var dictation = SpeechDictation()`、`@State private var command = LibraryCommandSession()`、`@State private var confirm: (id: String, summary: String)? = nil`。`.task` 里 `command.onReply/onUpdate/onConfirm` 挂上；`onUpdate = { _ in Task { await refresh() } }`；`await dictation.requestAuth()`。
- [ ] **Step 2: 红键长按** —— `recordButton` 的红圈加 `.simultaneousGesture(LongPressGesture(minimumDuration: 0.3).onEnded { _ in commandMode = true; dictation.start(); haptic() })`；轻点仍 `showRecord = true`。命令态时列表上方浮 `PushToTalkBar(dictation: dictation, session: command)`（复用同一套气泡）；松手在 `PushToTalkBar` 内 `enqueue`，但库级要带 `refs` —— 用 `onWillSend` 先 `command.setRefs(currentRefs())`，`currentRefs()` = 当前 `articlesForList` 的绝对位置 `[{n,stem,title}]`。
- [ ] **Step 3: 序号 overlay** —— `rowCard(rec)` 在 `commandMode` 时左侧叠一个圈号（`Text("\(index+1)")` in a `Circle`），`index` = 该 rec 在列表中的绝对位置。
- [ ] **Step 4: reply + confirm** —— 顶部叠 `command` 的最近 reply（复用 `replyBubble` 风格）；`command.onConfirm = { id, summary in confirm = (id, summary) }`；`.alert(confirm?.summary ?? "", isPresented: ...) { Button("删除", role: .destructive) { command.confirm(id) }; Button("取消", role: .cancel) { command.cancel(id) } }`。
- [ ] **Step 5: xcodegen + build** → BUILD SUCCEEDED
- [ ] **Step 6: Commit**

```bash
git add VoiceDropApp/LibraryView.swift VoiceDrop.xcodeproj
git commit -m "feat(ios): 我的录音长按红键→语音指令（序号 overlay + 复用 PushToTalkBar + 破坏性确认）"
```

---

## Task 14: 真机验证（TestFlight）

- [ ] **Step 1: push 触发 CI** — `git push origin main`（走现有 fastlane→TestFlight）。
- [ ] **Step 2: 盯 CI** — `gh run watch <id> --exit-status`；成功→新 build 上 TestFlight。
- [ ] **Step 3: 真机走查**：
  - 长按红键 → 列表出序号 + 底部聆听气泡 + 实时转写。
  - 说「把第1篇和第2篇合并」→ 松手 → reply「好了」→ 列表顶部出现合并新篇、原两篇还在。
  - 说「删掉第2篇」→ 弹确认卡 → 确认 → 该篇消失。
  - 说一句听不清的 → reply「没听清…」，数据不动。
- [ ] **Step 4: 更新 STATE.md** — 记语音指令功能（架构 + 两套 agent 并存 + 待统一）。Commit。

---

## Self-Review（plan vs spec）

- **Spec 覆盖**：交互（Task 13）、开放式 agent（Task 5 工具集）、对讲机手势（Task 11/13 复用 holdGesture）、分级确认（Task 3 pending + Task 7 confirm/cancel）、合并=揉+留原文+静音锚点（Task 2）、复用语音编辑栈（Task 10/11 抽共享件 + 复用 `/agent/asr`/`SpeechDictation`）、编号→stem（Task 5 refs）、计费（Task 6）、列表锚点（Task 2 `writeStandaloneArticle`）、错误处理（空转写/指代不明由 agent 回 reply）、测试（Task 1–6 vitest）。全部有对应任务。
- **占位扫描**：无 TBD/TODO；DO/route 用"clone + 具体改动代码块"而非"similar to"。
- **类型一致**：`runCommandTurn({...,refs,callClaude})`、`refs=[{n,stem,title}]`、`pending={action,stem,title}`、`COMMAND_TOOL_NAMES`/`COMMAND_TERMINAL`/`toolDefsFor`、`deleteArticleFiles(env,scope,stem)`、`meteredCommandGate(db,scope,now)`、`VoiceAgentSession`/`PushToTalkBar`/`LibraryCommandSession` 各处签名一致。
- **已知需实现时确认**：`restyleArticle` 返回形状（Task 2 注）、`readStyleText` 导出名（若不同改为 `readStyleDoc` 取文本）、`makeSqlStore`/`QUEUE_TABLE_SQL`/`rand6`/`buildHistoryMessages`/`resolveEditModel` 均在 `src/index.js`/`src/queue.js` 现有，clone 时照用。
