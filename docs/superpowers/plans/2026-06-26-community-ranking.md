# VD社区 基础推荐排序 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 给 VD社区做一个「互动加权 × 年龄衰减」的全局排序(千人一面),采集 view/finish/like/reply 四个聚合信号,全部跑在一个**可随时拔掉**的独立 Worker 里,核心 VoiceDrop 零改动。

**Architecture:** 新独立 Worker `voicedrop-reco`(`~/code/jianshuo.dev/reco/`,自带 D1 / wrangler / README / 测试),路由 `jianshuo.dev/reco/*`。它只管互动计数(D1 `engagement` 单表)+ 排序计算,**不碰 R2、不反调核心**。iOS app 先拿核心 `community/list`(时间序),再问 reco 怎么排;**reco 失败就用时间序**,feed 照常出。

**Tech Stack:** Cloudflare Workers + D1 (SQLite) + Web Crypto;测试用 vitest(镜像 `agent/` 的手写 fake 范式);iOS SwiftUI。

## Global Constraints

- **核心隔离**:`~/code/jianshuo.dev/functions/files/api/[[path]].js` 与 `community/list` **一行都不改**。reco 宕机/报错/超时 → app 回退时间序,VoiceDrop 无感。
- **reco 单向**:不读 R2、不调用核心、无 FILES_TOKEN、无 Claude。唯一与核心共享的是 `SESSION_SECRET` 的**值**(各自独立验 token),非运行时依赖。
- **权重(起步,可调)**:`W = {view:1, finish:4, like:3, reply:5}`;冷却指数 `1.5`;作者打散强度 `0.5`。
- **rank 超时 2s** → app 即回退时间序。
- **赞不显示计数**:❤️ 只反映"我赞过没"(实心/空心),无数字。
- **`firstSharedAt` 单位是毫秒**(`Date.now()`);`ageHours = (now - firstSharedAt)/3600000`。
- **`user_sub` = reco 独立解析出的 `scope`**(如 `users/anon-<hash>/` 或 Apple JWT 里的 scope)。
- 部署:reco = `cd ~/code/jianshuo.dev/reco && npx wrangler deploy`(独立);核心 Pages 不重新部署;iOS push `main` → TestFlight。
- 核心测试必须保持绿(核心零改动):`cd ~/code/jianshuo.dev/agent && npm test`。

---

## File Structure

**新建(reco worker,`~/code/jianshuo.dev/reco/`):**
- `package.json` — type:module,vitest,wrangler。
- `wrangler.jsonc` — name `voicedrop-reco`,route `jianshuo.dev/reco/*`,`workers_dev:true`,D1 binding `DB`。无 R2、无 DO。
- `migrations/0001_engagement.sql` — `engagement` 表。
- `src/ranking.js` — 纯函数 `postScore` / `rankPosts`(无 I/O,核心可测物)。
- `src/auth.js` — token 验证(从核心复刻):`resolveScope(token, secret) → scope|null`。
- `src/store.js` — D1 访问:`recordEngagement` / `countsFor` / `likedBy`。
- `src/index.js` — Worker fetch handler,路由 `/reco/engage/<id>`、`/reco/rank`。
- `test/ranking.test.js` / `test/auth.test.js` / `test/store.test.js` / `test/index.test.js` / `test/fakes.js`。
- `README.md` — canonical 文档。

**修改(iOS,`~/code/voicedrop/VoiceDropApp/`):**
- `Community.swift` — `CommunityStore` 加 reco base + `engage()` + `rank()` + `likedShareIds` + 在 `load()` 里重排;`CommunityPostView` 加 view/finish 上报 + ❤️ 按钮。

**修改(项目状态):**
- `~/code/voicedrop/STATE.md` — 加一段 reco 指针(canonical 文档在 reco/README.md)。

---

## Task 1: reco 脚手架 + 纯排序模块(ranking.js)

**Files:**
- Create: `~/code/jianshuo.dev/reco/package.json`
- Create: `~/code/jianshuo.dev/reco/src/ranking.js`
- Test: `~/code/jianshuo.dev/reco/test/ranking.test.js`

**Interfaces:**
- Produces:
  - `postScore(eng, replyCount, firstSharedAt, now) → number` — `eng` 是 `{view,finish,like}`(字段可缺省 0)。
  - `rankPosts(posts, engMap, now) → string[]` — `posts` 是 `[{shareId, firstSharedAt, author, replyCount}]`;`engMap` 是 `{[shareId]: {view,finish,like}}`;返回**排好序的 shareId 数组**。

- [ ] **Step 1: 建 package.json**

```json
{
  "name": "voicedrop-reco",
  "version": "1.0.0",
  "private": true,
  "type": "module",
  "scripts": {
    "deploy": "wrangler deploy",
    "dev": "wrangler dev",
    "test": "vitest run"
  },
  "devDependencies": {
    "wrangler": "^4",
    "vitest": "^2"
  }
}
```

- [ ] **Step 2: 写失败测试 `test/ranking.test.js`**

