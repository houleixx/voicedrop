# HANDOFF — VD社区 基础推荐排序(community-ranking)

> 写于 2026-06-26。给接手的 agent:这份文档自包含,读它 + 读 plan 就能续上。
> **不要重做已完成的 Task 1–4**(已提交并测试通过)。从 **Task 5** 续起。

## 一句话目标

给 VD社区 feed 做一个「互动加权 × 年龄衰减」的全局排序(千人一面),采集 view/finish/like/reply 四个聚合信号,**全部跑在一个可随时拔掉的独立 Worker `voicedrop-reco` 里,VoiceDrop 核心零改动**。reco 挂了 → app 回退时间序,feed 照常。

## 权威文档(先读这两份)

- **Spec**:`~/code/voicedrop/docs/superpowers/specs/2026-06-26-community-ranking-design.md`
- **Plan(含每个任务的完整代码)**:`~/code/voicedrop/docs/superpowers/plans/2026-06-26-community-ranking.md`
- **进度 ledger**:`~/code/voicedrop/.superpowers/sdd/progress.md`(durable 进度,信它 + `git log`)

⚠️ Spec / Plan / ledger 都在 voicedrop repo,目前**未提交**(untracked)。

## 工作方式约定(用户明确要求)

1. **两个 repo 都直接在 `main` 上改+提交**,不开 branch / worktree(沿用本项目既有实践)。
2. **琐碎 fix 自己直接改,不要起 subagent**(用户强调过两次)。计划里代码都是完整的,基本是建文件→跑测试→提交。
3. 工具调用注意命名空间前缀格式(我之前几次因丢前缀报 malformed)。
4. 提交信息末尾带:
   ```
   Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
   Claude-Session: https://claude.ai/code/session_015SJ1MUn2wPyiYn69JxhoVx
   ```

## 架构(纯旁挂 sidecar)

```
app ──GET /files/api/community/list──► 核心 Pages(不变,时间倒序) ──posts──┐
app ──POST /reco/engage/<id>────────► voicedrop-reco(新 Worker)          │
app ──POST /reco/rank───────────────► D1 engagement · 独立验 token         ──order+liked──► app 本地合并
                                                                              reco 挂/超时2s → 用时间序
```
- reco **不碰 R2、不反调核心**;唯一与核心共享 `SESSION_SECRET` 的值(各自独立验 token)。
- 核心 `functions/files/api/[[path]].js` 与 `community/list` **一行都不改**。

---

## ✅ 已完成(jianshuo.dev repo,main 上已提交)

reco worker 在 `~/code/jianshuo.dev/reco/`。**全套测试 20/20 绿**(`cd ~/code/jianshuo.dev/reco && npm test`)。

| Task | 内容 | 提交 |
|---|---|---|
| base | (Task 1 之前的 HEAD) | `b6c3d9c` |
| 1 | 脚手架 `package.json` + 纯排序 `src/ranking.js`(`postScore`/`rankPosts`)+ `test/ranking.test.js` | `923c0f4` |
| 1-fix | 补 reply 权重孤立测试(review 的 Important) | `5eb2b5a` |
| 2 | `src/auth.js` — `resolveScope(token,secret)`(verifySession + anon hash,从核心复刻)+ test | `3cd3f44` |
| 3 | `src/store.js`(`recordEngagement`/`countsFor`/`likedBy`)+ `test/fakes.js`(fake D1)+ test | `743fc77` |
| 4 | `src/index.js` Worker 入口(`/reco/engage/<id>` + `/reco/rank`,401、env.DB 缺失降级)+ test | `371e212` |

**jianshuo.dev 当前 HEAD = `371e212`**,外加**未提交的工作区文件**(属于 Task 5,见下):
- `reco/migrations/0001_engagement.sql`(已写,未提交)
- `reco/README.md`(已写,未提交)

Task 1 review 留下 2 个 Minor(已记 ledger,留给最终 review 三检,**不阻塞**):
- `postScore(null,...)` 会抛(但唯一调用点都传 `||{}`,低风险);
- `author=undefined` 会collapse 进同一个打散桶。

---

## ⬜ 待完成

### Task 5 — wrangler 配置 + D1 迁移 + 部署(**真实上云动作,我停在这里**)

我已写好 `migrations/0001_engagement.sql` 和 `README.md`(未提交)。**剩下的都是动 Cloudflare 的命令,需要用户在场确认再跑**:

1. `cd ~/code/jianshuo.dev/reco && npx wrangler d1 create voicedrop-reco` → 记下输出的 `database_id`。
2. 用该 id 写 `reco/wrangler.jsonc`(模板在 plan 的 Task 5 Step 3,**还没创建这个文件**)。关键字段:
   - `name: "voicedrop-reco"`、`main: "src/index.js"`、`compatibility_date: "2026-06-01"`
   - `routes: [{ pattern: "jianshuo.dev/reco/*", zone_name: "jianshuo.dev" }]`、`workers_dev: true`
   - `d1_databases: [{ binding: "DB", database_name: "voicedrop-reco", database_id: "<上一步>" }]`
   - **无 R2、无 DO**。
