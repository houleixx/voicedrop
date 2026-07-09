# 邀请奖励（Referral Rewards）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 新装用户 24h 内经「universal link 回点 > IP 指纹 > 剪贴板兜底」三层归因到分享作者，双方按币记价（作者 12 币/新人 6 币）、入账时刻池子实时汇率折算力入账。

**Architecture:** 复用现有铸币经济——mint 表加 `kind='referral'` 事件（唯一索引天然防重），钱走 grantBucket 分桶账本（90 天过期）；归因数据 = Pages 落地页写 R2 `refhits/`（IP 哈希）+ 分享短链自带 owner；防刷 = account.created_at 判新 + DeviceCheck 两 bit + owner 日封顶。Pages 落地页加 CTA（实时汇率经 R2 `config/mint-rate.json` 读取）+ 下载按钮写剪贴板。iOS 新增 ReferralManager 跑归因序列。

**Tech Stack:** Cloudflare Worker (voicedrop-agent, D1+R2) · Cloudflare Pages Functions · SwiftUI/DeviceCheck · vitest

## Global Constraints

- 面额/开关存 R2 `config/referral.json`：`{enabled:true, authorCoins:12, newUserCoins:6, dailyCapPerOwner:10, requireDeviceCheck:true}`（零部署可调）。
- 铸币公式与投币完全同池：`payout_uy = coins_uc × POOL_7D_UY ÷ (SEED_COINS_UC + 近7天全表铸币 + 本次)`；共享 `FUSE_MULT` 当日保险丝。
- 账本 reason：`referral_author`（邀请奖励）/ `referral_new`（受邀赠送）；过期 `CAMPAIGN_EXPIRE_DAYS = 90` 天。
- 判新：`account.created_at` 距 now < 24h（服务端时间，不信客户端）。
- 每账号一生一次：mint 唯一索引 `(kind='referral', subject_key=新账号sub, actor_sub=新账号sub)`。
- owner 日封顶只砍作者侧发放，新用户照发（对新人公平；spec 措辞「照常归因但不发币」按此落地）。
- IP 归因宁漏不错：24h 窗口内 refhits 出现 >1 个 owner → 放弃。
- 不存明文 IP：`ipHash = hmacSign(ip, SESSION_SECRET).slice(0,16)`。
- universal link / AASA / entitlements **已上线**（TEAMID 97XBW2A43H，App Store id 6781565141），本计划不动它们。
- worker 测试：`cd ~/code/jianshuo.dev/agent && npm test`（改前改后都跑）。
- 部署顺序：Pages 先（refhits+CTA 对老 App 无害）→ worker → iOS。

---

### Task 1: 常量 + 中文账单名（usage.js）

**Files:**
- Modify: `~/code/jianshuo.dev/agent/src/usage.js`（REASON_ZH 表附近，约 :86-102）
- Test: `~/code/jianshuo.dev/agent/test/referral.test.js`（新建，先只放 reason 用例）

**Interfaces:**
- Produces: `REASON_ZH["referral_author"]`、`REASON_ZH["referral_new"]`；常量 `REFERRAL_DEFAULTS`。

- [ ] **Step 1: 写失败测试**

```js
// test/referral.test.js — 邀请奖励：中文账单名 + 配置默认值
import { describe, it, expect } from "vitest";
import { REASON_ZH, REFERRAL_DEFAULTS } from "../src/usage.js";

describe("referral constants", () => {
  it("has Chinese ledger names", () => {
    expect(REASON_ZH["referral_author"]).toBe("邀请奖励");
    expect(REASON_ZH["referral_new"]).toBe("受邀赠送");
  });
  it("has defaults", () => {
    expect(REFERRAL_DEFAULTS).toEqual({
      enabled: true, authorCoins: 12, newUserCoins: 6,
      dailyCapPerOwner: 10, requireDeviceCheck: true,
    });
  });
});
```

- [ ] **Step 2: 跑测试确认失败** — `cd ~/code/jianshuo.dev/agent && npx vitest run test/referral.test.js`，期望 FAIL（REFERRAL_DEFAULTS undefined）。

- [ ] **Step 3: 实现** — usage.js 的 `REASON_ZH` 加两行：

```js
  "referral_author": "邀请奖励",
  "referral_new":    "受邀赠送",
```

投币常量区（`pairDiscount` 之后）加：

```js
// ── 邀请奖励（referral，币记价，与投币同池同价）────────────────────────────
// R2 config/referral.json 整体覆盖这些默认值（零部署调价/关闸）。
export const REFERRAL_DEFAULTS = {
  enabled: true,
  authorCoins: 12,        // 作者（分享 owner）得币
  newUserCoins: 6,        // 新装用户得币
  dailyCapPerOwner: 10,   // owner 每日被奖励安装数上限（超出只发新人侧）
  requireDeviceCheck: true,
};
```

- [ ] **Step 4: 跑测试确认通过**，再跑全量 `npm test` 无回归。
- [ ] **Step 5: Commit** — `feat(referral): 账单中文名与默认配置常量`

---

### Task 2: refhits 共享库（Pages 与 worker 共用）

**Files:**
- Create: `~/code/jianshuo.dev/functions/lib/refhits.js`
- Test: `~/code/jianshuo.dev/agent/test/refhits.test.js`

**Interfaces:**
- Consumes: `hmacSign` from `functions/lib/auth.js`。
- Produces: `ipHash(ip, secret)` → Promise<16-char string>；`refhitKey(hash, ts)` → `refhits/<hash>/<ts>`；`writeRefhit(env, ip, secret, owner, token, ts)`；`lookupRefhit(env, ip, secret, now)` → `{owner, token} | null`（24h 窗口，owner 唯一才返回）。

- [ ] **Step 1: 写失败测试**