```javascript
import { describe, it, expect } from "vitest";
import { postScore, rankPosts } from "../src/ranking.js";

const HOUR = 3600000;

describe("postScore", () => {
  it("新帖(age≈0、零互动)得分高于老帖(零互动)", () => {
    const now = 1_000_000_000_000;
    const fresh = postScore({}, 0, now, now);
    const old = postScore({}, 0, now - 48 * HOUR, now);
    expect(fresh).toBeGreaterThan(old);
  });

  it("互动按权重计入:like 比 view 抬分更多", () => {
    const now = 1_000_000_000_000;
    const withLike = postScore({ like: 1 }, 0, now, now);
    const withView = postScore({ view: 1 }, 0, now, now);
    expect(withLike).toBeGreaterThan(withView);
  });

  it("高互动老帖能顶过零互动新帖", () => {
    const now = 1_000_000_000_000;
    const hotOld = postScore({ like: 5, finish: 5 }, 3, now - 12 * HOUR, now);
    const coldNew = postScore({}, 0, now, now);
    expect(hotOld).toBeGreaterThan(coldNew);
  });

  it("firstSharedAt 缺失不崩(当作 now)", () => {
    const now = 1_000_000_000_000;
    expect(postScore({}, 0, undefined, now)).toBeGreaterThan(0);
  });
});

describe("rankPosts", () => {
  it("空输入返回空数组", () => {
    expect(rankPosts([], {}, 1)).toEqual([]);
  });

  it("同作者多帖被打散(不相邻)", () => {
    const now = 1_000_000_000_000;
    // a1,a2,a3 同作者且分本应最高;b1 不同作者。打散后 a 系列不应三连。
    const posts = [
      { shareId: "a1", firstSharedAt: now, author: "A", replyCount: 0 },
      { shareId: "a2", firstSharedAt: now, author: "A", replyCount: 0 },
      { shareId: "a3", firstSharedAt: now, author: "A", replyCount: 0 },
      { shareId: "b1", firstSharedAt: now, author: "B", replyCount: 0 },
    ];
    const order = rankPosts(posts, {}, now);
    expect(order).toHaveLength(4);
    // B 不应被挤到最后(它在第二位被提上来)
    expect(order.indexOf("b1")).toBeLessThan(3);
  });

  it("按分排序:高互动帖排在前", () => {
    const now = 1_000_000_000_000;
    const posts = [
      { shareId: "x", firstSharedAt: now, author: "A", replyCount: 0 },
      { shareId: "y", firstSharedAt: now, author: "B", replyCount: 0 },
    ];
    const order = rankPosts(posts, { y: { like: 10 } }, now);
    expect(order[0]).toBe("y");
  });
});
```

- [ ] **Step 3: 跑测试确认失败**

Run: `cd ~/code/jianshuo.dev/reco && npm install && npm test`
Expected: FAIL — `Cannot find module '../src/ranking.js'`。

- [ ] **Step 4: 写 `src/ranking.js`**

```javascript
// 互动加权(起步值,= recommendation_system.md §3.1)
export const W = { view: 1, finish: 4, like: 3, reply: 5 };

// HN/牛顿冷却:新帖起高分,随时间冷却。firstSharedAt 是 ms。
export function postScore(eng, replyCount, firstSharedAt, now) {
  const e = W.view * (eng.view || 0) + W.finish * (eng.finish || 0)
          + W.like * (eng.like || 0) + W.reply * (replyCount || 0);
  const ageHours = Math.max(0, (now - (firstSharedAt || now)) / 3600000);
  return (1 + e) / Math.pow(ageHours + 2, 1.5);
}

// 排序 + 作者打散(贪心,乘性惩罚;作者少时几乎不生效)。返回 shareId 数组。
export function rankPosts(posts, engMap, now) {
  const scored = posts.map((p) => ({
    p, s: postScore(engMap[p.shareId] || {}, p.replyCount, p.firstSharedAt, now),
  }));
  const out = [], seen = {};
  while (scored.length) {
    let bi = 0, bv = -Infinity;
    for (let i = 0; i < scored.length; i++) {
      const adj = scored[i].s * Math.pow(0.5, seen[scored[i].p.author] || 0);
      if (adj > bv) { bv = adj; bi = i; }
    }
    const [picked] = scored.splice(bi, 1);
    seen[picked.p.author] = (seen[picked.p.author] || 0) + 1;
    out.push(picked.p.shareId);
  }
  return out;
}
```

- [ ] **Step 5: 跑测试确认通过**

Run: `cd ~/code/jianshuo.dev/reco && npm test`
Expected: PASS(ranking.test.js 全绿)。

- [ ] **Step 6: 提交**

```bash
cd ~/code/jianshuo.dev
git add reco/package.json reco/src/ranking.js reco/test/ranking.test.js
git commit -m "feat(reco): scaffold reco worker + pure ranking module"
```

---

## Task 2: token 验证模块(auth.js)

**Files:**
- Create: `~/code/jianshuo.dev/reco/src/auth.js`
- Test: `~/code/jianshuo.dev/reco/test/auth.test.js`

**Interfaces:**
- Produces:
  - `resolveScope(token, secret) → Promise<string|null>` — Apple session JWT → 其 scope;`anon_*` token → `users/anon-<hash>/`;否则 null。
  - `hmacSign(data, secret) → Promise<string>`(测试里造 token 用)。

> 这些是从核心 `functions/files/api/[[path]].js`(行 840–880)**逐字复刻**的 crypto helper,reco 独立验 token、不调核心。

- [ ] **Step 1: 写失败测试 `test/auth.test.js`**

