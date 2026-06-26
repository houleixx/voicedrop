# VD社区 基础推荐排序 · 技术 Spec

> 2026-06-26 · 贴当前体量的最小实现。不为扩容设计。
> 给 VD社区做一个「互动加权 × 年龄衰减」的全局排序(千人一面),并采集 4 个聚合互动信号
> (view / finish / like / reply)。**不建画像、不个性化。**
>
> **首要约束(2026-06-26 用户加):整套系统必须尽量独立 —— 即便它整个 down 掉,也绝不影响
> VoiceDrop 核心(录音 / 文章 / 社区浏览照常)。它自存在、自己带文档、可随时拔掉。**

## 0. 范围与原则

- **千人一面**:所有用户看到同一个排好序的 feed,没有 per-user 画像、没有个性化顺序。
  (例外:每帖带一个"我赞过没"的 `liked` 标记,这是 per-caller 的,不影响全局顺序。)
- **只产出"每帖聚合计数"**,不存"谁喜欢什么"。`engagement` 表是计数 + 去重,不是兴趣画像。
- **失败隔离(最高优先级)**:推荐系统是一个**独立 Worker `voicedrop-reco`**,核心
  `functions/files/api/[[path]].js` **一行不改**。reco 宕机 / 报错 / 超时 → app 退回核心的
  时间序 feed,VoiceDrop 完全无感。reco 对核心、核心对 reco **互不依赖**(唯一耦合是共享
  `SESSION_SECRET` 这个值,用来各自独立验 token;不是运行时调用)。
- **自带文档**:reco 目录里有自己的 `README.md`(schema / 路由 / 评分 / 部署 / 回退契约),
  是这套系统的 canonical 文档;STATE.md 只放一行指针。
- **不引入**文档 `recommendation_system.md` 里的 content / content_tags / user_interests /
  follows / impressions 五张表,也不引入 Cron、标签抽取、向量召回。文章/照片/社区指针**继续留在
  核心 R2**,reco 不碰 R2。

## 1. 架构:纯旁挂 sidecar

```
                    ┌──────────────────────────────────────────┐
                    │  VoiceDrop 核心(完全不变)                 │
   app ──list────►  │  Pages Fn: GET /files/api/community/list   │ ──时间序 posts──┐
                    │  (R2 指针 + live article,一行不改)         │                 │
                    └──────────────────────────────────────────┘                 │
                                                                                  ▼
                    ┌──────────────────────────────────────────┐         app 本地合并:
   app ──engage──►  │  voicedrop-reco(新独立 Worker)            │         有 reco → 用 reco 序
   app ──rank────►  │  路由 /engage /rank · D1 engagement · 自带 │ ──order+liked──► 用 liked
                    │  SESSION_SECRET 独立验 token · 不碰 R2      │         reco 挂 → 用时间序
                    └──────────────────────────────────────────┘
```

- **核心**:数据真源(文章/照片/社区指针)全在核心 R2,`community/list` 维持现状(时间倒序)。
- **reco**:只管互动计数(D1)+ 排序计算。无状态于"内容"——它不知道文章正文,只接收 app 传来的
  候选元数据 `{shareId, firstSharedAt, author}`,配上自己 D1 里的计数算分。
- **app**:同时拿核心 `list`(必拿,feed 的基础)和 reco `rank`(尽力而为)。reco 失败就用 list 原序。

### 落点

- 新目录 `~/code/jianshuo.dev/reco/`(与 `agent/` 同级),独立 Worker `voicedrop-reco`。
- 路由:`jianshuo.dev/reco/*`(zone route),并开 `workers_dev: true` 作为备用直连子域。
- Binding:**D1 `DB`(自己的库)** + **`SESSION_SECRET`(同值,用来独立验 token)**。无 R2 / 无 FILES_TOKEN / 无 Claude。
- 部署:`cd ~/code/jianshuo.dev/reco && npx wrangler deploy`(与 agent 同套路,独立部署)。

## 2. 数据模型(D1 单表,reco 私有)

新建 D1 数据库 `voicedrop-reco`,只有一张表:

```sql
CREATE TABLE engagement (
  share_id   TEXT NOT NULL,
  user_sub   TEXT NOT NULL,          -- = reco 独立解析出的 scope,如 "users/anon-<hash>/"
  action     TEXT NOT NULL,          -- 'view' | 'finish' | 'like'
  created_at INTEGER NOT NULL,       -- Date.now() ms
  PRIMARY KEY (share_id, user_sub, action)   -- 同一人同一动作只算一次 → 天然去重
);
CREATE INDEX idx_engagement_share ON engagement(share_id);
```