```js
// test/refhits.test.js — IP 指纹归因：写入 + 唯一匹配查询
import { describe, it, expect, beforeEach } from "vitest";
import { fakeEnv } from "./fakes.js";
import { ipHash, writeRefhit, lookupRefhit } from "../../functions/lib/refhits.js";

const SECRET = "test-secret";
const NOW = 1800000000000;
let env;
beforeEach(() => { env = fakeEnv(); });

describe("refhits", () => {
  it("hashes ip, no plaintext", async () => {
    const h = await ipHash("1.2.3.4", SECRET);
    expect(h).toHaveLength(16);
    expect(h).not.toContain(".");
  });
  it("lookup finds unique owner within 24h", async () => {
    await writeRefhit(env, "1.2.3.4", SECRET, "users/anon-a/", "tokA", NOW - 3600_000);
    const hit = await lookupRefhit(env, "1.2.3.4", SECRET, NOW);
    expect(hit).toEqual({ owner: "users/anon-a/", token: "tokA" });
  });
  it("returns null when two owners share the ip (CGNAT — 宁漏不错)", async () => {
    await writeRefhit(env, "1.2.3.4", SECRET, "users/anon-a/", "tokA", NOW - 3600_000);
    await writeRefhit(env, "1.2.3.4", SECRET, "users/anon-b/", "tokB", NOW - 1800_000);
    expect(await lookupRefhit(env, "1.2.3.4", SECRET, NOW)).toBeNull();
  });
  it("ignores hits older than 24h and other ips", async () => {
    await writeRefhit(env, "1.2.3.4", SECRET, "users/anon-a/", "tokA", NOW - 25 * 3600_000);
    await writeRefhit(env, "5.6.7.8", SECRET, "users/anon-b/", "tokB", NOW - 3600_000);
    expect(await lookupRefhit(env, "1.2.3.4", SECRET, NOW)).toBeNull();
  });
  it("same owner twice still matches (not ambiguous)", async () => {
    await writeRefhit(env, "1.2.3.4", SECRET, "users/anon-a/", "tokA", NOW - 3600_000);
    await writeRefhit(env, "1.2.3.4", SECRET, "users/anon-a/", "tokB", NOW - 1800_000);
    const hit = await lookupRefhit(env, "1.2.3.4", SECRET, NOW);
    expect(hit && hit.owner).toBe("users/anon-a/");
  });
});
```

注意：`fakes.js` 的 `fakeEnv` 需要 FILES.list 支持 prefix——先读 `test/fakes.js` 确认；不支持就在 fakes.js 里补最小实现（返回 `{objects:[{key}]}` 按前缀过滤），别在测试里造私有 fake。

- [ ] **Step 2: 跑测试确认失败**（模块不存在）。
- [ ] **Step 3: 实现**

```js
// functions/lib/refhits.js — 落地页访问的 IP 指纹记录（邀请归因第 2 层）。
// 键 refhits/<ipHash>/<ts>，值 {owner, token, ts}。不存明文 IP（HMAC 后截断）。
// R2 lifecycle 对 refhits/ 前缀设 2 天过期（部署清单里用 wrangler 配，代码不管）。
import { hmacSign } from "./auth.js";

const DAY_MS = 86400000;

export async function ipHash(ip, secret) {
  return (await hmacSign(String(ip || ""), secret)).slice(0, 16);
}

export async function writeRefhit(env, ip, secret, owner, token, ts) {
  if (!ip || !secret || !owner) return;
  const h = await ipHash(ip, secret);
  await env.FILES.put(`refhits/${h}/${ts}`, JSON.stringify({ owner, token, ts }));
}

// 24h 窗口内该 IP 访问过的分享页：owner 唯一 → {owner, token}；0 个或多个 → null。
export async function lookupRefhit(env, ip, secret, now) {
  if (!ip || !secret) return null;
  const h = await ipHash(ip, secret);
  const listed = await env.FILES.list({ prefix: `refhits/${h}/` });
  const owners = new Map(); // owner → latest {owner, token}
  for (const o of listed.objects || []) {
    const ts = parseInt(o.key.slice(o.key.lastIndexOf("/") + 1), 10);
    if (!Number.isFinite(ts) || now - ts > DAY_MS || ts > now + 60000) continue;
    const obj = await env.FILES.get(o.key);
    if (!obj) continue;
    let rec; try { rec = JSON.parse(await obj.text()); } catch { continue; }
    if (!rec || !rec.owner) continue;
    const prev = owners.get(rec.owner);
    if (!prev || rec.ts > prev.ts) owners.set(rec.owner, rec);
  }
  if (owners.size !== 1) return null;
  const rec = owners.values().next().value;
  return { owner: rec.owner, token: rec.token || null };
}
```

- [ ] **Step 4: 跑测试确认通过**。
- [ ] **Step 5: Commit** — `feat(referral): refhits IP 指纹库（写入+唯一匹配查询）`

---

### Task 3: DeviceCheck 客户端（worker 侧）

**Files:**
- Create: `~/code/jianshuo.dev/agent/src/devicecheck.js`
- Test: `~/code/jianshuo.dev/agent/test/devicecheck.test.js`

**Interfaces:**
- Consumes: worker secrets `APNS_KEY_P8` / `APNS_KEY_ID` / `APNS_TEAM_ID`（与 push.js 同一把 .p8——ES256 JWT 结构一致；**部署清单里验证这把 key 是否开了 DeviceCheck 服务**，没开就在 Apple Developer 后台新建一把开 DeviceCheck 的 key，加 secrets `DC_KEY_P8`/`DC_KEY_ID`，代码里 `env.DC_KEY_P8 || env.APNS_KEY_P8` 兜底）。
- Produces: `deviceCheckGate(env, dcToken, fetcher?)` → `"fresh" | "used" | "unavailable"`；`deviceCheckMark(env, dcToken, fetcher?)` → boolean。`fetcher` 参数注入 fetch 供测试。

- [ ] **Step 1: 写失败测试**