```javascript
import { describe, it, expect } from "vitest";
import { resolveScope, hmacSign } from "../src/auth.js";

const SECRET = "test-secret";

// 造一个与核心同构的 session JWT(HS256)。
function b64url(str) {
  return btoa(unescape(encodeURIComponent(str))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
async function mintSession(scope, secret) {
  const now = Math.floor(Date.now() / 1000);
  const h = b64url(JSON.stringify({ alg: "HS256", typ: "JWT" }));
  const p = b64url(JSON.stringify({ scope, apple: true, iat: now, exp: now + 3600 }));
  const sig = await hmacSign(`${h}.${p}`, secret);
  return `${h}.${p}.${sig}`;
}

describe("resolveScope", () => {
  it("有效 session JWT → 解出 scope", async () => {
    const t = await mintSession("users/abc/", SECRET);
    expect(await resolveScope(t, SECRET)).toBe("users/abc/");
  });

  it("被篡改的签名 → null", async () => {
    const t = await mintSession("users/abc/", SECRET);
    expect(await resolveScope(t + "x", SECRET)).toBeNull();
  });

  it("anon_ token → users/anon-<hash>/", async () => {
    const scope = await resolveScope("anon_" + "a".repeat(24), SECRET);
    expect(scope).toMatch(/^users\/anon-[0-9a-f]{32}\/$/);
  });

  it("空/垃圾 token → null", async () => {
    expect(await resolveScope("", SECRET)).toBeNull();
    expect(await resolveScope("garbage", SECRET)).toBeNull();
  });
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd ~/code/jianshuo.dev/reco && npm test -- auth`
Expected: FAIL — `Cannot find module '../src/auth.js'`。

- [ ] **Step 3: 写 `src/auth.js`(复刻核心 helper)**

```javascript
// 复刻自核心 functions/files/api/[[path]].js(行 840–887)。reco 独立验 token。
export async function hmacSign(data, secret) {
  const key = await crypto.subtle.importKey(
    "raw", new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(data));
  return bytesToB64url(new Uint8Array(sig));
}

async function sha256hex(s) {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

async function verifySession(tokenStr, secret) {
  const parts = tokenStr.split(".");
  if (parts.length !== 3) return null;
  const [h, p, s] = parts;
  const expected = await hmacSign(`${h}.${p}`, secret);
  if (!timingSafeEqual(s, expected)) return null;
  let payload;
  try { payload = JSON.parse(b64urlToString(p)); } catch { return null; }
  if (!payload.scope) return null;
  if (payload.exp && payload.exp * 1000 < Date.now()) return null;
  return { scope: payload.scope, apple: !!payload.apple };
}

async function anonScopeFromToken(token) {
  if (!token || !token.startsWith("anon_") || token.length < 20) return null;
  const id = (await sha256hex(token)).slice(0, 32);
  return `users/anon-${id}/`;
}

// 任意有效 token → scope;否则 null。reco 不接受 temp/admin token。
export async function resolveScope(token, secret) {
  if (!token) return null;
  if (secret) {
    const sess = await verifySession(token, secret);
    if (sess) return sess.scope;
  }
  return await anonScopeFromToken(token);
}

// ── b64url / timing-safe(复刻核心)──
function timingSafeEqual(a, b) {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}
function bytesToB64url(bytes) {
  let bin = "";
  for (const b of bytes) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
function b64urlToString(s) {
  const b64 = s.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((s.length + 3) % 4);
  const bin = atob(b64);
  const bytes = Uint8Array.from(bin, (c) => c.charCodeAt(0));
  return new TextDecoder().decode(bytes);
}
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd ~/code/jianshuo.dev/reco && npm test -- auth`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
cd ~/code/jianshuo.dev
git add reco/src/auth.js reco/test/auth.test.js
git commit -m "feat(reco): independent token verification (copied from core)"
```

---

## Task 3: D1 访问层(store.js)+ fake D1

**Files:**
- Create: `~/code/jianshuo.dev/reco/src/store.js`
- Create: `~/code/jianshuo.dev/reco/test/fakes.js`
- Test: `~/code/jianshuo.dev/reco/test/store.test.js`

**Interfaces:**
- Consumes: `env.DB`(D1 binding)。
- Produces:
  - `recordEngagement(env, shareId, sub, action, on, now) → Promise<void>` — `view`/`finish` = INSERT OR IGNORE;`like` 按 `on`(false=DELETE,否则 INSERT OR IGNORE)。
  - `countsFor(env, shareIds) → Promise<{[shareId]:{view,finish,like}}>`。
  - `likedBy(env, sub, shareIds) → Promise<Set<string>>`。
- `test/fakes.js` Produces: `fakeD1(rows=[]) → { DB }`(支持本任务用到的 4 条语句)。

- [ ] **Step 1: 写 fake D1 `test/fakes.js`**

```javascript
// 内存版 D1,只实现 store.js 用到的 4 条语句。行 = {share_id,user_sub,action,created_at}。
export function fakeD1(seed = []) {
  const rows = [...seed];
  function stmt(sql) {
    let args = [];
    return {
      bind(...a) { args = a; return this; },
      async run() {
        if (/^INSERT OR IGNORE/.test(sql)) {
          const [share_id, user_sub, action, created_at] = args;
          if (!rows.some(r => r.share_id === share_id && r.user_sub === user_sub && r.action === action))
            rows.push({ share_id, user_sub, action, created_at });
        } else if (/^DELETE/.test(sql)) {
          const [share_id, user_sub] = args;
          for (let i = rows.length - 1; i >= 0; i--)
            if (rows[i].share_id === share_id && rows[i].user_sub === user_sub && rows[i].action === "like") rows.splice(i, 1);
        }
        return { success: true };
      },
      async all() {
        if (/GROUP BY/.test(sql)) {
          // counts: WHERE share_id IN (...) GROUP BY share_id, action
          const ids = new Set(args);
          const agg = new Map();
          for (const r of rows) {
            if (!ids.has(r.share_id)) continue;
            const k = r.share_id + " " + r.action;
            agg.set(k, (agg.get(k) || 0) + 1);
          }
          const results = [...agg.entries()].map(([k, c]) => {
            const [share_id, action] = k.split(" ");
            return { share_id, action, c };
          });
          return { results };
        }
        // liked: WHERE user_sub=? AND action='like' AND share_id IN (...)
        const sub = args[0], ids = new Set(args.slice(1));
        const results = rows
          .filter(r => r.user_sub === sub && r.action === "like" && ids.has(r.share_id))
          .map(r => ({ share_id: r.share_id }));
        return { results };
      },
    };
  }
  return { DB: { prepare: (sql) => stmt(sql), _rows: rows } };
}
```

- [ ] **Step 2: 写失败测试 `test/store.test.js`**

```javascript
import { describe, it, expect } from "vitest";
import { recordEngagement, countsFor, likedBy } from "../src/store.js";
import { fakeD1 } from "./fakes.js";