- **去重**靠主键:同一 `(share_id, user_sub, action)` 只一行。view 看 100 次仍只计 1。
- **已读记录**也由这张表承担(view 行存在 = 看过),所以不需要 impressions。
- `reply` 不入表 —— 回复数由 app 从核心 `list` 的 `replyTo` 字段数出来,随 `rank` 请求一起传给 reco。

建库 + 建表(一次性):

```bash
cd ~/code/jianshuo.dev/reco
npx wrangler d1 create voicedrop-reco        # 把 database_id 填进 reco/wrangler.jsonc
npx wrangler d1 execute voicedrop-reco --remote --file=migrations/0001_engagement.sql
npx wrangler secret put SESSION_SECRET       # 同核心/agent 的值
```

迁移文件 `reco/migrations/0001_engagement.sql` 纳入 repo。

## 3. reco Worker 路由

### 3.1 鉴权(reco 自己验,不调核心)

reco 内置一份与核心同款的 token 解析(小段代码:`verifySession`(用 SESSION_SECRET 验 Apple JWT)
+ anon token 的 `sha256` 派生)。解析出 `user_sub = scope`。

- **只要任意有效 token**(`scope !== null`)即可上报/排序 —— anon token 也行,门槛越低信号越多。
- 解析失败 → 401。但注意:rank 失败时 app 会回退,所以 401 也不会让 feed 崩。

### 3.2 `POST /reco/engage/<shareId>` — 记录互动

body `{action, on?}`:

- `shareId` 校验 `/^[0-9A-Za-z_-]{1,32}$/`。
- `view` / `finish`:`INSERT OR IGNORE INTO engagement VALUES (<shareId>, <scope>, '<action>', <now>)` → `{ok:true}`。
- `like`:**显式开关**(配合乐观 UI):`on === false` → `DELETE ... action='like'`;否则 `INSERT OR IGNORE`。
  返回 `{ok:true, liked: on !== false}`。

### 3.3 `POST /reco/rank` — 给一批帖排序

body:`{ posts: [{ shareId, firstSharedAt, author, replyCount }] }`(app 从核心 `list` 现成字段拼出来;
`replyCount` = app 数 `replyTo === shareId` 的条数)。

reco:
1. `SELECT share_id, action, COUNT(*) c FROM engagement WHERE share_id IN (...) GROUP BY share_id, action`
   → `engMap[shareId] = {view, finish, like}`。
2. `SELECT share_id FROM engagement WHERE user_sub=? AND action='like' AND share_id IN (...)` → 我赞过的集合。
3. 用纯函数 `rankPosts`(§4)算分 + 作者打散。
4. 返回 `{ order: [shareId...], liked: [shareId...] }`。**只回顺序和 liked,不回任何计数数字**(赞先不显示计数)。

> reco 不读 R2、不知道正文,所有内容元数据由 app 传入 → reco 真正独立、可单测、可随时重启。

## 4. 排序公式(纯函数,可单测)

```javascript
// engagement 加权(权重起步值,= recommendation_system.md §3.1;后续看数据调)
const W = { view: 1, finish: 4, like: 3, reply: 5 };

function postScore(eng, replyCount, firstSharedAt, now) {
  const e = W.view*(eng.view||0) + W.finish*(eng.finish||0)
          + W.like*(eng.like||0) + W.reply*(replyCount||0);
  const ageHours = Math.max(0, (now - (firstSharedAt||now)) / 3600000); // firstSharedAt 是 ms
  return (1 + e) / Math.pow(ageHours + 2, 1.5);   // HN/牛顿冷却:新帖起高分,随时间冷却
}

// 排序 + 作者打散(贪心,乘性惩罚;作者少时几乎不生效)
function rankPosts(posts, engMap, now) {
  const scored = posts.map(p => ({
    p, s: postScore(engMap[p.shareId] || {}, p.replyCount || 0, p.firstSharedAt, now)
  }));
  const out = [], seen = {};
  while (scored.length) {
    let bi = 0, bv = -Infinity;
    for (let i = 0; i < scored.length; i++) {
      const adj = scored[i].s * Math.pow(0.5, seen[scored[i].p.author] || 0); // 同作者每出现一次 ×0.5
      if (adj > bv) { bv = adj; bi = i; }
    }
    const [picked] = scored.splice(bi, 1);
    seen[picked.p.author] = (seen[picked.p.author] || 0) + 1;
    out.push(picked.p.shareId);
  }
  return out;
}
```

- `now = Date.now()`(Worker 运行时可用)。
- `0.5` = 作者打散强度(可调);作者少时排序基本等于纯 score 序。

## 5. iOS(`VoiceDropApp/`)—— 回退契约是重点

### 5.1 feed 加载(`Community.swift` + `LibraryView.swift`)