```js
// test/devicecheck.test.js — DeviceCheck 两 bit 防重装（fetch 注入，不打真 Apple）
import { describe, it, expect } from "vitest";
import { deviceCheckGate, deviceCheckMark } from "../src/devicecheck.js";

// push.js 同款 P-256 测试私钥：随便一把合法 pkcs8 test key（仅测 JWT 组装不验签）
const TEST_P8 = `-----BEGIN PRIVATE KEY-----
MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgevZzL1gdAFr88hb2
OF/2NxApJCzGCEDdfSp6VQO30hyhRANCAAQRWz+jn65BtOMvdyHKcvjBeBSDZH2r
1RTwjmYSi9R/zpBnuQ4EiMnCqfMPWiZqB4QdbAd0E7oH50VpuZ1P087G
-----END PRIVATE KEY-----`;

const envOk = { APNS_KEY_P8: TEST_P8, APNS_KEY_ID: "KEYID12345", APNS_TEAM_ID: "97XBW2A43H" };

describe("deviceCheckGate", () => {
  it("unavailable when secrets missing", async () => {
    expect(await deviceCheckGate({}, "tok")).toBe("unavailable");
  });
  it("unavailable when no device token", async () => {
    expect(await deviceCheckGate(envOk, "")).toBe("unavailable");
  });
  it("fresh when bits never set", async () => {
    const fetcher = async () => new Response("Failed to find bit state", { status: 200 });
    expect(await deviceCheckGate(envOk, "tok", fetcher)).toBe("fresh");
  });
  it("fresh when bit0 false", async () => {
    const fetcher = async () => Response.json({ bit0: false, bit1: false });
    expect(await deviceCheckGate(envOk, "tok", fetcher)).toBe("fresh");
  });
  it("used when bit0 already set", async () => {
    const fetcher = async () => Response.json({ bit0: true, bit1: false });
    expect(await deviceCheckGate(envOk, "tok", fetcher)).toBe("used");
  });
  it("unavailable on api error", async () => {
    const fetcher = async () => new Response("bad", { status: 500 });
    expect(await deviceCheckGate(envOk, "tok", fetcher)).toBe("unavailable");
  });
  it("mark posts update_two_bits with bit0 true", async () => {
    let sent = null;
    const fetcher = async (url, init) => { sent = { url, body: JSON.parse(init.body) }; return new Response("", { status: 200 }); };
    expect(await deviceCheckMark(envOk, "tok", fetcher)).toBe(true);
    expect(sent.url).toContain("update_two_bits");
    expect(sent.body.bit0).toBe(true);
  });
});
```

- [ ] **Step 2: 跑测试确认失败**。
- [ ] **Step 3: 实现**

```js
// src/devicecheck.js — Apple DeviceCheck 两 bit：跨删除重装持久的「此设备已领过」标记。
// bit0 = 已领过邀请奖励。ES256 JWT 与 push.js 同构（iss=team, kid=key）；key 复用
// APNS 那把 .p8（DC_KEY_* secrets 存在则优先——万一 APNs key 没开 DeviceCheck 服务）。
// 一律 fail-safe：拿不到明确答案返回 "unavailable"，由调用方按配置决定放行或拒绝。
const DC_HOST = "https://api.devicecheck.apple.com"; // TestFlight/App Store 构建走生产

let jwtCache = { token: null, exp: 0, keyId: null };

function pemToPkcs8(pem) {
  const b64 = pem.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  const raw = atob(b64);
  const buf = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) buf[i] = raw.charCodeAt(i);
  return buf.buffer;
}
const b64url = (buf) =>
  btoa(String.fromCharCode(...new Uint8Array(buf))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

function creds(env) {
  const p8 = env.DC_KEY_P8 || env.APNS_KEY_P8;
  const kid = env.DC_KEY_ID || env.APNS_KEY_ID;
  const team = env.APNS_TEAM_ID;
  return p8 && kid && team ? { p8, kid, team } : null;
}

async function dcJwt(c) {
  const now = Math.floor(Date.now() / 1000);
  if (jwtCache.token && jwtCache.exp > now + 300 && jwtCache.keyId === c.kid) return jwtCache.token;
  const key = await crypto.subtle.importKey(
    "pkcs8", pemToPkcs8(c.p8), { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const header = b64url(new TextEncoder().encode(JSON.stringify({ alg: "ES256", kid: c.kid })));
  const payload = b64url(new TextEncoder().encode(JSON.stringify({ iss: c.team, iat: now })));
  const sig = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(`${header}.${payload}`));
  const token = `${header}.${payload}.${b64url(sig)}`;
  jwtCache = { token, exp: now + 2400, keyId: c.kid };
  return token;
}

async function dcPost(c, path, body, fetcher) {
  return (fetcher || fetch)(`${DC_HOST}/v1/${path}`, {
    method: "POST",
    headers: { authorization: `Bearer ${await dcJwt(c)}`, "content-type": "application/json" },
    body: JSON.stringify(body),
  });
}

export async function deviceCheckGate(env, dcToken, fetcher) {
  try {
    const c = creds(env);
    if (!c || !dcToken) return "unavailable";
    const resp = await dcPost(c, "query_two_bits",
      { device_token: dcToken, transaction_id: crypto.randomUUID(), timestamp: Date.now() }, fetcher);
    if (resp.status !== 200) return "unavailable";
    const text = await resp.text();
    if (/Failed to find bit state/i.test(text)) return "fresh"; // 该设备从未置过位
    let bits; try { bits = JSON.parse(text); } catch { return "unavailable"; }
    return bits && bits.bit0 === true ? "used" : "fresh";
  } catch (e) {
    console.error("[devicecheck] query failed:", e && e.message);
    return "unavailable";
  }
}

export async function deviceCheckMark(env, dcToken, fetcher) {
  try {
    const c = creds(env);
    if (!c || !dcToken) return false;
    const resp = await dcPost(c, "update_two_bits",
      { device_token: dcToken, transaction_id: crypto.randomUUID(), timestamp: Date.now(), bit0: true, bit1: false }, fetcher);
    return resp.status === 200;
  } catch (e) {
    console.error("[devicecheck] update failed:", e && e.message);
    return false;
  }
}
```

- [ ] **Step 4: 跑测试确认通过**。
- [ ] **Step 5: Commit** — `feat(referral): DeviceCheck 两 bit 防重装客户端`