describe("recordEngagement", () => {
  it("view 重复只计一次(幂等)", async () => {
    const env = fakeD1();
    await recordEngagement(env, "s1", "u1", "view", undefined, 100);
    await recordEngagement(env, "s1", "u1", "view", undefined, 200);
    const c = await countsFor(env, ["s1"]);
    expect(c.s1.view).toBe(1);
  });

  it("不同用户的 view 各计一次", async () => {
    const env = fakeD1();
    await recordEngagement(env, "s1", "u1", "view", undefined, 100);
    await recordEngagement(env, "s1", "u2", "view", undefined, 100);
    const c = await countsFor(env, ["s1"]);
    expect(c.s1.view).toBe(2);
  });

  it("like on=true 计入,on=false 删除", async () => {
    const env = fakeD1();
    await recordEngagement(env, "s1", "u1", "like", true, 100);
    expect((await countsFor(env, ["s1"])).s1.like).toBe(1);
    await recordEngagement(env, "s1", "u1", "like", false, 100);
    expect((await countsFor(env, ["s1"])).s1?.like || 0).toBe(0);
  });
});

describe("likedBy", () => {
  it("只返回该用户赞过的 shareId", async () => {
    const env = fakeD1();
    await recordEngagement(env, "s1", "u1", "like", true, 100);
    await recordEngagement(env, "s2", "u2", "like", true, 100);
    const liked = await likedBy(env, "u1", ["s1", "s2"]);
    expect([...liked]).toEqual(["s1"]);
  });
});
```

- [ ] **Step 3: 跑测试确认失败**

Run: `cd ~/code/jianshuo.dev/reco && npm test -- store`
Expected: FAIL — `Cannot find module '../src/store.js'`。

- [ ] **Step 4: 写 `src/store.js`**

```javascript
const ACTIONS = new Set(["view", "finish", "like"]);

export async function recordEngagement(env, shareId, sub, action, on, now) {
  if (!ACTIONS.has(action)) return;
  if (action === "like" && on === false) {
    await env.DB.prepare(
      "DELETE FROM engagement WHERE share_id=? AND user_sub=? AND action='like'",
    ).bind(shareId, sub).run();
    return;
  }
  await env.DB.prepare(
    "INSERT OR IGNORE INTO engagement (share_id, user_sub, action, created_at) VALUES (?,?,?,?)",
  ).bind(shareId, sub, action, now).run();
}

export async function countsFor(env, shareIds) {
  const out = {};
  if (!shareIds.length) return out;
  const ph = shareIds.map(() => "?").join(",");
  const { results } = await env.DB.prepare(
    `SELECT share_id, action, COUNT(*) AS c FROM engagement WHERE share_id IN (${ph}) GROUP BY share_id, action`,
  ).bind(...shareIds).all();
  for (const r of results || []) {
    (out[r.share_id] ||= {})[r.action] = r.c;
  }
  return out;
}