3. `npx wrangler d1 execute voicedrop-reco --remote --file=migrations/0001_engagement.sql`(建表)。
4. `npx wrangler secret put SESSION_SECRET` — **值 = 核心 Pages 项目 jianshuo-dev 用的同一个 SESSION_SECRET**。
   - ⚠️ **未解决的开放项**:我正要查这个值在哪本地能拿到时被打断。线索:上一个功能(anon-apple-auth-link,2026-06-23)的旧 ledger 写过 "SESSION_SECRET rotated + identical on Pages jianshuo-dev + Worker voicedrop-agent ... Secret saved to vault"。**接手者需先确认 wrangler 是否已登录(`npx wrangler whoami`),并向用户要 SESSION_SECRET 的值或确认其在 `~/code/.env` / vault 的位置**(`grep -q SESSION_SECRET ~/code/.env`,不要打印值)。
5. `npx wrangler deploy`。
6. 冒烟:`curl -s -X POST https://jianshuo.dev/reco/rank -H 'Content-Type: application/json' -d '{"posts":[]}' -i | head -1` → 期望 `HTTP/2 401`(无 token 被拒 = 路由+鉴权在线)。
7. 提交:`git add reco/wrangler.jsonc reco/migrations/0001_engagement.sql reco/README.md`(README/migration 此刻才一起提交)。

### Task 6 — iOS:`CommunityStore` 接 reco(完整代码见 plan Task 6)

改 `~/code/voicedrop/VoiceDropApp/Community.swift`:
- 加 `private let recoBase = URL(string: "https://jianshuo.dev/reco")!` 和 `var likedShareIds: Set<String> = []`。
- `load()` 末尾调 `applyRanking()`:拼 `{shareId,firstSharedAt,author,replyCount}` POST `/reco/rank`(`timeoutInterval=2`),成功就按 `order` 重排 `posts` 且 `likedShareIds = Set(liked)`;失败/超时**保持时间序**(只在 `reordered.count == posts.count` 时替换)。
- 加 `func engage(_ shareId:String, action:String, on:Bool? = nil)` — fire-and-forget,失败静默。
- `replyCount` 由 app 自己数 `posts` 里 `replyTo == shareId` 的条数。
- 验证:`cd ~/code/voicedrop && xcodegen generate && xcodebuild -scheme VoiceDrop -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO 2>&1 | tail -5` → `BUILD SUCCEEDED`。

### Task 7 — iOS:详情页 view/finish 上报 + ❤️ 按钮(完整代码见 plan Task 7)

同样改 `Community.swift` 的 `CommunityPostView`(struct 在同文件 ~行198):
- 加 `@State private var liked = false` / `@State private var finishedReported = false`。
- `.task` 开头:`liked = store.likedShareIds.contains(post.shareId)` + `await store.engage(post.shareId, action:"view")`。
- ScrollView 正文 `VStack` 末尾(`repliesSection` 之后)加 `Color.clear.frame(height:1).onAppear{ 守门后 engage(finish) }` = 滚到文底算看完。
- `navBar` 的 `Spacer()` 与 `Menu` 之间插入 ❤️ 按钮:`Image(systemName: liked ? "heart.fill" : "heart")`,点击 `liked.toggle()` + `engage(action:"like", on:liked)`。**不显示计数**。
- 验证:同上 xcodebuild。

### Task 8 — STATE.md 指针(完整文案见 plan Task 8)

在 `~/code/voicedrop/STATE.md` 的「## Community (VD社区)」段末尾加一小节,指明 canonical 文档 = `reco/README.md`,要点:核心零改动、reco 可拔掉回退时间序、engagement 表、互动上报点、token 计费未做(将来单独 `voicedrop-usage` 库)。

### 最终:whole-branch review + 提交文档

- 跑核心回归(应纯绿,核心零改动):`cd ~/code/jianshuo.dev/agent && npm test`。
- 把 spec / plan / ledger / 本 handoff 提交到 voicedrop repo。
- 按 `superpowers:finishing-a-development-branch` 收尾。

---

## 关键 gotcha

1. **`firstSharedAt` 是毫秒**(`Date.now()`)。`ageHours=(now-firstSharedAt)/3600000`。iOS `CommunityPost.firstSharedAt` 也是 ms(`Double?`)。
2. **`user_sub` = reco 独立解析的 `scope`**(`users/anon-<hash>/` 或 Apple JWT 的 scope),anon 用户也有稳定身份,够去重。
3. **engage 不要求 Apple 登录**,任意有效 token 即可(门槛低=信号多);只有核心的 share/unshare 才要 Apple 门禁。
4. **赞不显示计数**:❤️ 只反映"我赞过没"。
5. **reco 失败一律静默回退**,绝不让 feed 出不来。
6. 起步参数(都可调):`W={view:1,finish:4,like:3,reply:5}`、冷却指数 `1.5`、作者打散 `0.5`、rank 超时 `2s`。
7. 上线次序无所谓:reco 先上老 app 不调它也无害;app 先上 reco 没好就走回退。

## 测试速查
- reco:`cd ~/code/jianshuo.dev/reco && npm test`(现 20/20)。
- 核心回归:`cd ~/code/jianshuo.dev/agent && npm test`。
- iOS:`cd ~/code/voicedrop && xcodegen generate && xcodebuild -scheme VoiceDrop -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO`。