---

### Task 4: referral.js — 配置、报价、claim 路由（核心）

**Files:**
- Create: `~/code/jianshuo.dev/agent/src/referral.js`
- Modify: `~/code/jianshuo.dev/agent/src/index.js`（`handleMintRoutes` 调用处 :1279 旁加一行）
- Test: `~/code/jianshuo.dev/agent/test/referral.test.js`（追加）

**Interfaces:**
- Consumes: `grantBucket`/`ensureAccount`（usage_store.js）、`REFERRAL_DEFAULTS, POOL_7D_UY, SEED_COINS_UC, DAILY_POOL_UY, FUSE_MULT, CAMPAIGN_EXPIRE_DAYS, DAY_MS, expiryAfterDays, uyToSuanli`（usage.js）、`lookupRefhit`（refhits.js）、`deviceCheckGate/deviceCheckMark`（devicecheck.js）、`verifySession, anonScopeFromToken, bearerToken`（auth.js）、`isShareId, communityKey`（community-store.js）。
- Produces: `handleReferralRoutes(url, request, env, fetcher?)`（`/agent/referral/claim` 非命中返回 null）；`referralQuote(sumUC, authorUC, newUC)`；`loadReferralConfig(env)`；`publishMintRate(env, db, now)`（写 R2 `config/mint-rate.json` `{suanliPerCoin, updatedAt}`）。
- API 契约（iOS 用）：`POST /agent/referral/claim` body `{source:"link"|"clipboard"|"hello", token?, deviceCheckToken?}` → 200 `{attributed:true, already?:true, suanli?:{you,author}}` 或 `{attributed:false, reason:"disabled"|"not-new"|"no-match"|"self"|"device-used"|"device-unavailable"|"pool_exhausted"}`。

- [ ] **Step 1: 写失败测试**（追加进 test/referral.test.js；套 mint.test.js 的骨架：`fakeD1(usageSql())`、`makeToken`、fakeEnv 种子 `shares/<id>` 与 `community/<id>.json`）

核心用例（每个都是独立 it）：
1. **报价数学**：`referralQuote(0, 12e6, 6e6)` → 分母 = 70e6+18e6，author ≈ `floor(12e6×POOL_7D_UY/88e6)`，new 侧同式；冷启动价 = `POOL_7D_UY/88` 微元/币。
2. **link claim 成功**：新账号（先 `ensureAccount(db, NEW, NOW - 3600_000)`）带 shares token claim → 200 `{attributed:true}`；`balanceUY(db, OWNER)` 增加 author 侧、`balanceUY(db, NEW)` 增加 new 侧 + signup；ledger reason 分别为 `referral_author`/`referral_new`；bucket expires_at ≈ NOW+90 天；mint 表出现 kind='referral' 行；R2 出现 `config/mint-rate.json`。
3. **幂等**：同一账号第二次 claim → `{attributed:true, already:true}`，余额不再变。
4. **不新拒绝**：`ensureAccount` 于 NOW-25h → `{attributed:false, reason:"not-new"}`。
5. **自邀拒绝**：owner 自己 claim 自己的 token → `reason:"self"`。
6. **hello 走 IP**：先 `writeRefhit(env, ip, SECRET, OWNER, tok, NOW-3600_000)`，request 带 `CF-Connecting-IP` 头 → attributed；同 IP 两个 owner → `reason:"no-match"`。
7. **DeviceCheck**：`requireDeviceCheck:true`（默认）时 fetcher 返回 bit0=true → `reason:"device-used"` 且不付钱；R2 放 `config/referral.json` `{requireDeviceCheck:false}` 时无 dcToken 也能领。
8. **日封顶**：owner 当日已有 10 行 kind='referral' 的 mint（用 insertMint 手插，benef=OWNER, ts=当日）→ 新 claim 仍 attributed、新人得钱、**owner 得 0**（balance 不变，无 referral_author ledger 行）。
9. **保险丝**：当日已发放 > FUSE_MULT×DAILY_POOL_UY（insertMint 大额）→ `reason:"pool_exhausted"`。
10. **community token 也解析**：token 为社区 shareId（community/<id>.json）→ attributed 给 post.owner。
11. **disabled**：R2 `config/referral.json` `{enabled:false}` → `reason:"disabled"`。

DeviceCheck 的 fetcher 经 `handleReferralRoutes(url, req, env, fetcher)` 第 4 参注入；测试默认给「永远 fresh + mark 成功」的 fetcher。

- [ ] **Step 2: 跑测试确认失败**。
- [ ] **Step 3: 实现**

