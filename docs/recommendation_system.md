# 社区基础推荐系统 · 技术设计方案

> 目标:把每个用户最可能感兴趣的内容推到他面前。
> 落地约束:Cloudflare 栈(Workers + D1 + Cron,后续可接 Vectorize)。

## 0. 关键假设

设计基于以下假设,不符的地方按注释替换即可:

- **内容形态**:短文本 / 图文为主(标签可由模型抽取)。
- **数据阶段**:起步期,行为数据不多 → 不依赖协同过滤,避免冷启动死锁。
- **实时性**:画像近实时更新,推荐流近实时召回 + 轻量排序;重计算放 Cron。
- **规模**:起步几千到几万用户/内容,单 D1 库可扛;到百万级再分库或引入专用存储。

整套系统三条主线:**兴趣画像 → 多路召回 → 加权排序**。

---

## 1. 整体架构

```
         ┌─────────────┐
用户行为 → │  行为埋点 API │ → 写 events 表 + 增量更新画像
         └─────────────┘
                              ┌──────────────┐
         ┌─────────────┐      │  多路召回      │
拉取 feed → │  Feed API   │ →   │ 关注/标签/热门/新 │ → 合并去重
         └─────────────┘      └──────────────┘
                                     ↓
                              ┌──────────────┐
                              │  加权排序+打散  │ → 返回 feed
                              └──────────────┘

         ┌─────────────┐
内容发布 → │ 内容入库 API │ → 模型抽标签 → 写 content_tags
         └─────────────┘

Cron(定时):重算热门榜、画像懒衰减校准、清理过期 events
```

### Cloudflare 组件映射

| 职责 | 组件 | 说明 |
|------|------|------|
| API / 业务逻辑 | Workers | 行为埋点、feed、入库 |
| 画像 / 标签 / 内容元数据 | D1 (SQLite) | 关系查询友好,起步够用 |
| 热门榜 / 高频读缓存 | KV 或 Workers Cache | 读多写少的榜单 |
| 定时任务 | Cron Triggers | 重算热门、清理 |
| 向量召回(演进) | Vectorize | 语义相似召回,后期加 |
| 标签抽取(演进) | Workers AI 或外部 LLM | 内容打标签 |

---

## 2. 数据模型(D1 表结构)

```sql
-- 内容主表
CREATE TABLE content (
  id          TEXT PRIMARY KEY,
  author_id   TEXT NOT NULL,
  created_at  INTEGER NOT NULL,        -- unix 秒
  like_count  INTEGER DEFAULT 0,
  comment_count INTEGER DEFAULT 0,
  share_count INTEGER DEFAULT 0,
  hot_score   REAL DEFAULT 0,          -- Cron 定时刷新
  status      INTEGER DEFAULT 1        -- 1正常 0下架
);
CREATE INDEX idx_content_created ON content(created_at);
CREATE INDEX idx_content_hot ON content(hot_score);

-- 内容标签(一条内容多行)
CREATE TABLE content_tags (
  content_id  TEXT NOT NULL,
  tag         TEXT NOT NULL,
  weight      REAL DEFAULT 1.0,        -- 该标签在这条内容里的强度
  PRIMARY KEY (content_id, tag)
);
CREATE INDEX idx_ctag_tag ON content_tags(tag);

-- 用户兴趣画像(用户 × 标签)
CREATE TABLE user_interests (
  user_id     TEXT NOT NULL,
  tag         TEXT NOT NULL,
  weight      REAL NOT NULL,           -- 累积兴趣权重
  updated_at  INTEGER NOT NULL,        -- 懒衰减用的时间戳
  PRIMARY KEY (user_id, tag)
);
CREATE INDEX idx_uinterest_user ON user_interests(user_id);

-- 关注关系
CREATE TABLE follows (
  follower_id TEXT NOT NULL,
  followee_id TEXT NOT NULL,
  PRIMARY KEY (follower_id, followee_id)
);

-- 行为流水(也用于"已读去重"和后续协同过滤)
CREATE TABLE events (
  user_id     TEXT NOT NULL,
  content_id  TEXT NOT NULL,
  action      TEXT NOT NULL,           -- view/like/comment/share/finish
  created_at  INTEGER NOT NULL
);
CREATE INDEX idx_events_user ON events(user_id, created_at);

-- 已曝光记录(防重复推送,可用 KV 替代以减轻 D1 压力)
CREATE TABLE impressions (
  user_id     TEXT NOT NULL,
  content_id  TEXT NOT NULL,
  shown_at    INTEGER NOT NULL,
  PRIMARY KEY (user_id, content_id)
);
```

---

## 3. 兴趣画像:打分 + 懒衰减

### 3.1 行为权重

每次行为给对应内容的标签加分。建议起步值:

```
view(浏览)    +1
finish(看完)  +4
like(点赞)    +3
comment(评论)  +5
share(转发)    +8
```

负向行为(可选):快速划走 / 点"不感兴趣" → 给标签减分,信号很强。

### 3.2 懒衰减(Lazy Decay)—— 关键设计