```
1. posts = await core.community/list      // 必走;失败 → 现有错误处理,与今天一致
2. 尝试 order/liked = await reco /rank(传 posts 的 shareId/firstSharedAt/author/replyCount)
   2a. 成功 → 按 order 重排 posts;给每个 post 打 liked 标记
   2b. 失败/超时(短 timeout, 如 2s) → 保持 list 原序(时间倒序),liked 全 false
3. 渲染
```

**关键:reco 只影响"顺序"和"❤️ 是否实心",从不影响"feed 能不能出"。** core.list 成功就一定有 feed。

- `CommunityStore` 新增:
  - `func rank(_ posts:[CommunityPost]) async -> (order:[String], liked:Set<String>)?`(失败返回 nil)。
  - `func engage(_ shareId:String, action:String, on:Bool? = nil) async`(fire-and-forget,失败静默)。
- reco 的 base URL 独立常量(如 `https://jianshuo.dev/reco`),与核心 `base` 分开。
- `CommunityPost` 不必加可解码字段;`liked` 由 app 用 reco 返回的集合在内存里标(`@State`/字典)。

### 5.2 `CommunityPostView`(详情页)—— 三个上报点

- **view**:`.task`/`onAppear` 进帖 → `engage(shareId, "view")`。
- **finish = 滚动到正文底**:正文内容**最末尾**放哨兵
  `Color.clear.frame(height:1).onAppear { … engage(shareId,"finish") }`,只报一次(`@State finished` 守门)。
- **like = ❤️ 按钮**(详情页作者/日期行,**不在列表卡片**):实心/空心由 `liked` 决定,**不显示计数**;
  点击 → 乐观翻转 → `engage(shareId,"like", on:newLiked)`。

所有 engage 失败都静默忽略 —— reco down 时用户只是"赞了没生效",核心体验不受影响。

## 6. 测试

- **核心可测物 = 纯函数 `postScore` / `rankPosts`**(reco 内,无 I/O):
  - 新帖(age≈0)分高于老帖;高互动老帖能顶过零互动新帖;
  - 同作者连续多帖被打散;空输入不崩。
- **reco 路由测试**:engage 幂等(view 重复只计一次)、like 开关、rank 返回结构。
- reco 有**自己的测试**(`reco/test/`),与核心 `agent/test/` 解耦。
- 改动前后仍按 CLAUDE.md 跑核心测试 `cd ~/code/jianshuo.dev/agent && npm test` 确认**核心零回归**
  (本设计核心代码零改动,理应纯绿)。

## 7. 部署 / 上线顺序

1. 建 `reco/` 目录:`wrangler.jsonc`(D1 binding + route + workers_dev)、`src/index.js`、
   `migrations/0001_engagement.sql`、`README.md`、`test/`。
2. `wrangler d1 create voicedrop-reco` → 填 id → 跑迁移 → `secret put SESSION_SECRET`。
3. `cd reco && npx wrangler deploy`。
4. iOS:`Community.swift` 加 rank/engage + `CommunityPostView` 三个上报点 + ❤️ 按钮;push `main` → TestFlight。
5. **次序无所谓**:reco 先上,老 app 不调它也无害;app 先上,reco 没好之前 rank 失败就走回退。
   核心始终不变,任何时刻拔掉 reco 都安全。

## 8. 明确不做(YAGNI)

- ❌ 改动核心 Pages Function / `community/list`(隔离要求 → 核心零改动)。
- ❌ 用户画像 / 个性化 / 多路召回 / 标签 / 向量 / Cron 热门榜。
- ❌ 点赞计数数字、点赞列表、谁赞了我。
- ❌ 防刷 / 限流(anon 去重已够)。
- ❌ reco 读 R2 或反向调用核心(保持单向、无运行时依赖)。
- ❌ **token 计费 / 用量统计**(2026-06-26 暂不做)。决定已定档:将来做时**单独一份 spec + 单独 D1
  库 `voicedrop-usage`**,由 agent worker 在写 `llmlogs/` 同一点 UPSERT 累加;**绝不**进
  `engagement` 表、**也不**进 reco 库(计费是持久财务数据,不能挂在"可丢弃 sidecar"里)。

## 9. 起步参数(都可调,先拍脑袋上线看感觉)

| 参数 | 值 | 含义 |
|---|---|---|
| `W.view` | 1 | 浏览权重 |
| `W.finish` | 4 | 看完权重 |
| `W.like` | 3 | 点赞权重 |
| `W.reply` | 5 | 回复权重 |
| 冷却指数 | 1.5 | `(ageHours+2)^1.5`,越大老帖掉得越快 |
| 作者打散 | 0.5 | 同作者每多出现一次,分 ×0.5 |
| rank 超时 | 2s | app 等 reco 的上限,超时即回退时间序 |