```js
// src/referral.js — 邀请奖励：新装归因（link/clipboard token 或 hello IP 指纹）+
// 双边铸币入账。事件进 mint 表 kind='referral'（subject_key = 新账号 sub，唯一索引
// 天然「每账号一生一次」）；钱走 grantBucket（referral_author / referral_new，90 天过期）；
// 价格与投币同池同式（sumCoins7d 全表无 kind 过滤 = 同一个分母）。
import { verifySession, anonScopeFromToken, bearerToken } from "../../functions/lib/auth.js";
import { isShareId, communityKey } from "../../functions/lib/community-store.js";
import { lookupRefhit } from "../../functions/lib/refhits.js";
import { grantBucket, ensureAccount } from "./usage_store.js";
import { deviceCheckGate, deviceCheckMark } from "./devicecheck.js";
import {
  REFERRAL_DEFAULTS, POOL_7D_UY, SEED_COINS_UC, DAILY_POOL_UY, FUSE_MULT,
  CAMPAIGN_EXPIRE_DAYS, DAY_MS, expiryAfterDays, uyToSuanli,
} from "./usage.js";

const J = (x, status = 200) => new Response(JSON.stringify(x), { status, headers: { "content-type": "application/json" } });
const r1 = (n) => Math.round(n * 10) / 10;
const no = (reason) => J({ attributed: false, reason });

export function referralQuote(sumUC, authorUC, newUC) {
  const denomUC = SEED_COINS_UC + sumUC + authorUC + newUC;
  const beneficiaryUY = Math.floor((authorUC * POOL_7D_UY) / denomUC);
  const actorUY = Math.floor((newUC * POOL_7D_UY) / denomUC);
  const priceUY = Math.floor(POOL_7D_UY / (denomUC / 1e6));
  return { denomUC, beneficiaryUY, actorUY, priceUY };
}

export async function loadReferralConfig(env) {
  try {
    const obj = await env.FILES.get("config/referral.json");
    if (obj) return { ...REFERRAL_DEFAULTS, ...JSON.parse(await obj.text()) };
  } catch (e) { console.error("[referral] bad config/referral.json:", e && e.message); }
  return { ...REFERRAL_DEFAULTS };
}

// 落地页 CTA 的实时汇率（Pages 读同一 bucket，不跨服务调用）。尽力而为，失败不抛。
export async function publishMintRate(env, db, now) {
  try {
    const sumUC = (await db.prepare("SELECT COALESCE(SUM(coins_uc),0) AS s FROM mint WHERE ts>?")
      .bind(now - 7 * DAY_MS).first()).s;
    const priceUY = Math.floor(POOL_7D_UY / ((SEED_COINS_UC + sumUC) / 1e6));
    await env.FILES.put("config/mint-rate.json",
      JSON.stringify({ suanliPerCoin: r1(uyToSuanli(priceUY)), updatedAt: now }));
  } catch (e) { console.error("[referral] publishMintRate failed:", e && e.message); }
}

// token（分享短链 id）→ owner scope。shares/<id> 的值是 articleKey；社区 id 读指针。
async function ownerFromToken(env, token) {
  const id = String(token || "").trim();
  if (!/^[A-Za-z0-9_-]{6,16}$/.test(id)) return null;
  let key = null;
  const map = await env.FILES.get(`shares/${id}`);
  if (map) key = await map.text();
  else if (isShareId(id)) {
    const cm = await env.FILES.get(communityKey(id));
    if (cm) { try { key = JSON.parse(await cm.text()).articleKey || null; } catch {} }
  }
  const m = key && key.match(/^(users\/[^/]+\/)/);
  return m ? m[1] : null;
}

export async function handleReferralRoutes(url, request, env, fetcher) {
  if (url.pathname !== "/agent/referral/claim" || request.method !== "POST") return null;
  if (!env.USAGE) return J({ error: "usage-unavailable" }, 503);
  try {
    // 新用户就是匿名用户：anon token 与 Apple session 都接受。
    const tok = bearerToken(request);
    let scope = null;
    if (env.SESSION_SECRET) { const s = await verifySession(tok, env.SESSION_SECRET); if (s) scope = s.scope; }
    if (!scope) scope = await anonScopeFromToken(tok);
    if (!scope) return J({ error: "unauthorized" }, 401);

    const cfg = await loadReferralConfig(env);
    if (!cfg.enabled) return no("disabled");

    const body = await request.json().catch(() => ({}));
    const now = Date.now();

    // 判新：account.created_at（服务端出生时间；首次 claim 即出生）。
    await ensureAccount(env.USAGE, scope, now);
    const acct = await env.USAGE.prepare("SELECT created_at FROM account WHERE user_sub=?").bind(scope).first();
    if (!acct || now - acct.created_at > DAY_MS) return no("not-new");

    // 已归因过 → 幂等返回（不看 source，first-touch 终身封笔）。
    const prior = await env.USAGE.prepare(
      "SELECT id FROM mint WHERE kind='referral' AND subject_key=?").bind(scope).first();
    if (prior) return J({ attributed: true, already: true });

    // 归因：token（link/clipboard）优先，否则 hello 走 IP 指纹。
    let owner = null, via = String(body.source || "hello");
    if (body.token) owner = await ownerFromToken(env, body.token);
    if (!owner) {
      const ip = request.headers.get("CF-Connecting-IP");
      const hit = env.SESSION_SECRET ? await lookupRefhit(env, ip, env.SESSION_SECRET, now) : null;
      if (hit) { owner = hit.owner; if (via === "link" || via === "clipboard") via = "hello"; }
    }
    if (!owner) return no("no-match");
    if (owner === scope) return no("self");

    // DeviceCheck（防删除重装刷币）。unavailable 在 require 时按拒绝处理。
    if (cfg.requireDeviceCheck) {
      const dc = await deviceCheckGate(env, body.deviceCheckToken, fetcher);
      if (dc === "used") return no("device-used");
      if (dc === "unavailable") return no("device-unavailable");
    }

    // 当日保险丝（与投币同一条线）。
    const day0 = now - (now % DAY_MS);
    const paidToday = (await env.USAGE.prepare(
      "SELECT COALESCE(SUM(actor_uy+beneficiary_uy),0) AS s FROM mint WHERE ts>=?").bind(day0).first()).s;
    if (paidToday > FUSE_MULT * DAILY_POOL_UY) return no("pool_exhausted");

    // owner 日封顶：超出只发新人侧（对新人公平，作者侧归零防批量刷）。
    const ownerToday = (await env.USAGE.prepare(
      "SELECT COUNT(*) AS n FROM mint WHERE kind='referral' AND beneficiary_sub=? AND ts>=?"
    ).bind(owner, day0).first()).n;
    const capped = ownerToday >= cfg.dailyCapPerOwner;

    const authorUC = capped ? 0 : Math.round(cfg.authorCoins * 1e6);
    const newUC = Math.round(cfg.newUserCoins * 1e6);
    const sumUC = (await env.USAGE.prepare(
      "SELECT COALESCE(SUM(coins_uc),0) AS s FROM mint WHERE ts>?").bind(now - 7 * DAY_MS).first()).s;
    const q = referralQuote(sumUC, authorUC, newUC);

    // 先抢唯一键，成功才付钱（mint.js 同约定）。
    const ins = await env.USAGE.prepare(
      "INSERT OR IGNORE INTO mint (kind,subject_key,share_id,actor_sub,beneficiary_sub,coins_uc,price_uy,actor_uy,beneficiary_uy,detail,ts) " +
      "VALUES ('referral',?,?,?,?,?,?,?,?,?,?)"
    ).bind(
      scope, body.token ? String(body.token).slice(0, 16) : null, scope, owner,
      authorUC + newUC, q.priceUY, q.actorUY, q.beneficiaryUY,
      JSON.stringify({ via, ...(capped ? { capped: true } : {}) }), now,
    ).run();
    if (!ins.meta || ins.meta.changes !== 1) return J({ attributed: true, already: true });
    const refId = ins.meta.last_row_id;

    const exp = expiryAfterDays(now, CAMPAIGN_EXPIRE_DAYS);
    if (q.beneficiaryUY > 0)
      await grantBucket(env.USAGE, owner, q.beneficiaryUY, "referral_author", exp, now, { ref_id: refId, via });
    if (q.actorUY > 0)
      await grantBucket(env.USAGE, scope, q.actorUY, "referral_new", exp, now, { ref_id: refId, via });

    if (cfg.requireDeviceCheck) await deviceCheckMark(env, body.deviceCheckToken, fetcher);
    await publishMintRate(env, env.USAGE, now);

    return J({
      attributed: true,
      suanli: { you: r1(uyToSuanli(q.actorUY)), author: r1(uyToSuanli(q.beneficiaryUY)) },
    });
  } catch (e) {
    console.error("[referral] claim failed:", e && e.message);
    return J({ error: "referral-failed" }, 500);
  }
}
```

