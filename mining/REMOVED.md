# 已删除的死文件（tombstone）

这里记录 `mining/` 下被确认弃用、已删除的文件，方便将来需要时从 git 历史恢复。
**删除前请务必读 STATE.md，确认没有被新链路重新用上。**

## `mine.py`（删于 2026-06-26）

**做什么**：旧的 Python 服务端 miner —— 下载录音 → 火山 ASR → Claude 挖成公众号文章
→ 写回 R2；外加一整套微信发草稿 + 封面逻辑。

**为什么删**：
- **挖矿那半边**早被 Worker 的 `Miner` DO 取代（`~/code/jianshuo.dev/agent/src/miner.js`，
  文件头自己写明「port of mining/mine.py to Cloudflare Workers JS」）。现在挖矿全走
  miner.js（上传触发 + 6 小时 cron + `POST /files/api/mine` → 触发 Worker DO，**不是** workflow）。
  本仓库已没有 `mine.yml`，没有任何东西会跑 `python mine.py`。
- **微信那半边**是 relay（`relay_server.py`）唯一在用的部分，已**内联进 relay_server.py**，
  relay 不再 `import mine`。

**顺手修的 bug**：内联 `md_to_wechat_html` 时，把照片 marker 的正则从只匹配数字的
`[[photo:\d+]]` 加宽成 `[[photo:[^\]]+]]` —— 现在 marker 是 key 形式
（`[[photo:photos/<ts>/<offset>-<rand>.jpg]]`），旧正则会让 key 原样泄漏进微信草稿文字里。

**怎么恢复**：
```
# mine.py 最后存在于删除前的 HEAD（d425fde）
git checkout d425fde -- mining/mine.py
```

## `publish_wechat.py` + `.github/workflows/publish-wechat.yml`（删于 2026-06-26）

**做什么**：旧的「按需发一篇微信公众号草稿」链路。app 点「发布微信公众号草稿」
→ Cloudflare Function `POST /files/api/wechat/<articleKey>` 会 `workflow_dispatch`
触发 `publish-wechat.yml` → 在 GitHub Actions 里跑 `python mining/publish_wechat.py`
（`import mine`，走 `WECHAT_PROXY` 东京代理推草稿）。fire-and-forget，约 1 分钟，
app 拿不到真实结果。

**为什么删**：这条链路已被**同步 relay** 完全取代。现在 Function 的
`/files/api/wechat` handler 直接 `fetch` 东京 VPS 上的 `wechat-relay`
（`mining/relay_server.py`），同步拿到真实 `created/updated`
或 `errcode`。Function 不再 dispatch 这个 workflow，`publish-wechat.yml` 只剩
`workflow_dispatch` 这一个触发器、没有任何东西去触发它 → 整条死掉。
（`mine.yml` 在本仓库已不存在；STATE.md 旧文案里「mine.yml auto-push 还在用」的说法是过时的。）

> 注：删 `publish_wechat.py` 时 `mine.py` 还活着（relay 当时 `import mine`）。同一天稍后
> 把 relay 用到的微信代码内联进了 `relay_server.py`，`mine.py` 也一并删了 —— 见上面 `mine.py` 那节。

**怎么恢复**：
```
# 这两个文件最后存在于 commit c51f796（publish_wechat.py）/ 5ec7343（workflow）
git checkout c51f796 -- mining/publish_wechat.py
git checkout 5ec7343 -- .github/workflows/publish-wechat.yml
```