Serverless 环境**不要**每天全表更新衰减,那很重。改成**读取时按需衰减**:存储时记下 `updated_at`,任何时候用到权重,先按经过的时间折算。

衰减公式(每天 ×0.95,即半衰期约 13.5 天):

```
有效权重 = stored_weight × 0.95 ^ ((now - updated_at) / 86400)
```

更新画像时,把旧权重先衰减到"现在",再叠加新增量,刷新 `updated_at`:

```javascript
// 用户对某条内容产生行为后,更新其所有标签的画像
async function updateInterest(db, userId, tags, actionScore, now) {
  for (const { tag, weight } of tags) {
    const delta = actionScore * weight;          // 行为分 × 标签强度
    const row = await db.prepare(
      `SELECT weight, updated_at FROM user_interests WHERE user_id=? AND tag=?`
    ).bind(userId, tag).first();

    let newWeight;
    if (row) {
      const decayed = row.weight * Math.pow(0.95, (now - row.updated_at) / 86400);
      newWeight = decayed + delta;
    } else {
      newWeight = delta;
    }
    await db.prepare(
      `INSERT INTO user_interests (user_id, tag, weight, updated_at)
       VALUES (?, ?, ?, ?)
       ON CONFLICT(user_id, tag) DO UPDATE SET weight=?, updated_at=?`
    ).bind(userId, tag, newWeight, now, newWeight, now).run();
  }
}
```

> 好处:零定时成本、画像永远反映"最近兴趣"、可解释。
> Cron 只需偶尔清理权重已衰减到接近 0 的长尾行,控制表大小。

---

## 4. 内容标签

发布时抽标签,落 `content_tags`。两种做法:

- **规则法**:关键词词典 / 话题 # 直接映射。零成本但扩展差,适合最早期。
- **模型抽取(推荐)**:把正文喂给 LLM,要求输出 3–5 个标签 + 权重,JSON 返回。

模型抽取的 prompt 约束示例(输出严格 JSON):

```
你是内容标签抽取器。读下面这条社区内容,输出最相关的 3-5 个标签。
只输出 JSON,不要任何解释:
{"tags":[{"tag":"露营","weight":0.9},{"tag":"装备","weight":0.5}]}
```

标签体系建议**先收敛到一个可控的标签库**(几百个),避免长尾标签把画像打散。可以让模型从给定标签集里选,而非自由生成。

---

## 5. 多路召回

目标:从全量内容里快速捞出几百条"可能相关"的候选,各路并行。

### 5.1 四路召回

**① 关注流**:关注的人的近期内容。

```sql
SELECT c.id FROM content c
JOIN follows f ON f.followee_id = c.author_id
WHERE f.follower_id = ?1 AND c.status = 1
  AND c.created_at > ?2          -- 近 N 天
ORDER BY c.created_at DESC LIMIT 50;
```

**② 标签兴趣流**:用户高权重标签 ↔ 内容标签。先取用户 Top-K 标签,再查命中这些标签的内容。

```sql
-- 取用户 Top 标签
SELECT tag, weight FROM user_interests WHERE user_id = ?1
ORDER BY weight DESC LIMIT 10;

-- 用这些标签召回内容(? 占位为标签列表)
SELECT ct.content_id, SUM(ct.weight) AS match_score
FROM content_tags ct
JOIN content c ON c.id = ct.content_id
WHERE ct.tag IN (?,?,?,...) AND c.status = 1
  AND c.created_at > ?           -- 近 N 天,避免老内容
GROUP BY ct.content_id
ORDER BY match_score DESC LIMIT 80;
```

**③ 热门兜底**:近期高互动,解决冷启动 + 保证新用户也有东西看。

```sql
SELECT id FROM content
WHERE status = 1 AND created_at > ?
ORDER BY hot_score DESC LIMIT 40;
```

**④ 新鲜探索**:给刚发布内容一点曝光,采集行为信号(否则新内容永远冷)。

```sql
SELECT id FROM content
WHERE status = 1 AND created_at > ?    -- 最近几小时
ORDER BY created_at DESC LIMIT 30;
```

### 5.2 合并去重

各路结果合并,去掉:已曝光(impressions)、自己发的、已下架。保留来源标记(后面排序和打散要用)。

---

## 6. 排序

### 6.1 加权打分公式

候选合并后,逐条算分。起步用线性加权,不上模型:

```
score = w1 · 标签匹配度(用户画像 · 内容标签 点积,归一化)
      + w2 · log(1 + 互动数)             // 热度,取 log 防头部碾压
      + w3 · 时间新鲜度                   // 1/(1+小时数) 或牛顿冷却
      + w4 · 关注关系加成                 // 来自关注流则 +1
      - w5 · 已曝光惩罚                   // 曾经曝光未点击,降权
```

起步权重建议:`w1=0.4, w2=0.25, w3=0.2, w4=0.15`。**先拍脑袋,上线后看点击/停留调。**