index.js 在 `handleMintRoutes` 那行后加：

```js
    { const r = await handleReferralRoutes(url, request, env); if (r) return r; }
```

（import 加 `import { handleReferralRoutes, publishMintRate } from "./referral.js";`）

- [ ] **Step 4: 跑测试确认通过**，全量 `npm test` 无回归。
- [ ] **Step 5: Commit** — `feat(referral): claim 路由——三源归因+判新+DeviceCheck+日封顶+同池铸币`

---

### Task 5: 汇率发布挂到投币与定时任务

**Files:**
- Modify: `~/code/jianshuo.dev/agent/src/mint.js`（feed 成功支付后）
- Modify: `~/code/jianshuo.dev/agent/src/index.js`（`scheduled` handler :1287）
- Test: `~/code/jianshuo.dev/agent/test/referral.test.js`（追加 1 用例）

**Interfaces:**
- Consumes: `publishMintRate`（referral.js）。

- [ ] **Step 1: 写失败测试** — mint.test.js 风格：POST /agent/feed 成功后断言 `env.FILES` 里出现 `config/mint-rate.json` 且 `suanliPerCoin > 0`。
- [ ] **Step 2: 确认失败**。
- [ ] **Step 3: 实现** — mint.js feed 分支 `return J({ok:true,…})` 前加 `await publishMintRate(env, env.USAGE, now);`（import from ./referral.js）；index.js `scheduled` 里加 `if (env.USAGE) ctx.waitUntil(publishMintRate(env, env.USAGE, Date.now()));`（6h 刷新兜底，冷启动没铸币也有价可显示——首次部署后手动 curl 触发一次或等 cron）。
- [ ] **Step 4: 确认通过 + 全量无回归**。
- [ ] **Step 5: Commit** — `feat(referral): 铸币汇率发布到 R2（投币后+6h cron）`

---

### Task 6: Pages 落地页——refhits 写入 + CTA + 剪贴板

**Files:**
- Modify: `~/code/jianshuo.dev/functions/voicedrop/[token].js`
- Test: `~/code/jianshuo.dev/agent/test/referral-landing.test.js`（新建；og-tags.test.js 同风格，测导出的纯函数）

**Interfaces:**
- Consumes: `writeRefhit`（refhits.js）；R2 `config/mint-rate.json` + `config/referral.json`。
- Produces: 导出 `ctaHtml(rate, cfg)` 纯函数（rate/cfg 任一缺 → 无数字通用文案）。

- [ ] **Step 1: 写失败测试**

```js
// test/referral-landing.test.js — 落地页 CTA 文案
import { describe, it, expect } from "vitest";
import { ctaHtml } from "../../functions/voicedrop/[token].js";

describe("ctaHtml", () => {
  it("with rate+cfg shows both amounts", () => {
    const h = ctaHtml({ suanliPerCoin: 200 }, { authorCoins: 12, newUserCoins: 6, enabled: true });
    expect(h).toContain("1200");   // 6×200 你约得
    expect(h).toContain("2400");   // 12×200 作者约得
    expect(h).toContain("apps.apple.com");
    expect(h).toContain("navigator.clipboard");
  });
  it("without rate falls back to generic copy (no numbers)", () => {
    const h = ctaHtml(null, { authorCoins: 12, newUserCoins: 6, enabled: true });
    expect(h).toContain("apps.apple.com");
    expect(h).not.toMatch(/\d+\s*算力/);
  });
  it("disabled → still a download CTA, no reward copy", () => {
    const h = ctaHtml({ suanliPerCoin: 200 }, { enabled: false });
    expect(h).not.toContain("算力");
  });
});
```

- [ ] **Step 2: 确认失败**。
- [ ] **Step 3: 实现** — [token].js：

```js
import { writeRefhit } from "../lib/refhits.js";

const APP_STORE = "https://apps.apple.com/cn/app/id6781565141";

// 落地页底部 CTA：奖励数字按「访问时刻」池子价现算（带「约」，实发以入账时为准）。
// rate/cfg 读不到 → 无数字通用文案；enabled:false → 纯下载条不提奖励。
export function ctaHtml(rate, cfg) {
  const on = cfg && cfg.enabled !== false && rate && rate.suanliPerCoin > 0;
  const line = on
    ? `下载 VoiceDrop，你约得 <b>${Math.round(cfg.newUserCoins * rate.suanliPerCoin)}</b> 算力，作者约得 <b>${Math.round(cfg.authorCoins * rate.suanliPerCoin)}</b> 算力`
    : `下载 VoiceDrop，把口述变成文章`;
  return `<div class="vd-cta"><p>${line}</p>