export async function likedBy(env, sub, shareIds) {
  const set = new Set();
  if (!shareIds.length) return set;
  const ph = shareIds.map(() => "?").join(",");
  const { results } = await env.DB.prepare(
    `SELECT share_id FROM engagement WHERE user_sub=? AND action='like' AND share_id IN (${ph})`,
  ).bind(sub, ...shareIds).all();
  for (const r of results || []) set.add(r.share_id);
  return set;
}
```

- [ ] **Step 5: 跑测试确认通过**

Run: `cd ~/code/jianshuo.dev/reco && npm test -- store`
Expected: PASS。

- [ ] **Step 6: 提交**

```bash
cd ~/code/jianshuo.dev
git add reco/src/store.js reco/test/fakes.js reco/test/store.test.js
git commit -m "feat(reco): D1 engagement store + fake D1 for tests"
```

---

## Task 4: Worker 入口 + 路由(index.js)

**Files:**
- Create: `~/code/jianshuo.dev/reco/src/index.js`
- Test: `~/code/jianshuo.dev/reco/test/index.test.js`

**Interfaces:**
- Consumes: `resolveScope`(Task 2)、`recordEngagement`/`countsFor`/`likedBy`(Task 3)、`rankPosts`(Task 1)、`fakeD1`(Task 3 测试)。
- Produces: `default { fetch(request, env) }`。
  - `POST /reco/engage/<shareId>` body `{action, on?}` → `{ok:true[, liked]}`。
  - `POST /reco/rank` body `{posts:[{shareId,firstSharedAt,author,replyCount}]}` → `{order:[shareId...], liked:[shareId...]}`。

- [ ] **Step 1: 写失败测试 `test/index.test.js`**

```javascript
import { describe, it, expect } from "vitest";
import worker from "../src/index.js";
import { fakeD1 } from "./fakes.js";
import { hmacSign } from "../src/auth.js";