```javascript
function scoreItem(item, userVec, now) {
  const match = cosineOrDot(userVec, item.tagVec);       // 标签匹配
  const hot   = Math.log(1 + item.like + item.comment*2 + item.share*3);
  const ageHr = (now - item.created_at) / 3600;
  const fresh = 1 / (1 + ageHr);
  const follow = item.fromFollow ? 1 : 0;
  return 0.4*match + 0.25*norm(hot) + 0.2*fresh + 0.15*follow;
}
```

### 6.2 打散 / 多样性(防信息茧房)

纯按分数排,会出现"连续 10 条同一个标签/同一作者",体验差也加深茧房。加两条规则:

- **作者打散**:同一作者在一屏内最多出现 1–2 次。
- **标签打散**:相邻内容主标签不重复;或对已出现标签做"递减惩罚"(MMR 思路,简化版)。
- **探索位**:每屏固定留 1–2 个低匹配但新鲜/热门的位置,持续给系统注入新信号。这就是经典的 explore/exploit 平衡。

简化打散(贪心,边选边惩罚):

```javascript
function diversify(sorted, perScreen = 10) {
  const picked = [], authorCount = {}, tagCount = {};
  for (const item of sorted) {
    const aPenalty = (authorCount[item.author] || 0) * 0.3;
    const tPenalty = (tagCount[item.mainTag] || 0) * 0.2;
    item.finalScore = item.score - aPenalty - tPenalty;
  }
  sorted.sort((a, b) => b.finalScore - a.finalScore);
  return sorted.slice(0, perScreen);
}
```

---

## 7. API 设计(Workers 路由)

```
POST /events            上报行为 → 写 events + updateInterest
GET  /feed?cursor=...    拉取推荐流(召回→排序→打散→返回)
POST /content           内容入库 → 抽标签 → 写 content_tags
```

`/feed` 主流程伪代码:

```javascript
export async function getFeed(env, userId, now) {
  // 1. 取画像(含懒衰减)
  const interests = await getDecayedInterests(env.DB, userId, now);

  // 2. 多路召回(并行)
  const [follow, tagBased, hot, fresh] = await Promise.all([
    recallFollow(env.DB, userId, now),
    recallByTags(env.DB, interests, now),
    recallHot(env.DB, now),
    recallFresh(env.DB, now),
  ]);

  // 3. 合并去重 + 过滤已曝光
  let candidates = mergeAndDedup([follow, tagBased, hot, fresh]);
  candidates = await filterImpressed(env.DB, userId, candidates);

  // 4. 排序 + 打散
  const scored = candidates.map(c => ({ ...c, score: scoreItem(c, interests, now) }));
  const feed = diversify(scored.sort((a,b) => b.score - a.score), 10);

  // 5. 记录曝光(可异步,写 KV/impressions)
  await recordImpressions(env, userId, feed, now);
  return feed;
}
```

---

## 8. Cron 定时任务

```
每 10–30 分钟:重算 hot_score(近期窗口内的互动,带时间衰减),写回 content + 缓存到 KV
每天:清理 events 超过 N 天的记录;清理 user_interests 中已衰减到阈值以下的长尾标签
```

热门分(牛顿冷却 / 时间窗加权)示例:

```sql
UPDATE content SET hot_score =
  (like_count + comment_count*2 + share_count*3)
  / POWER((strftime('%s','now') - created_at)/3600.0 + 2, 1.5)
WHERE created_at > strftime('%s','now') - 7*86400;
```

---

## 9. 冷启动处理

| 场景 | 策略 |
|------|------|
| **新用户**(无画像) | 注册时让选 3–5 个兴趣标签 → 写入初始画像;否则纯热门 + 新鲜流 |
| **新内容**(无互动) | 新鲜探索路保证曝光;靠标签匹配进相关用户的流 |
| **新标签** | 收敛标签库,尽量不让模型自由造词 |

---

## 10. 演进路线

起步版跑通、数据攒够后,按需加:

1. **协同过滤**:有了足够 `events`,做 item-based CF(看过 A 的人也看 B),作为第 5 路召回。
2. **向量召回(Vectorize)**:内容 embedding 入 Vectorize,用户兴趣向量做 ANN 检索,补语义相似。这是 Cloudflare 栈的自然升级位。
3. **排序模型化**:线性加权 → LR / GBDT / 小型双塔,用真实点击数据训练,替换手调权重。
4. **特征丰富**:加入停留时长、完播率、时段、设备等上下文特征。

> 原则:**先用规则把闭环跑通、把数据采起来,再逐步模型化**。起步阶段算法越简单越好,数据和闭环比算法更值钱。

---

## 附:最小落地清单(MVP)

- [ ] D1 建表(content / content_tags / user_interests / follows / events / impressions)
- [ ] 内容入库 + 标签抽取(先规则,后模型)
- [ ] 行为埋点 API + 画像懒衰减更新
- [ ] 四路召回 + 合并去重
- [ ] 线性加权排序 + 作者/标签打散
- [ ] Cron 刷热门榜
- [ ] 新用户兴趣选择页(冷启动)
