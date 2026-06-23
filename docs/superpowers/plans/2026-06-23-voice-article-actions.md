# Voice-driven Article Actions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a spoken instruction in the article editor do anything the user could do by hand — rewrite, combine articles, publish to WeChat, share to community, or adjust writing style — by giving the Worker agent a small set of general primitive tools it composes in a multi-step tool-use loop.

**Architecture:** The `ArticleEditor` Durable Object (Cloudflare Worker, `~/code/jianshuo.dev/agent`) stops doing a single rewrite call. Each `instruct` message drives an agentic loop: Claude is called with 7 primitive tools, the Worker executes each tool call server-side and feeds the result back, until Claude stops calling tools. R2 tools read/write the user's articles and style file; distribution tools `fetch` the existing Pages endpoints. Tool logic lives in testable pure modules (`src/tools.js`, `src/loop.js`); the DO is thin glue. The app is unchanged — the loop always ends by pushing `{type:"updated", article}`, which the app already handles.

**Tech Stack:** Cloudflare Workers + Durable Objects (`agents` SDK), R2, Anthropic Messages API (tool use), vitest (new, plain node — no workers pool).

## Global Constraints

- Worker project root: `~/code/jianshuo.dev/agent`. Source is ESM (`"type":"module"`).
- Model: `claude-sonnet-4-6` (keep the existing `MODEL` constant).
- R2 binding: `env.FILES`. User scope: `users/<sub>/` (the DO already has `articleKey` and `scope` in its `config` table).
- Distribution endpoints are scope-relative: call `https://jianshuo.dev/files/api/wechat/<rel>` and `.../community/share/<rel>` where `rel = articleKey.slice(scope.length)` = `articles/<stem>.json`. The server's `keyFor` re-prepends scope. Send `Authorization: Bearer <user token>`.
- Voice DNA: keep `REVISE_SYSTEM` content (the owner-voice rules) as the base of the system prompt.
- `write_article` writes the CURRENT article only (the DO's own `articleKey`); it takes no `stem`. `read_article` may read any of the user's stems.
- Style file key: `scope + "CLAUDE.md"`.
- Article doc schema (v2): `{schema,id,sourceAudio,createdAt,transcript,srt,articles:[{title,body,wechatMediaId?}],status,model}`. Presence of `articles/<stem>.json` = 已成文; `articles/<stem>.empty` = 无语音 (skip in listings).
- Commit after every task. Do NOT deploy until Task 6's verification step.

---

### Task 1: Test harness + fakes + tools dispatcher scaffold

**Files:**
- Modify: `~/code/jianshuo.dev/agent/package.json`
- Create: `~/code/jianshuo.dev/agent/test/fakes.js`
- Create: `~/code/jianshuo.dev/agent/src/tools.js`
- Test: `~/code/jianshuo.dev/agent/test/tools.test.js`

**Interfaces:**
- Produces: `runTool(name, args, ctx) -> Promise<object>` where `ctx = {env, scope, articleKey, token, origin}`. Returns a JSON-serializable result. Unknown tool → `{error:"unknown_tool"}`.
- Produces: `TOOL_DEFS` — array of Anthropic tool definitions (filled in across Tasks 2–4).
- Produces fakes: `fakeEnv(seed)` → `{FILES}` R2 mock; `fakeFetch(routes)` → fetch stub.

- [ ] **Step 1: Add vitest and a test script**

Edit `package.json` — add to `devDependencies` and `scripts`:

```json
{
  "name": "voicedrop-agent",
  "version": "1.0.0",
  "private": true,
  "type": "module",
  "scripts": {
    "deploy": "wrangler deploy",
    "dev": "wrangler dev",
    "test": "vitest run"
  },
  "dependencies": {
    "agents": "latest"
  },
  "devDependencies": {
    "wrangler": "^4",
    "vitest": "^2"
  }
}
```

Then run: `cd ~/code/jianshuo.dev/agent && npm install`

- [ ] **Step 2: Write the R2 + fetch fakes**

Create `test/fakes.js`:

```js
// A Map-backed R2 bucket mock — only the methods our tools use.
export function fakeEnv(seed = {}) {
  const store = new Map(Object.entries(seed)); // key -> string value
  const FILES = {
    async get(key) {
      if (!store.has(key)) return null;
      const v = store.get(key);
      return { text: async () => v };
    },
    async put(key, value) { store.set(key, typeof value === "string" ? value : String(value)); },
    async head(key) { return store.has(key) ? {} : null; },
    async delete(key) { store.delete(key); },
    async list({ prefix = "", limit = 1000 } = {}) {
      const objects = [...store.keys()]
        .filter((k) => k.startsWith(prefix))
        .slice(0, limit)
        .map((k) => ({ key: k, size: store.get(k).length, uploaded: new Date(0) }));
      return { objects };
    },
    _store: store,
  };
  return { FILES };
}

// Route table: { "POST https://host/path": (req) => ({ ok, status, body }) }
export function fakeFetch(routes) {
  const calls = [];
  const fn = async (url, init = {}) => {
    const method = (init.method || "GET").toUpperCase();
    calls.push({ url: String(url), method, headers: init.headers || {}, body: init.body });
    const handler = routes[`${method} ${url}`] || routes[String(url)];
    const r = handler ? handler({ url, init }) : { ok: false, status: 404, body: { error: "no route" } };
    return { ok: r.ok ?? true, status: r.status ?? 200, json: async () => r.body, text: async () => JSON.stringify(r.body) };
  };
  fn.calls = calls;
  return fn;
}
```

- [ ] **Step 3: Write the failing dispatcher test**

Create `test/tools.test.js`:

```js
import { describe, it, expect } from "vitest";
import { runTool, TOOL_DEFS } from "../src/tools.js";
import { fakeEnv } from "./fakes.js";

describe("runTool dispatcher", () => {
  it("returns unknown_tool for an unrecognized name", async () => {
    const ctx = { env: fakeEnv(), scope: "users/u/", articleKey: "users/u/articles/s.json", token: "t", origin: "https://jianshuo.dev" };
    expect(await runTool("nope", {}, ctx)).toEqual({ error: "unknown_tool" });
  });

  it("exposes a tool definition array", () => {
    expect(Array.isArray(TOOL_DEFS)).toBe(true);
  });
});
```

- [ ] **Step 4: Run test to verify it fails**

Run: `cd ~/code/jianshuo.dev/agent && npm test`
Expected: FAIL — `Cannot find module '../src/tools.js'`.

- [ ] **Step 5: Create the tools scaffold**

Create `src/tools.js`:

```js
// VoiceDrop agent tools — general primitives the article-editing agent composes.
// Each handler takes (args, ctx) where ctx = {env, scope, articleKey, token, origin}.

export const TOOL_DEFS = []; // populated in Tasks 2–4

const HANDLERS = {}; // name -> async (args, ctx) => result  (populated below)

export async function runTool(name, args, ctx) {
  const h = HANDLERS[name];
  if (!h) return { error: "unknown_tool" };
  try {
    return await h(args || {}, ctx);
  } catch (e) {
    return { error: String((e && e.message) || e) };
  }
}

// Internal: register a tool definition + handler together.
export function register(def, handler) {
  TOOL_DEFS.push(def);
  HANDLERS[def.name] = handler;
}
```

- [ ] **Step 6: Run test to verify it passes**

Run: `cd ~/code/jianshuo.dev/agent && npm test`
Expected: PASS (2 tests).

- [ ] **Step 7: Commit**

```bash
cd ~/code/jianshuo.dev/agent && git add package.json package-lock.json test/fakes.js src/tools.js test/tools.test.js
git commit -m "test: add vitest harness, R2/fetch fakes, tools dispatcher scaffold"
```

---

### Task 2: R2 content tools — list / read / write article

**Files:**
- Modify: `~/code/jianshuo.dev/agent/src/tools.js`
- Test: `~/code/jianshuo.dev/agent/test/tools.test.js`

**Interfaces:**
- Consumes: `register(def, handler)`, `ctx` from Task 1.
- Produces tools:
  - `list_articles` (no input) → `{articles:[{stem,title,createdAt}]}`, newest-first, skips `.empty`/`.srt`, cap 30.
  - `read_article` (`{stem}`) → `{transcript, articles:[{title,body}]}` or `{error}`.
  - `write_article` (`{articles:[{title,body}]}`) → `{ok:true, count}`; writes CURRENT `articleKey` only, preserving `wechatMediaId` by index.

- [ ] **Step 1: Write the failing tests**

Append to `test/tools.test.js`:

```js
import { runTool as rt } from "../src/tools.js";

const CTX = (env) => ({ env, scope: "users/u/", articleKey: "users/u/articles/s2.json", token: "t", origin: "https://jianshuo.dev" });

function seedTwoArticles() {
  return {
    "users/u/articles/s1.json": JSON.stringify({ schema: 2, createdAt: 1000, transcript: "tx1", articles: [{ title: "A1", body: "b1" }] }),
    "users/u/articles/s2.json": JSON.stringify({ schema: 2, createdAt: 2000, transcript: "tx2", articles: [{ title: "A2", body: "b2", wechatMediaId: "m2" }] }),
    "users/u/articles/s3.empty": JSON.stringify({ status: "empty" }),
    "users/u/articles/s2.srt": "1\n00:00",
  };
}

describe("list_articles", () => {
  it("lists json articles newest-first and skips .empty/.srt", async () => {
    const env = fakeEnv(seedTwoArticles());
    const r = await rt("list_articles", {}, CTX(env));
    expect(r.articles.map((a) => a.stem)).toEqual(["s2", "s1"]);
    expect(r.articles[0]).toMatchObject({ stem: "s2", title: "A2", createdAt: 2000 });
  });
});

describe("read_article", () => {
  it("returns transcript and articles for a stem", async () => {
    const env = fakeEnv(seedTwoArticles());
    const r = await rt("read_article", { stem: "s1" }, CTX(env));
    expect(r).toEqual({ transcript: "tx1", articles: [{ title: "A1", body: "b1" }] });
  });
  it("rejects a stem that escapes scope", async () => {
    const env = fakeEnv(seedTwoArticles());
    expect(await rt("read_article", { stem: "../x" }, CTX(env))).toEqual({ error: "bad_stem" });
  });
  it("404s a missing stem", async () => {
    const env = fakeEnv(seedTwoArticles());
    expect(await rt("read_article", { stem: "nope" }, CTX(env))).toEqual({ error: "not_found" });
  });
});

describe("write_article", () => {
  it("overwrites the CURRENT article and preserves wechatMediaId by index", async () => {
    const env = fakeEnv(seedTwoArticles());
    const r = await rt("write_article", { articles: [{ title: "A2x", body: "b2x" }] }, CTX(env));
    expect(r).toEqual({ ok: true, count: 1 });
    const doc = JSON.parse(env.FILES._store.get("users/u/articles/s2.json"));
    expect(doc.articles[0]).toEqual({ title: "A2x", body: "b2x", wechatMediaId: "m2" });
    expect(doc.transcript).toBe("tx2"); // untouched
  });
  it("rejects empty articles", async () => {
    const env = fakeEnv(seedTwoArticles());
    expect(await rt("write_article", { articles: [] }, CTX(env))).toEqual({ error: "empty_articles" });
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ~/code/jianshuo.dev/agent && npm test`
Expected: FAIL — `list_articles` etc. return `{error:"unknown_tool"}`.

- [ ] **Step 3: Implement the three tools**

Append to `src/tools.js`:

```js
function badStem(stem) {
  return !stem || typeof stem !== "string" || stem.includes("/") || stem.includes("..");
}

register(
  { name: "list_articles", description: "列出当前用户的全部已成文文章（最新在前）。用来挑选要合并/参考的文章。", input_schema: { type: "object", properties: {}, additionalProperties: false } },
  async (_args, { env, scope }) => {
    const prefix = scope + "articles/";
    const listed = await env.FILES.list({ prefix, limit: 1000 });
    const stems = listed.objects
      .map((o) => o.key)
      .filter((k) => k.endsWith(".json"))
      .map((k) => k.slice(prefix.length, -".json".length));
    const out = [];
    for (const stem of stems) {
      const obj = await env.FILES.get(prefix + stem + ".json");
      if (!obj) continue;
      let doc; try { doc = JSON.parse(await obj.text()); } catch { continue; }
      const title = (doc.articles && doc.articles[0] && doc.articles[0].title) || "(无题)";
      out.push({ stem, title, createdAt: doc.createdAt || 0 });
    }
    out.sort((a, b) => (b.createdAt || 0) - (a.createdAt || 0));
    return { articles: out.slice(0, 30) };
  }
);

register(
  { name: "read_article", description: "读取某一篇文章的口述转写和正文。", input_schema: { type: "object", properties: { stem: { type: "string" } }, required: ["stem"], additionalProperties: false } },
  async ({ stem }, { env, scope }) => {
    if (badStem(stem)) return { error: "bad_stem" };
    const obj = await env.FILES.get(scope + "articles/" + stem + ".json");
    if (!obj) return { error: "not_found" };
    let doc; try { doc = JSON.parse(await obj.text()); } catch { return { error: "bad_article" }; }
    const articles = Array.isArray(doc.articles) ? doc.articles.map((a) => ({ title: a.title, body: a.body })) : [];
    return { transcript: doc.transcript || "", articles };
  }
);

register(
  { name: "write_article", description: "把改写后的全部文章写回当前正在编辑的这一篇（只能写当前篇）。输入是完整的文章数组。", input_schema: { type: "object", properties: { articles: { type: "array", items: { type: "object", properties: { title: { type: "string" }, body: { type: "string" } }, required: ["title", "body"], additionalProperties: false } } }, required: ["articles"], additionalProperties: false } },
  async ({ articles }, { env, articleKey }) => {
    if (!Array.isArray(articles) || !articles.length) return { error: "empty_articles" };
    const obj = await env.FILES.get(articleKey);
    if (!obj) return { error: "not_found" };
    let doc; try { doc = JSON.parse(await obj.text()); } catch { return { error: "bad_article" }; }
    const prev = Array.isArray(doc.articles) ? doc.articles : [];
    doc.articles = articles.map((a, i) => {
      const out = { title: String(a.title || "(无题)"), body: String(a.body || "") };
      if (prev[i] && prev[i].wechatMediaId) out.wechatMediaId = prev[i].wechatMediaId;
      return out;
    });
    delete doc.title; delete doc.body; // collapse any v1 remnants
    await env.FILES.put(articleKey, JSON.stringify(doc), { httpMetadata: { contentType: "application/json" } });
    return { ok: true, count: doc.articles.length };
  }
);
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ~/code/jianshuo.dev/agent && npm test`
Expected: PASS (all list/read/write cases).

- [ ] **Step 5: Commit**

```bash
cd ~/code/jianshuo.dev/agent && git add src/tools.js test/tools.test.js
git commit -m "feat: list_articles / read_article / write_article R2 tools"
```

---

### Task 3: Style tools — read / write CLAUDE.md

**Files:**
- Modify: `~/code/jianshuo.dev/agent/src/tools.js`
- Test: `~/code/jianshuo.dev/agent/test/tools.test.js`

**Interfaces:**
- Produces:
  - `read_style` (no input) → `{style:string}` (text of `scope+"CLAUDE.md"`, `""` if absent).
  - `write_style` (`{content}`) → `{ok:true}`; overwrites `scope+"CLAUDE.md"` (full replace).

- [ ] **Step 1: Write the failing tests**

Append to `test/tools.test.js`:

```js
describe("style tools", () => {
  it("read_style returns the CLAUDE.md text, empty when absent", async () => {
    const env = fakeEnv({ "users/u/CLAUDE.md": "# 我的名字\n王建硕\n\n口语一点" });
    expect(await rt("read_style", {}, CTX(env))).toEqual({ style: "# 我的名字\n王建硕\n\n口语一点" });
    const env2 = fakeEnv({});
    expect(await rt("read_style", {}, CTX(env2))).toEqual({ style: "" });
  });
  it("write_style overwrites CLAUDE.md", async () => {
    const env = fakeEnv({ "users/u/CLAUDE.md": "old" });
    expect(await rt("write_style", { content: "new style" }, CTX(env))).toEqual({ ok: true });
    expect(env.FILES._store.get("users/u/CLAUDE.md")).toBe("new style");
  });
  it("write_style rejects empty content", async () => {
    const env = fakeEnv({});
    expect(await rt("write_style", { content: "" }, CTX(env))).toEqual({ error: "empty_content" });
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ~/code/jianshuo.dev/agent && npm test`
Expected: FAIL — `read_style`/`write_style` unknown.

- [ ] **Step 3: Implement the style tools**

Append to `src/tools.js`:

```js
register(
  { name: "read_style", description: "读取用户的写作文风（CLAUDE.md 的内容）。调整文风前先读出来。", input_schema: { type: "object", properties: {}, additionalProperties: false } },
  async (_args, { env, scope }) => {
    const obj = await env.FILES.get(scope + "CLAUDE.md");
    return { style: obj ? (await obj.text()) : "" };
  }
);

register(
  { name: "write_style", description: "整体覆盖写用户的写作文风（CLAUDE.md）。先 read_style 读出当前内容，改完再整体写回。影响以后所有挖矿和编辑。", input_schema: { type: "object", properties: { content: { type: "string" } }, required: ["content"], additionalProperties: false } },
  async ({ content }, { env, scope }) => {
    if (!content || !String(content).trim()) return { error: "empty_content" };
    await env.FILES.put(scope + "CLAUDE.md", String(content), { httpMetadata: { contentType: "text/markdown" } });
    return { ok: true };
  }
);
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ~/code/jianshuo.dev/agent && npm test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
cd ~/code/jianshuo.dev/agent && git add src/tools.js test/tools.test.js
git commit -m "feat: read_style / write_style tools (CLAUDE.md)"
```

---

### Task 4: Distribution tools — publish_wechat / share_to_community

**Files:**
- Modify: `~/code/jianshuo.dev/agent/src/tools.js`
- Test: `~/code/jianshuo.dev/agent/test/tools.test.js`

**Interfaces:**
- Produces:
  - `publish_wechat` (no input) → result of `POST {origin}/files/api/wechat/<rel>` JSON (e.g. `{ok,created,updated}` or `{error,errcode}`).
  - `share_to_community` (no input) → result of `POST {origin}/files/api/community/share/<rel>` JSON (e.g. `{ok,shareId}`).
  - Both compute `rel = articleKey.slice(scope.length)` and send `Authorization: Bearer <token>`.
  - Both read `globalThis.fetch` so tests can stub it.

- [ ] **Step 1: Write the failing tests**

Append to `test/tools.test.js`:

```js
import { fakeFetch } from "./fakes.js";
import { afterEach, vi } from "vitest";

afterEach(() => { if (globalThis.fetch && globalThis.fetch.calls) delete globalThis.fetch; });

describe("distribution tools", () => {
  it("publish_wechat POSTs the scope-relative key with the bearer token", async () => {
    const env = fakeEnv(seedTwoArticles());
    globalThis.fetch = fakeFetch({
      "POST https://jianshuo.dev/files/api/wechat/articles/s2.json": () => ({ ok: true, body: { ok: true, created: 1, updated: 0 } }),
    });
    const r = await rt("publish_wechat", {}, CTX(env));
    expect(r).toEqual({ ok: true, created: 1, updated: 0 });
    const call = globalThis.fetch.calls[0];
    expect(call.method).toBe("POST");
    expect(call.headers.Authorization).toBe("Bearer t");
  });

  it("share_to_community POSTs the scope-relative key and returns shareId", async () => {
    const env = fakeEnv(seedTwoArticles());
    globalThis.fetch = fakeFetch({
      "POST https://jianshuo.dev/files/api/community/share/articles/s2.json": () => ({ ok: true, body: { ok: true, shareId: "abc123" } }),
    });
    const r = await rt("share_to_community", {}, CTX(env));
    expect(r).toEqual({ ok: true, shareId: "abc123" });
  });

  it("surfaces a non-ok response body", async () => {
    const env = fakeEnv(seedTwoArticles());
    globalThis.fetch = fakeFetch({
      "POST https://jianshuo.dev/files/api/wechat/articles/s2.json": () => ({ ok: false, status: 409, body: { error: "wechat_not_configured" } }),
    });
    expect(await rt("publish_wechat", {}, CTX(env))).toEqual({ error: "wechat_not_configured" });
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ~/code/jianshuo.dev/agent && npm test`
Expected: FAIL — distribution tools unknown.

- [ ] **Step 3: Implement the distribution tools**

Append to `src/tools.js`:

```js
function relKey({ articleKey, scope }) {
  return articleKey.startsWith(scope) ? articleKey.slice(scope.length) : articleKey;
}

async function postFiles(path, { token, origin }) {
  const resp = await fetch(`${origin}/files/api/${path}`, {
    method: "POST",
    headers: { Authorization: `Bearer ${token}` },
  });
  const body = await resp.json().catch(() => null);
  if (!resp.ok) return body || { error: `http_${resp.status}` };
  return body;
}

register(
  { name: "publish_wechat", description: "把当前这篇文章发布为微信公众号草稿（说了直接发）。", input_schema: { type: "object", properties: {}, additionalProperties: false } },
  async (_args, ctx) => postFiles(`wechat/${relKey(ctx)}`, ctx)
);

register(
  { name: "share_to_community", description: "把当前这篇文章分享到 VoiceDrop 社区（立即分享）。", input_schema: { type: "object", properties: {}, additionalProperties: false } },
  async (_args, ctx) => postFiles(`community/share/${relKey(ctx)}`, ctx)
);
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ~/code/jianshuo.dev/agent && npm test`
Expected: PASS. All 7 tools now registered (`TOOL_DEFS.length === 7`).

- [ ] **Step 5: Commit**

```bash
cd ~/code/jianshuo.dev/agent && git add src/tools.js test/tools.test.js
git commit -m "feat: publish_wechat / share_to_community tools via existing endpoints"
```

---

### Task 5: Agentic loop

**Files:**
- Create: `~/code/jianshuo.dev/agent/src/loop.js`
- Test: `~/code/jianshuo.dev/agent/test/loop.test.js`

**Interfaces:**
- Consumes: `runTool`, `TOOL_DEFS` from `src/tools.js`.
- Produces:
  - `parseAssistant(resp) -> {text, toolUses:[{id,name,input}]}` — extracts text + tool_use blocks from an Anthropic Messages response.
  - `runAgentLoop({callClaude, ctx, system, userText, maxSteps=8}) -> {calledTools:string[], finalText:string, steps:number}` — drives the loop, executing tools via `runTool`, until no tool_use or `maxSteps` reached.
  - `callClaude({system, messages, tools}) -> Promise<anthropicResponseJSON>` is INJECTED (real impl in Task 6).

- [ ] **Step 1: Write the failing tests**

Create `test/loop.test.js`:

```js
import { describe, it, expect } from "vitest";
import { parseAssistant, runAgentLoop } from "../src/loop.js";
import { fakeEnv } from "./fakes.js";

// Build a fake Anthropic response.
const asst = (...blocks) => ({ role: "assistant", content: blocks, stop_reason: blocks.some(b => b.type === "tool_use") ? "tool_use" : "end_turn" });
const toolUse = (name, input, id = name + "-1") => ({ type: "tool_use", id, name, input });
const text = (t) => ({ type: "text", text: t });

const ctx = (env) => ({ env, scope: "users/u/", articleKey: "users/u/articles/cur.json", token: "t", origin: "https://x" });

describe("parseAssistant", () => {
  it("splits text and tool_use blocks", () => {
    const r = parseAssistant(asst(text("hi"), toolUse("read_article", { stem: "a" })));
    expect(r.text).toBe("hi");
    expect(r.toolUses).toEqual([{ id: "read_article-1", name: "read_article", input: { stem: "a" } }]);
  });
});

describe("runAgentLoop", () => {
  it("chains list -> read -> read -> write to merge, then stops", async () => {
    const env = fakeEnv({
      "users/u/articles/cur.json": JSON.stringify({ schema: 2, transcript: "T", articles: [{ title: "Cur", body: "c" }] }),
      "users/u/articles/old.json": JSON.stringify({ schema: 2, createdAt: 1, transcript: "", articles: [{ title: "Old", body: "o" }] }),
    });
    // Scripted Claude: one tool per turn, then a final text turn (no tools).
    const script = [
      asst(toolUse("list_articles", {})),
      asst(toolUse("read_article", { stem: "old" })),
      asst(toolUse("write_article", { articles: [{ title: "Merged", body: "c\n\no" }] })),
      asst(text("合并好了")),
    ];
    let i = 0;
    const callClaude = async () => script[i++];
    const r = await runAgentLoop({ callClaude, ctx: ctx(env), system: "S", userText: "把 old 合并进来" });
    expect(r.calledTools).toEqual(["list_articles", "read_article", "write_article"]);
    expect(r.finalText).toBe("合并好了");
    const doc = JSON.parse(env.FILES._store.get("users/u/articles/cur.json"));
    expect(doc.articles[0].title).toBe("Merged");
  });

  it("handles an action-only turn (publish) with no write", async () => {
    const env = fakeEnv({ "users/u/articles/cur.json": JSON.stringify({ articles: [{ title: "C", body: "c" }] }) });
    globalThis.fetch = (async () => ({ ok: true, status: 200, json: async () => ({ ok: true, created: 1 }) }));
    const script = [asst(toolUse("publish_wechat", {})), asst(text("已发草稿"))];
    let i = 0;
    const r = await runAgentLoop({ callClaude: async () => script[i++], ctx: ctx(env), system: "S", userText: "发公众号" });
    expect(r.calledTools).toEqual(["publish_wechat"]);
    expect(r.finalText).toBe("已发草稿");
    delete globalThis.fetch;
  });

  it("stops at maxSteps even if Claude never yields", async () => {
    const env = fakeEnv({ "users/u/articles/cur.json": JSON.stringify({ articles: [{ title: "C", body: "c" }] }) });
    const callClaude = async () => asst(toolUse("read_article", { stem: "cur" }));
    const r = await runAgentLoop({ callClaude, ctx: ctx(env), system: "S", userText: "loop", maxSteps: 3 });
    expect(r.steps).toBe(3);
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd ~/code/jianshuo.dev/agent && npm test`
Expected: FAIL — `Cannot find module '../src/loop.js'`.

- [ ] **Step 3: Implement the loop**

Create `src/loop.js`. `steps` counts completed Claude calls — incremented right after each call — so a 3-turn run that never yields returns `steps === 3`, matching the maxSteps test:

```js
import { runTool, TOOL_DEFS } from "./tools.js";

export function parseAssistant(resp) {
  const content = (resp && resp.content) || [];
  const text = content.filter((b) => b.type === "text").map((b) => b.text).join("");
  const toolUses = content
    .filter((b) => b.type === "tool_use")
    .map((b) => ({ id: b.id, name: b.name, input: b.input || {} }));
  return { text, toolUses };
}

// Drive Claude with tools until it stops calling them (or maxSteps).
export async function runAgentLoop({ callClaude, ctx, system, userText, maxSteps = 8 }) {
  const messages = [{ role: "user", content: userText }];
  const calledTools = [];
  let finalText = "";
  let steps = 0;
  while (steps < maxSteps) {
    const resp = await callClaude({ system, messages, tools: TOOL_DEFS });
    steps++;
    const { text, toolUses } = parseAssistant(resp);
    messages.push({ role: "assistant", content: resp.content });
    if (!toolUses.length) { finalText = text; break; }
    const results = [];
    for (const tu of toolUses) {
      calledTools.push(tu.name);
      results.push({ type: "tool_result", tool_use_id: tu.id, content: JSON.stringify(await runTool(tu.name, tu.input, ctx)) });
    }
    messages.push({ role: "user", content: results });
  }
  return { calledTools, finalText, steps };
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd ~/code/jianshuo.dev/agent && npm test`
Expected: PASS (merge chain writes the current doc; action-only path; maxSteps cap = 3).

- [ ] **Step 5: Commit**

```bash
cd ~/code/jianshuo.dev/agent && git add src/loop.js test/loop.test.js
git commit -m "feat: agentic tool-use loop (parseAssistant + runAgentLoop)"
```

---

### Task 6: Wire the loop into ArticleEditor + real Claude tool-use call

**Files:**
- Modify: `~/code/jianshuo.dev/agent/src/index.js` (the `ArticleEditor` class: `onConnect`, `onMessage`; remove `_rewrite`/`_callClaude`; add `SYSTEM` + `_callClaude` tool-use wrapper)

**Interfaces:**
- Consumes: `runAgentLoop` from `src/loop.js`.
- Produces: unchanged WebSocket protocol — every turn ends with `{type:"updated", article:<current doc>}` (the app already handles it). `{type:"status",state:"working"}` and `{type:"error",message}` unchanged.

- [ ] **Step 1: Persist the bearer token on connect**

In `src/index.js`, the Worker entry already does `fwd.headers.set("x-vd-article-key", ...)` and copies `Authorization` (via `new Request(request)`). In `ArticleEditor.onConnect`, read and store the token alongside the existing keys. Replace the body of `onConnect` with:

```js
  onConnect(connection, ctx) {
    const key = ctx.request.headers.get("x-vd-article-key");
    const scope = ctx.request.headers.get("x-vd-scope");
    const token = (ctx.request.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
    const set = (k, v) => { if (v) this.sql`INSERT INTO config (k, v) VALUES (${k}, ${v}) ON CONFLICT(k) DO UPDATE SET v = excluded.v`; };
    set("articleKey", key);
    set("scope", scope);
    set("token", token);
  }
```

- [ ] **Step 2: Add the SYSTEM prompt and the tool-use Claude wrapper**

In `src/index.js`, add near the top imports:

```js
import { runAgentLoop } from "./loop.js";
import { TOOL_DEFS } from "./tools.js";
```

Add a new system constant (reuse the existing `REVISE_SYSTEM` voice DNA, reframed for tools). Place it next to `REVISE_SYSTEM`:

```js
const SYSTEM = `你在用语音帮用户编辑他自己的公众号文章。你有一组工具，按用户这次的语音指令决定怎么做：
- 改写当前这篇：直接调 write_article，传入改写后的完整文章数组。
- 合并 / 参考其它文章：先 list_articles 看有哪些，再 read_article 读出来，融合后用 write_article 写回当前这一篇（只能写当前篇，其它篇只读）。
- 发公众号：调 publish_wechat。分享到社区：调 share_to_community。
- 调整文风：先 read_style 读出当前 CLAUDE.md，改完用 write_style 整体写回。
默认就是「改写当前这篇」。做完简短说一句结果即可。

写文章时遵守下面的语气 DNA：
${REVISE_SYSTEM}`;
```

- [ ] **Step 3: Replace `onMessage` to drive the loop**

Replace the existing `onMessage` body so it builds the user text from the current doc + transcript and runs the loop, then always pushes the current doc back:

```js
  async onMessage(connection, message) {
    let msg;
    try { msg = JSON.parse(typeof message === "string" ? message : ""); } catch { return; }
    if (!msg || msg.type !== "instruct") return;
    const instruction = String(msg.text || "").trim();
    if (!instruction) { connection.send(JSON.stringify({ type: "error", message: "空指令" })); return; }
    if (this._busy) { connection.send(JSON.stringify({ type: "error", message: "正在修改，请稍候" })); return; }
    this._busy = true;
    connection.send(JSON.stringify({ type: "status", state: "working" }));
    try {
      const { articleKey, scope, token } = this._config();
      if (!articleKey) throw new Error("会话未初始化");
      const obj = await this.env.FILES.get(articleKey);
      if (!obj) throw new Error("文章不存在");
      const doc = JSON.parse(await obj.text());
      const articles = Array.isArray(doc.articles) && doc.articles.length
        ? doc.articles : (doc.body ? [{ title: doc.title || "(无题)", body: doc.body }] : []);

      const userText = [
        "当前文章（你正在编辑这一篇）：",
        JSON.stringify({ articles: articles.map((a) => ({ title: a.title, body: a.body })) }, null, 2),
        "",
        "原始口述转写（事实来源，只能用这里出现的事实，不可编造）：",
        doc.transcript || "（无）",
        "",
        "这次的语音指令：",
        instruction,
      ].join("\n");

      const ctx = { env: this.env, scope, articleKey, token, origin: "https://jianshuo.dev" };
      const result = await runAgentLoop({ callClaude: (p) => this._callClaude(p), ctx, system: SYSTEM, userText });

      // Always push the (possibly unchanged) current doc so the app reloads and
      // the in-flight queue item resolves — works for edit, merge, AND action-only turns.
      const after = await this.env.FILES.get(articleKey);
      const finalDoc = after ? JSON.parse(await after.text()) : doc;
      connection.send(JSON.stringify({ type: "updated", article: finalDoc }));

      this.sql`INSERT INTO history (instruction, created_at) VALUES (${instruction}, ${Date.now()})`;
      void result;
    } catch (e) {
      connection.send(JSON.stringify({ type: "error", message: String((e && e.message) || e) }));
    } finally {
      this._busy = false;
    }
  }
```

- [ ] **Step 4: Replace `_callClaude` with a tool-use wrapper and delete `_rewrite`**

Remove the old `_rewrite` method and the old `_callClaude` (the structured-output version), plus the now-unused `ARTICLES_SCHEMA`, `articlesFrom`, `parseLLMJson` if nothing else references them (grep first — `articlesFrom`/`parseLLMJson` are only used by the old `_callClaude`). Add the new tool-use `_callClaude` on `ArticleEditor`:

```js
  // One Anthropic Messages call WITH tools. Returns the raw response JSON so the
  // loop can read content blocks (text + tool_use).
  async _callClaude({ system, messages, tools }) {
    const resp = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "x-api-key": this.env.CLAUDE_API_KEY,
        "anthropic-version": "2023-06-01",
        "content-type": "application/json",
      },
      body: JSON.stringify({ model: MODEL, max_tokens: 8000, system, messages, tools, tool_choice: { type: "auto" } }),
    });
    if (!resp.ok) throw new Error(`Claude HTTP ${resp.status}: ${(await resp.text()).slice(0, 160)}`);
    return resp.json();
  }
```

- [ ] **Step 5: Verify the existing unit tests still pass and lint the bundle**

Run: `cd ~/code/jianshuo.dev/agent && npm test`
Expected: PASS (Tasks 1–5 tests unaffected).

Run: `cd ~/code/jianshuo.dev/agent && npx wrangler deploy --dry-run`
Expected: builds with no syntax/import errors (no upload).

- [ ] **Step 6: Manual end-to-end smoke (real deploy)**

Deploy: `cd ~/code/jianshuo.dev/agent && npx wrangler deploy`

In the app (or a wscat against `wss://jianshuo.dev/agent/edit?stem=<real-stem>` with a real `Authorization: Bearer` token), send each and confirm:
- `{"type":"instruct","text":"把开头改紧凑一点"}` → `updated` with a rewritten current article.
- `{"type":"instruct","text":"把最近的另一篇合并进来"}` → `updated` where the current article absorbed another; the other article still exists (check 文章 tab).
- `{"type":"instruct","text":"发公众号"}` → `updated` (unchanged doc); a WeChat draft appears (or the real errcode surfaces if not configured).
- `{"type":"instruct","text":"分享到社区"}` → `updated`; the post shows in the 社区 tab.
- `{"type":"instruct","text":"以后写得更口语一点"}` → `read_style`/`write_style` ran; re-open Settings → 文风 shows the updated CLAUDE.md.

- [ ] **Step 7: Commit**

```bash
cd ~/code/jianshuo.dev/agent && git add src/index.js
git commit -m "feat: drive ArticleEditor with the agentic tool-use loop"
```

---

## Notes / out of scope

- **App side:** no changes required. `ArticleAgentSession` already handles `updated`/`status`/`error`, and every turn now ends with `updated`. Surfacing the agent's final summary (e.g. a "已发草稿" toast) is a deliberate follow-up, not in this plan.
- **Community auth:** `share_to_community` forwards the user's own bearer token, so it inherits the exact auth behavior of the in-app 分享 button (including any Apple-sign-in gate). If the user isn't signed in where the endpoint requires it, the tool result carries the endpoint's error, which Claude relays in its final text.
- **No confirmation:** 公众号 fires directly (user's explicit choice).
- **Blast radius:** `write_article` ignores any stem and always targets the DO's own `articleKey`; cross-article overwrite is impossible.
```