<a id="vd-dl" href="${APP_STORE}">下载 App${on ? " 领取" : ""}</a></div>
<script>document.getElementById('vd-dl').addEventListener('click',function(){
try{navigator.clipboard&&navigator.clipboard.writeText(location.href)}catch(e){}})</script>`;
}
```

onRequest 里（`return html(page(title, bodyHtml, og), 200, true)` 之前）：

```js
  // 邀请归因：记录本次访问的 IP 指纹（第 2 层），并把 CTA 拼进正文底部。
  const owner = (key.match(/^(users\/[^/]+\/)/) || [])[1];
  const ip = context.request.headers.get("CF-Connecting-IP");
  if (owner && ip && env.SESSION_SECRET)
    context.waitUntil(writeRefhit({ FILES: env.FILES }, ip, env.SESSION_SECRET, owner, id, Date.now()).catch(() => {}));
  let rate = null, refCfg = null;
  try { const o = await env.FILES.get("config/mint-rate.json"); if (o) rate = JSON.parse(await o.text()); } catch {}
  try { const o = await env.FILES.get("config/referral.json"); if (o) refCfg = JSON.parse(await o.text()); } catch {}
  const cta = ctaHtml(rate, refCfg || { enabled: true, authorCoins: 12, newUserCoins: 6 });
```

`page()` 加第 4 参 `extra = ''`，`${inner}` 后 `${extra}`，调用处传 `cta`。CSS 加：

```css
.vd-cta{margin-top:2.2rem;padding:1rem 1.2rem;background:#f4f1ea;border-radius:14px;text-align:center}
.vd-cta p{margin:0 0 .7rem;font-size:.95rem}
.vd-cta a{display:inline-block;background:#1d1d1f;color:#fff;text-decoration:none;
  padding:.55rem 1.6rem;border-radius:999px;font-size:.95rem}
```

注意：`Cache-Control: public, max-age=300` 只是浏览器缓存，Pages Function 每请求都执行，refhits 不会被缓存吞掉；同一浏览器 5 分钟内刷新少记几条无所谓（同 owner 去重后不影响唯一匹配）。**报错缺 SESSION_SECRET 时静默跳过**（该 secret Pages 本来就有）。

- [ ] **Step 4: 确认通过 + agent 全量测试无回归**（og-tags.test.js 会守住 metaTags 没被破坏）。
- [ ] **Step 5: Commit** — `feat(referral): 落地页 CTA（实时价现算）+ 下载写剪贴板 + refhits 记录`

---

### Task 7: iOS ReferralManager + 归因序列

**Files:**
- Create: `~/code/voicedrop/VoiceDropApp/ReferralManager.swift`
- Modify: `~/code/voicedrop/VoiceDropApp/AppRouter.swift`（universalLink 命中 .shareLink 时通知 ReferralManager）
- Modify: RootView 所在文件（onAppear 触发首启归因；先 grep RootView 定义处确认）

**Interfaces:**
- Consumes: `POST /agent/referral/claim`（Task 4 契约）、`AuthStore.bearer`（现有）、DeviceCheck framework。
- Produces: `ReferralManager.shared.noteShareToken(_ id: String)`（universal link 到达时调）；`ReferralManager.shared.runOnLaunch()`（首启序列）。

- [ ] **Step 1: 实现**（iOS 无单测 target，验证靠 build + 真机冒烟）

```swift
import Foundation
import UIKit
import DeviceCheck

/// 邀请归因（安装后 24h 内，服务端 first-touch 终身一次）：
///   1. universal link 带 token 到达 → 立即 claim（source=link，确定归因）
///   2. 首启 hello → 服务端用 IP 指纹静默匹配（source=hello）
///   3. 都没中 → detectPatterns 静默探测剪贴板，疑似有 URL 才真正读（此时才弹系统
///      粘贴提示）→ 解析分享链接 → claim（source=clipboard）
/// 本地 done 标记只挡重复网络请求；真正的幂等在服务端（mint 唯一索引 + DeviceCheck）。
@MainActor
final class ReferralManager {
    static let shared = ReferralManager()
    private let doneKey = "referralClaimDone"
    private let firstLaunchKey = "referralFirstLaunchAt"
    private var running = false

    private var done: Bool {
        get { UserDefaults.standard.bool(forKey: doneKey) }
        set { UserDefaults.standard.set(newValue, forKey: doneKey) }
    }

    /// 本地也限 24h：过窗后不再打服务端（服务端仍是真判定）。
    private var withinWindow: Bool {
        let d = UserDefaults.standard
        if d.object(forKey: firstLaunchKey) == nil { d.set(Date().timeIntervalSince1970, forKey: firstLaunchKey) }
        return Date().timeIntervalSince1970 - d.double(forKey: firstLaunchKey) < 86400
    }

    /// Universal link 的分享 id 到达（AppRouter 调）。
    func noteShareToken(_ id: String) {
        guard !done, withinWindow else { return }
        Task { await claim(source: "link", token: id) }
    }

    /// 首启序列：hello（IP）→ 未中再剪贴板兜底。AuthStore.bearer 就绪后调一次。
    func runOnLaunch() {
        guard !done, withinWindow, !running else { return }
        running = true
        Task {
            defer { running = false }
            if await claim(source: "hello", token: nil) { return }
            await clipboardFallback()
        }
    }

    private func clipboardFallback() async {
        // 先无感探测：剪贴板疑似有 URL 才真正读取（读取才触发系统粘贴提示）。
        let pb = UIPasteboard.general
        guard let patterns = try? await pb.detectedPatterns(for: [\.probableWebURL]),
              patterns.contains(\.probableWebURL),
              let text = pb.string,
              let id = Self.shareToken(in: text) else { return }
        _ = await claim(source: "clipboard", token: id)
    }

    /// 从任意文本里挖分享短链 id：voicedrop.cn/<id> 或 jianshuo.dev/voicedrop/<id>。
    static func shareToken(in text: String) -> String? {
        let pats = [
            #"voicedrop\.cn/([A-Za-z0-9_-]{6,16})"#,
            #"jianshuo\.dev/voicedrop/([A-Za-z0-9_-]{6,16})"#,
        ]
        for p in pats {
            if let r = text.range(of: p, options: .regularExpression) {
                let m = String(text[r])
                if let slash = m.lastIndex(of: "/") { return String(m[m.index(after: slash)...]) }
            }
        }
        return nil
    }

    @discardableResult
    private func claim(source: String, token: String?) async -> Bool {
        guard let bearer = AuthStore.bearer, !bearer.isEmpty else { return false }
        let dcToken = await Self.deviceCheckToken()
        var body: [String: Any] = ["source": source]
        if let token { body["token"] = token }
        if let dcToken { body["deviceCheckToken"] = dcToken }
        var req = URLRequest(url: URL(string: "https://jianshuo.dev/agent/referral/claim")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        let attributed = j["attributed"] as? Bool ?? false
        if attributed {
            done = true
            if let s = j["suanli"] as? [String: Any], let you = s["you"] as? Double, you > 0 {
                NotificationCenter.default.post(name: .referralRewarded, object: nil,
                                                userInfo: ["suanli": you])
            }
        }
        // 明确的终局否定（不新/设备已用过）也停手，别在每次启动时骚扰服务端。
        if let reason = j["reason"] as? String,
           ["not-new", "device-used", "disabled"].contains(reason) { done = true }
        return attributed
    }

    private static func deviceCheckToken() async -> String? {
        guard DCDevice.current.isSupported else { return nil }
        return await withCheckedContinuation { cont in
            DCDevice.current.generateToken { data, _ in
                cont.resume(returning: data?.base64EncodedString())
            }
        }
    }
}

extension Notification.Name {
    static let referralRewarded = Notification.Name("referralRewarded")
}
```