const SECRET = "test-secret";
function b64url(str) {
  return btoa(unescape(encodeURIComponent(str))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
async function token(scope) {
  const now = Math.floor(Date.now() / 1000);
  const h = b64url(JSON.stringify({ alg: "HS256", typ: "JWT" }));
  const p = b64url(JSON.stringify({ scope, apple: true, iat: now, exp: now + 3600 }));
  return `${h}.${p}.${await hmacSign(`${h}.${p}`, SECRET)}`;
}
function env(seed = []) { return { ...fakeD1(seed), SESSION_SECRET: SECRET }; }
function req(path, { method = "POST", body, auth } = {}) {
  return new Request("https://jianshuo.dev" + path, {
    method,
    headers: { ...(auth ? { Authorization: "Bearer " + auth } : {}), "Content-Type": "application/json" },
    body: body ? JSON.stringify(body) : undefined,
  });
}

describe("reco worker", () => {
  it("无 token → 401", async () => {
    const r = await worker.fetch(req("/reco/rank", { body: { posts: [] } }), env());
    expect(r.status).toBe(401);
  });

  it("engage view 写入,rank 把高互动帖排前", async () => {
    const e = env();
    const t = await token("users/u1/");
    await worker.fetch(req("/reco/engage/y", { body: { action: "like", on: true }, auth: t }), e);
    const now = Date.now();
    const posts = [
      { shareId: "x", firstSharedAt: now, author: "A", replyCount: 0 },
      { shareId: "y", firstSharedAt: now, author: "B", replyCount: 0 },
    ];
    const r = await worker.fetch(req("/reco/rank", { body: { posts }, auth: t }), e);
    const j = await r.json();
    expect(j.order[0]).toBe("y");
  });

  it("rank 返回我赞过的 shareId", async () => {
    const e = env();
    const t = await token("users/u1/");
    await worker.fetch(req("/reco/engage/z", { body: { action: "like", on: true }, auth: t }), e);
    const now = Date.now();
    const r = await worker.fetch(req("/reco/rank", {
      body: { posts: [{ shareId: "z", firstSharedAt: now, author: "A", replyCount: 0 }] }, auth: t,
    }), e);
    const j = await r.json();
    expect(j.liked).toContain("z");
  });

  it("env.DB 缺失 → rank 不崩,按输入序返回", async () => {
    const t = await token("users/u1/");
    const now = Date.now();
    const r = await worker.fetch(req("/reco/rank", {
      body: { posts: [{ shareId: "a", firstSharedAt: now, author: "A", replyCount: 0 }] }, auth: t,
    }), { SESSION_SECRET: SECRET });   // 没有 DB
    const j = await r.json();
    expect(j.order).toEqual(["a"]);
  });
});
```

- [ ] **Step 2: 跑测试确认失败**

Run: `cd ~/code/jianshuo.dev/reco && npm test -- index`
Expected: FAIL — `Cannot find module '../src/index.js'`。

- [ ] **Step 3: 写 `src/index.js`**

```javascript
import { resolveScope } from "./auth.js";
import { recordEngagement, countsFor, likedBy } from "./store.js";
import { rankPosts } from "./ranking.js";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET,POST,OPTIONS",
  "Access-Control-Allow-Headers": "Authorization,Content-Type",
};
const json = (obj, status = 200) =>
  new Response(JSON.stringify(obj), { status, headers: { "Content-Type": "application/json", ...CORS } });

const ID_RE = /^[0-9A-Za-z_-]{1,32}$/;

export default {
  async fetch(request, env) {
    if (request.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS });
    const url = new URL(request.url);
    const parts = url.pathname.split("/").filter(Boolean); // ['reco','engage','<id>'] | ['reco','rank']
    if (parts[0] !== "reco") return json({ error: "not found" }, 404);

    const token = (request.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
    const scope = await resolveScope(token, env.SESSION_SECRET);
    if (!scope) return json({ error: "unauthorized" }, 401);

    // POST /reco/engage/<shareId>
    if (request.method === "POST" && parts[1] === "engage" && parts[2]) {
      const shareId = parts[2];
      if (!ID_RE.test(shareId)) return json({ error: "bad id" }, 400);
      const body = await request.json().catch(() => ({}));
      const action = body.action;
      if (!["view", "finish", "like"].includes(action)) return json({ error: "bad action" }, 400);
      if (!env.DB) return json({ ok: true });   // D1 缺失 → no-op,绝不崩
      await recordEngagement(env, shareId, scope, action, body.on, Date.now());
      return json(action === "like" ? { ok: true, liked: body.on !== false } : { ok: true });
    }

    // POST /reco/rank
    if (request.method === "POST" && parts[1] === "rank") {
      const body = await request.json().catch(() => ({}));
      const posts = Array.isArray(body.posts) ? body.posts : [];
      if (!posts.length) return json({ order: [], liked: [] });
      if (!env.DB) return json({ order: posts.map((p) => p.shareId), liked: [] }); // 回退:保持输入序
      const ids = posts.map((p) => p.shareId);
      const [engMap, likedSet] = await Promise.all([countsFor(env, ids), likedBy(env, scope, ids)]);
      return json({ order: rankPosts(posts, engMap, Date.now()), liked: [...likedSet] });
    }

    return json({ error: "not found" }, 404);
  },
};
```

- [ ] **Step 4: 跑测试确认通过**

Run: `cd ~/code/jianshuo.dev/reco && npm test`
Expected: PASS(全部 4 个测试文件绿)。

- [ ] **Step 5: 提交**

```bash
cd ~/code/jianshuo.dev
git add reco/src/index.js reco/test/index.test.js
git commit -m "feat(reco): worker entry — engage + rank routes"
```

---

## Task 5: wrangler 配置 + D1 迁移 + README + 部署

**Files:**
- Create: `~/code/jianshuo.dev/reco/wrangler.jsonc`
- Create: `~/code/jianshuo.dev/reco/migrations/0001_engagement.sql`
- Create: `~/code/jianshuo.dev/reco/README.md`

- [ ] **Step 1: 写迁移 `migrations/0001_engagement.sql`**

```sql
CREATE TABLE IF NOT EXISTS engagement (
  share_id   TEXT NOT NULL,
  user_sub   TEXT NOT NULL,
  action     TEXT NOT NULL,          -- 'view' | 'finish' | 'like'
  created_at INTEGER NOT NULL,
  PRIMARY KEY (share_id, user_sub, action)
);
CREATE INDEX IF NOT EXISTS idx_engagement_share ON engagement(share_id);
```

- [ ] **Step 2: 建 D1 库**

Run: `cd ~/code/jianshuo.dev/reco && npx wrangler d1 create voicedrop-reco`
Expected: 输出一段 `database_id`。**记下它**,下一步填进 wrangler.jsonc。

- [ ] **Step 3: 写 `wrangler.jsonc`(把上一步的 database_id 填进去)**

```jsonc
{
  // VoiceDrop 社区推荐 sidecar。独立 Worker,自带 D1。不碰 R2、不反调核心。
  // 整个挂掉也不影响 VoiceDrop:app 会回退到核心 community/list 的时间序。
  "name": "voicedrop-reco",
  "main": "src/index.js",
  "compatibility_date": "2026-06-01",

  // 只接管 /reco/* 路径;Pages 仍服务其它一切。
  "routes": [
    { "pattern": "jianshuo.dev/reco/*", "zone_name": "jianshuo.dev" }
  ],
  // workers.dev 备用直连子域。
  "workers_dev": true,

  "d1_databases": [
    { "binding": "DB", "database_name": "voicedrop-reco", "database_id": "<上一步生成的 id>" }
  ]
  // Secret(wrangler secret put):
  //   SESSION_SECRET — 与核心 Pages 项目同值,用来独立验 token
}
```

- [ ] **Step 4: 建表 + 设 secret**

```bash
cd ~/code/jianshuo.dev/reco
npx wrangler d1 execute voicedrop-reco --remote --file=migrations/0001_engagement.sql
npx wrangler secret put SESSION_SECRET   # 粘贴与核心 Pages 项目相同的值
```
Expected: 迁移输出建表成功;secret 设置成功。

- [ ] **Step 5: 部署 + 冒烟**

```bash
cd ~/code/jianshuo.dev/reco
npx wrangler deploy
# 冒烟:无 token 应 401
curl -s -X POST https://jianshuo.dev/reco/rank -H 'Content-Type: application/json' -d '{"posts":[]}' -i | head -1
```
Expected: 部署成功;curl 返回 `HTTP/2 401`(无 token 被拒,证明路由+鉴权在线)。

- [ ] **Step 6: 写 `README.md`(canonical 文档)**

````markdown
# voicedrop-reco

VD社区的推荐排序 sidecar。**可随时拔掉**:整个 down 掉也不影响 VoiceDrop —— app 会回退到核心
`community/list` 的时间倒序。

## 它是什么
- 独立 Cloudflare Worker,路由 `jianshuo.dev/reco/*`。
- 自带一张 D1 表 `engagement`,记录 view/finish/like 三个互动信号(每用户去重)。
- 算一个「互动加权 × 年龄衰减」的全局顺序(千人一面)。
- **不碰 R2、不调用核心、无 Claude。** 唯一与核心共享的是 `SESSION_SECRET` 的值(独立验 token)。

## 路由
- `POST /reco/engage/<shareId>` body `{action:"view"|"finish"|"like", on?:bool}` → `{ok}`(like 另带 `{liked}`)。
- `POST /reco/rank` body `{posts:[{shareId,firstSharedAt,author,replyCount}]}` → `{order:[shareId...], liked:[shareId...]}`。
两者都要任意有效 token(anon 也行);失败 app 都会回退,不影响 feed。

## 数据模型(D1 `voicedrop-reco`)
engagement(share_id, user_sub, action, created_at),PK=(share_id,user_sub,action) → 天然去重。

## 排序
`score = (1 + view*1 + finish*4 + like*3 + reply*5) / (ageHours + 2)^1.5`,再做作者打散(同作者每多出现一次分 ×0.5)。权重见 `src/ranking.js` 的 `W`,可调。

## 开发 / 部署
- 测试:`npm test`(纯函数 + fake D1,不连真 D1)。
- 部署:`npx wrangler deploy`。
- 改表:加 `migrations/000N_*.sql`,`npx wrangler d1 execute voicedrop-reco --remote --file=...`。
- Secret:`npx wrangler secret put SESSION_SECRET`(与核心同值)。
````

- [ ] **Step 7: 提交**

```bash
cd ~/code/jianshuo.dev
git add reco/wrangler.jsonc reco/migrations/0001_engagement.sql reco/README.md
git commit -m "feat(reco): wrangler config, D1 migration, README; deployed"
```

---

## Task 6: iOS — CommunityStore 接 reco(engage + rank + 回退)

**Files:**
- Modify: `~/code/voicedrop/VoiceDropApp/Community.swift`(`CommunityStore`,行 32–185 区域)

**Interfaces:**
- Consumes: reco `POST /reco/rank`、`POST /reco/engage/<id>`。
- Produces:
  - `CommunityStore.likedShareIds: Set<String>` — rank 回来后填充,❤️ 初值。
  - `CommunityStore.engage(_ shareId:String, action:String, on:Bool?)` — fire-and-forget。
  - `load()` 改为:list → rank 重排(失败保持时间序)。

- [ ] **Step 1: 加 reco base + likedShareIds 字段**

在 `CommunityStore`(`private let base = …` 附近,约行 37)加:

```swift
    private let recoBase = URL(string: "https://jianshuo.dev/reco")!
    var likedShareIds: Set<String> = []
```

- [ ] **Step 2: 在 `load()` 末尾接 rank 重排**

把现有 `load()`(行 41–53)的结尾,从:

```swift
            posts = try JSONDecoder().decode(R.self, from: data).posts
        } catch { self.error = error.localizedDescription }
    }
```

改为(解码后追加 rank;rank 失败则保持时间序):

```swift
            posts = try JSONDecoder().decode(R.self, from: data).posts
            await applyRanking()
        } catch { self.error = error.localizedDescription }
    }

    /// 问 reco 怎么排;成功就重排 posts 并记下我赞过的。失败/超时 → 保持时间序。
    private func applyRanking() async {
        guard !posts.isEmpty, !token.isEmpty else { return }
        let replyCounts = posts.reduce(into: [String: Int]()) { acc, p in
            if let to = p.replyTo { acc[to, default: 0] += 1 }
        }
        let payload = posts.map { p -> [String: Any] in
            ["shareId": p.shareId,
             "firstSharedAt": p.firstSharedAt ?? 0,
             "author": p.author ?? "",
             "replyCount": replyCounts[p.shareId] ?? 0]
        }
        var req = URLRequest(url: recoBase.appending(path: "rank"))
        req.httpMethod = "POST"
        req.timeoutInterval = 2   // 超时即回退
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["posts": payload])
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true else { return }
            struct R: Decodable { let order: [String]; let liked: [String] }
            let r = try JSONDecoder().decode(R.self, from: data)
            likedShareIds = Set(r.liked)
            let byId = Dictionary(uniqueKeysWithValues: posts.map { ($0.shareId, $0) })
            let reordered = r.order.compactMap { byId[$0] }
            if reordered.count == posts.count { posts = reordered }  // 只在完整覆盖时替换
        } catch { /* 回退:保持时间序 */ }
    }