- [ ] **Step 2: 挂接**
  - AppRouter.swift `universalLink` 返回 `.shareLink(id:…)` 的分支处（或 `handle(_:)` 里 pending 赋值后）加 `ReferralManager.shared.noteShareToken(id)`。
  - RootView（grep `struct RootView` 定位）`.onAppear`/`.task` 里、AuthStore bearer 就绪后调 `ReferralManager.shared.runOnLaunch()`；参考 whoami/balance 现有首启调用的位置，跟在其后即可。
  - 奖励提示：监听 `.referralRewarded` 弹一个简单 alert/横幅「🎉 获得约 X 算力（朋友邀请）」——用 RootView 现有的 alert 状态机制，没有就加一个 `@State var referralToast`。
- [ ] **Step 3: xcodegen + build** — `cd ~/code/voicedrop && xcodegen && xcodebuild -project VoiceDrop.xcodeproj -scheme VoiceDrop -destination 'generic/platform=iOS Simulator' build` 过。
- [ ] **Step 4: Commit** — `feat(referral): iOS 归因序列（link/hello/剪贴板兜底）+ DeviceCheck`

---

### Task 8: 部署 + 基础设施 + 冒烟 + 文档

- [ ] **Step 1: R2 lifecycle**（refhits 2 天过期）：
  `npx wrangler r2 bucket lifecycle add jianshuo-dev-files --prefix refhits/ --expire-days 2`（wrangler 语法以 `--help` 为准；控制台配也行）。
- [ ] **Step 2: 初始配置入 R2**：`config/referral.json` 写默认值（显式落盘便于日后改）；手动触发一次 `publishMintRate`（部署 worker 后 curl 任意 feed/state 或等 cron）。
- [ ] **Step 3: 部署 Pages** — `cd ~/code/jianshuo.dev && npx wrangler pages deploy . --project-name jianshuo-dev --branch main`（**必须 --branch main**）。
- [ ] **Step 4: 部署 worker** — **先 `git pull` 合 origin/main**（voicedrop-agent 部署纪律：wrangler 整包覆盖），`npm test` 全过再 `npx wrangler deploy`。
- [ ] **Step 5: DeviceCheck key 验证** — 用真机 TestFlight build 走一次 claim，若 Apple 返回 key 无 DeviceCheck 权限（401/403），去 Apple Developer 后台建一把带 DeviceCheck 的 key，`wrangler secret put DC_KEY_P8` / `DC_KEY_ID`。**在此之前线上 requireDeviceCheck 先改 false**（R2 config 一行，避免全员 device-unavailable 拒发）。
- [ ] **Step 6: 线上冒烟** —
  1. 打开任一分享页：CTA 显示、HTML 里有 clipboard 脚本；R2 `refhits/` 出现新对象。
  2. 造一个新 anon token（vd-login / 新模拟器），同一出口 IP `POST /agent/referral/claim {source:"hello"}` → attributed；owner 账单出现「邀请奖励」，新账号出现「受邀赠送」。
  3. 二次 claim → already。老账号（>24h）claim → not-new。
- [ ] **Step 7: 文档** — voicedrop `STATE.md` 加「邀请奖励」节（契约、config 键、归因序列、已知边界）；`~/code/jianshuo-memory/08-infrastructure/` 加 voicedrop-referral.md + 更新总索引。
- [ ] **Step 8: Commit + push**（两 repo；voicedrop push main 自动出 TestFlight）。

## Self-Review

- Spec 覆盖：§1 三层归因（T4/T6/T7）、§2 判新防刷（T3/T4）、§3 币记价同池入账（T1/T4）、§4 落地页（T6）、§5 已上线仅验证（T8）、§6 API（T4）、§7 iOS（T7）✓。
- 与 spec 的两处落地偏差（均已在任务里注明理由）：日封顶只砍作者侧（对新人公平）；DeviceCheck 复用 APNs key 待验证、备 DC_KEY_* 兜底。
- 类型/命名一致性：`handleReferralRoutes(url,request,env,fetcher)`、`publishMintRate(env,db,now)`、`referralQuote(sumUC,authorUC,newUC)`、R2 键 `config/referral.json`/`config/mint-rate.json`/`refhits/<hash>/<ts>` 全文一致 ✓。