```

- [ ] **Step 3: 加 `engage()`(fire-and-forget)**

在 `CommunityStore` 里(如 `photoData` 附近)加:

```swift
    /// 上报一次互动。失败静默忽略 —— reco down 时不影响核心体验。
    func engage(_ shareId: String, action: String, on: Bool? = nil) async {
        guard !token.isEmpty else { return }
        var req = URLRequest(url: recoBase.appending(path: "engage").appending(path: shareId))
        req.httpMethod = "POST"
        req.timeoutInterval = 3
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["action": action]
        if let on { body["on"] = on }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: req)
    }
```

- [ ] **Step 4: 编译验证**

Run: `cd ~/code/voicedrop && xcodegen generate && xcodebuild -scheme VoiceDrop -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`。

- [ ] **Step 5: 提交**

```bash
cd ~/code/voicedrop
git add VoiceDropApp/Community.swift
git commit -m "feat(ios): community feed asks reco for order, falls back to time-sort"
```

---

## Task 7: iOS — 详情页 view/finish 上报 + ❤️ 按钮

**Files:**
- Modify: `~/code/voicedrop/VoiceDropApp/Community.swift`(`CommunityPostView`,行 198–312 区域)

**Interfaces:**
- Consumes: `CommunityStore.engage`、`CommunityStore.likedShareIds`(Task 6)。

- [ ] **Step 1: 加 ❤️ 本地状态**

在 `CommunityPostView` 的 `@State` 区(约行 214,`@State private var toast` 附近)加:

```swift
    @State private var liked = false
    @State private var finishedReported = false
```

- [ ] **Step 2: 进帖上报 view + 初始化 liked**

在 `body` 的 `.task { … }`(行 271–279)**开头**加 view 上报与 liked 初值:

```swift
        .task {
            liked = store.likedShareIds.contains(post.shareId)
            await store.engage(post.shareId, action: "view")
            full = await store.fetchPost(post.shareId)
```
(其余 `.task` 内容不变。)

- [ ] **Step 3: 正文底加 finish 哨兵**

在 ScrollView 的 `VStack`(行 237–253)里,`repliesSection` 之后、`VStack` 闭合前,加一个哨兵——滚到这儿 = 看完:

```swift
                        repliesSection
                        Color.clear.frame(height: 1)
                            .onAppear {
                                guard !finishedReported else { return }
                                finishedReported = true
                                Task { await store.engage(post.shareId, action: "finish") }
                            }
```

- [ ] **Step 4: nav bar 加 ❤️ 按钮**

在 `navBar`(行 285–312)的 `Spacer()` 与 `Menu` 之间插入一个心形按钮(实心/空心,无计数):

```swift
            Spacer()
            Button {
                liked.toggle()
                Task { await store.engage(post.shareId, action: "like", on: liked) }
            } label: {
                Image(systemName: liked ? "heart.fill" : "heart")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(liked ? Theme.accent : Theme.inkRead)
                    .frame(width: 38, height: 38)
            }
            .accessibilityLabel(liked ? "取消赞" : "赞")
            Menu {
```
(原 `Spacer()` 保留;`Menu` 原样接在后面。)

- [ ] **Step 5: 编译验证**

Run: `cd ~/code/voicedrop && xcodegen generate && xcodebuild -scheme VoiceDrop -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`。

- [ ] **Step 6: 手动冒烟(模拟器或真机)**

1. 打开一个社区帖 → reco D1 里应出现一条 `view` 行(`npx wrangler d1 execute voicedrop-reco --remote --command "SELECT * FROM engagement"`)。
2. 滚到文底 → 出现 `finish` 行。
3. 点 ❤️ → 出现 `like` 行;再点 → 消失。
4. 杀掉 reco(或断网)再刷社区 → feed 仍正常显示(时间序),不报错。

- [ ] **Step 7: 提交**

```bash
cd ~/code/voicedrop
git add VoiceDropApp/Community.swift
git commit -m "feat(ios): report view/finish on community post + like heart button"
```

---

## Task 8: 更新 STATE.md 指针

**Files:**
- Modify: `~/code/voicedrop/STATE.md`

- [ ] **Step 1: 在 Community 段落后加一小节**

在 STATE.md「## Community (VD社区)」段末尾追加:

```markdown
### 推荐排序 sidecar — voicedrop-reco(2026-06-26)

社区 feed 的排序由一个**独立、可随时拔掉**的 Worker `voicedrop-reco`(`~/code/jianshuo.dev/reco/`)
负责。canonical 文档 = `reco/README.md`。要点:
- 核心 `community/list` **零改动**(仍按 firstSharedAt 倒序)。app 拿到 list 后再问 reco
  `POST /reco/rank` 要顺序;**reco 挂/超时(2s)→ app 回退时间序**,feed 照常。
- reco 自带 D1 表 `engagement`(view/finish/like,每用户去重),算
  `(1 + view·1+finish·4+like·3+reply·5)/(ageHours+2)^1.5` + 作者打散。
- 互动上报:详情页进帖→view、滚到文底→finish、❤️→like(`POST /reco/engage/<shareId>`,fire-and-forget)。
  ❤️ **不显示计数**,只反映"我赞过没"。
- reco **不碰 R2、不反调核心**,仅共享 `SESSION_SECRET` 值独立验 token。部署独立:
  `cd ~/code/jianshuo.dev/reco && npx wrangler deploy`。
- **token 计费未做**:将来单独 spec + 单独 D1 库 `voicedrop-usage`,不进 engagement、不进 reco。
```

- [ ] **Step 2: 提交**

```bash
cd ~/code/voicedrop
git add STATE.md
git commit -m "docs: STATE.md pointer to voicedrop-reco ranking sidecar"
```

---

## Self-Review(已核对)

- **Spec 覆盖**:§1 架构→Task 1/4/5;§2 D1 表→Task 5;§3 路由→Task 4;§4 排序→Task 1;§5 iOS→Task 6/7;§6 测试→各任务 TDD;§7 部署→Task 5/6/7;§0 自带文档→Task 5 README + Task 8 STATE 指针。
- **类型一致**:`postScore(eng, replyCount, firstSharedAt, now)` / `rankPosts(posts, engMap, now)→string[]` / `resolveScope(token, secret)` / `recordEngagement(env, shareId, sub, action, on, now)` / `countsFor(env, ids)→{[id]:{view,finish,like}}` / `likedBy(env, sub, ids)→Set` 在各任务间一致。rank 返回 `{order, liked}`,iOS 解码同名。
- **无占位**:每步含完整代码 / 确切命令 / 期望输出。
- **隔离**:全程不改核心 `[[path]].js`,Task 5/6/7 部署互不依赖,reco 可独立拔除。
```
