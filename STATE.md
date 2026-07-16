# VoiceDrop — project state (read this first)

Last updated: 2026-07-16（邀请好友入口 + voicedrop.cn/i/<码> 落地页上线）

## 归因三修（2026-07-16 排查后落地，jianshuo.dev 6b59c22 已部署冒烟）

「好多人从链接装了但邀请人没反应」排查结论：一周 ~190 新账号仅 6 次归因（4 剪贴板
+2 上线自测）。**主因 = voicedrop.cn 腾讯云反代**：Pages 侧 `CF-Connecting-IP` 恒为
代理出口 IP（实测响应带 `via: 2.0 Caddy`），IP 指纹层对微信分享流量 100% 失效，
7-09 起文章分享页同病。三项修复：

- **第一方 beacon**：`POST /agent/referral/hit`（无鉴权，body=码/分享 id，解析不出
  owner 静默丢）——两个落地页内联 sendBeacon/fetch(no-cors) 让**访客浏览器直连**
  jianshuo.dev 报到，真实 IP 只有这条路拿得到。服务端 refhit 改为只在直连
  （无 x-forwarded-host）时写，反代垃圾停写。
- **剪贴板双保险 + 微信蒙层**：execCommand 同步先行（微信 webview 的
  navigator.clipboard 常不可用）叠 clipboard API；微信内点下载不跳转，弹
  「点右上角→浏览器打开」蒙层（剪贴板照写）。
- **邀请人到账推送**：claim 成功后 sendPush owner「你邀请的朋友装好了，算力 +N」
  深链 voicedrop://usage（复用投喂通道）——此前奖励静默进桶，成功了邀请人也无感。
- 测试：invite-link 23 例 / referral-landing 7 例，全量 1120 绿；线上冒烟：hit 204、
  两落地页含 beacon/execCommand/wx-mask。

## 归因再排查：零拉新 = 三层各有死因叠加（2026-07-16 深夜）

- **在售 iOS 1.3/1.4 不认 `/i/` 邀请链接**：剪贴板正则的 `/i/<码>` 模式 7-16 凌晨才进
  main（testflight/255 有，release/1.4 没有）——公众装的版本对邀请链接剪贴板层全废。
  等下一版上架才通。
- **PostHog「邀请落地页访问」distinct_id 全是同一个人**：id = IP 哈希，反代出口 IP
  恒定。已修（jianshuo.dev 0592eb7 已部署）：反代流量改读 `X-Forwarded-For` 首段
  （真实访客 IP）。⚠️ **X-Real-IP 不可用——Cloudflare 边缘会用连接方 IP 覆写它**
  （实测），XFF 是追加不覆写。落地页响应头 `x-vd-vid` 露出打点 id，`curl -I` 可核对
  （已验证：反代后 = 直连 IPv4 同哈希）。refhits 归因层仍只认浏览器直连 beacon
  （XFF 直打 pages.dev 可伪造，不进给钱的路径）。
- **安卓端其实有 ReferralManager**（houleixx/voicedrop-android，GitHub 代码搜索没索引
  到，别再用它下结论）。但有三坑已在本地修好待交付（分支 referral-invite-links）：
  ① 正则不认 `/i/` 邀请链接；② runOnLaunch 在 Application.onCreate 跑，无窗口焦点
  时 Android 10+ 拒读剪贴板——补了 RecordingsActivity.onWindowFocusChanged 焦点重试；
  ③ AppRouter 没有 INVITE 深链（已装用户点邀请链接开的是网页）。单测 315 绿。
  已交付：houleixx/voicedrop-android **PR #1**（fork jianshuo/voicedrop-android，
  分支 referral-invite-links）——等 houleixx 合并出新 APK 后，`/gh/` 直链要手改
  版本号（见 voicedrop-apk-distribution 记忆）。
- D1 真值（mint kind='referral'）：总共 6 条=2 自测+4 剪贴板（7-11 文章链接×3、
  7-16 凌晨邀请码自测×1）；新账号 20-40/天。IP 层 beacon 7-16 22:04 才上线，
  之前反代流量 IP 指纹 100% 垃圾——零拉新不是单一 bug。

## 邀请好友：设置页入口 + 邀请落地页（2026-07-16，服务端已部署，iOS 已合 main 未发 TestFlight）

referral 二期（补掉 2026-07-09 遗留 ④「主动邀请入口」）。设计稿 = claude.ai/design 项目
`Settings.dc.html`（邀请行）+ `Invite.dc.html`（分享 sheet 1b / 落地页 1c）。

- **邀请码一码两用**：码 = anon sub 前 6 位 hex 大写 ＝ App 设置页显示的账户短码
  （`inviteCodeForScope`，撞码退 10/16 位；非 anon scope 走 sha256 派生）。注册表
  R2 `invites/<码>` = `{owner, name, ts}`，name 每次取链接时从 CLAUDE.json profile 刷新
  （改名传导到落地页）。
- **服务端**（jianshuo.dev repo，worker 423081cc + Pages b83a98d3 已上线冒烟）：
  ① `GET /agent/referral/link`（anon/session 均可）→ `{code, url, name, enabled,
  suanliInviter, suanliFriend}`（奖励 = 面额 × mint-rate 现价，读不到回 0，客户端隐藏数字）；
  ② 落地页 `functions/voicedrop/i/[code].js`——深色品牌下载页（邀请人行/金色奖励条/
  三卖点/双下载键 App Store + jianshuo.dev/voicedrop/apk/，UA 弱化非本机端），访问写
  refhits IP 指纹（归因 2 层）、下载点击写剪贴板（3 层）、大写归一、未知码 404；
  ③ claim 的 `ownerFromToken` 认 `invites/<码>`——归因三层全部直接复用现有 referral。
  测试 `agent/test/invite-link.test.js`（17 例）。
- **分享卡片带 logo（2026-07-16 晚补）**：落地页 og:image/image_src 原来传空 →
  微信卡片空图标。已补 `voicedrop/icon-512.png`（App icon-1024 缩 512 的网页资产，
  两域可访问）+ 落地页拼绝对 URL（反代域 `voicedrop.cn/icon-512.png`、直连域
  `/voicedrop/` 前缀）。commit 56d5e03，Pages 已部署、双域线上验证过。文章/指令
  分享页无照片时仍是无图文字卡（有意保留），要品牌图可复用同一资产。
- **iOS**：设置页「账户·算力」卡下加单独一张「邀请好友」卡（SettingsView），副标题/
  「+N」徽标用现价（`SettingsStore.loadInvite`，0 = 隐藏数字）；点击拉系统分享 sheet
  （复用 SharePayload/ArticleShareItem——微信目标拿裸 URL 出 og 富卡片，其余拿文本）。
  `ReferralManager.shareToken` 新认 `voicedrop.cn/i/<码>` 与 `jianshuo.dev/voicedrop/i/<码>`；
  `AppRouter` 新 DeepLink `.invite(code)`（已装用户点邀请链接 → 记归因第 1 层 → 落 App
  主页，不看下载页）。单测 `VoiceDropTests/InviteLinkTests.swift`（6 例，全量 112 绿）。
- **真机手测清单（发 TestFlight 后）**：① 设置页邀请行出现、+N 数字合理 ② 点击弹分享
  sheet，微信里出「X 邀请你用 VoiceDrop」富卡片 ③ 链接在浏览器开落地页（奖励数字与
  App 一致）④ 新设备装后首启归因成功（invite 码走 link/剪贴板层）⑤ 已装设备点邀请
  链接直接进 App 主页。
- **分享零等待（2026-07-16 用户反馈修正）**：点邀请卡**立即**弹分享 sheet，不等
  loadInvite——邀请码 = 账户短码（anonId 前 6 位 hex，客户端与服务端 sha256 同源派生），
  链接本地拼；服务端回过权威链接（撞码加长极端情形）就用那个。注册表写穿放后台
  （设置页 .task 预取 + 点击时再兜一次）；离线分享的极端窗口 = 落地页暂 404，回线自愈。
- 已知边界：奖励文案「各得」只在双边同额时带数字（当前 9:9）；`enabled:false` 时 App
  仍显示入口（副标题通用文案）——要藏入口就等 loadInvite 加 gate，有意先不做；新增
  中文 String Catalog key 等夜间英文同步。

## 投喂到账推送：文章被投币 → 作者收 APNs，点开进算力账单（2026-07-16）

- **服务端**（jianshuo.dev repo `agent/src/mint.js`）：`POST /agent/feed` 双边
  grantBucket 之后给 `post.owner` 发 `sendPush`——「{投币者} 投喂了《{标题}》，
  算力 +X」，`link=voicedrop://usage`、`threadId=feed`。sendPush 尽力而为
  （缺 secret/无 token 静默 no-op），幂等分支（already）不重复推。
  测试在 `agent/test/mint.test.js`（vi.mock push.js 断言调用参数）。
- **iOS**：`DeepLink` 新增 `.usage`（`voicedrop://usage`，`billing` 也认）；
  LibraryView 新增 `navigationDestination(isPresented: $showUsage) { UsageView() }`
  ——点通知**直达账单页**，不绕设置页。其余深链分支互斥清理 showUsage
  （沿用「链接永远干净落地」约定）。
- 投币者自己不推（动作是他本人发起的）；安卓暂无推送通道，收币照常入账。

## referral 漏斗打点进 PostHog（2026-07-16，已上线）

「为啥没 refer 到人」从此可查。服务端直发四步漏斗（functions/lib/posthog.js，
waitUntil 后台 best-effort，POSTHOG_API_KEY 缺失=整体不打点）：
「邀请落地页访问」「邀请下载点击」（distinct_id=refhits 同款 ipHash，匿名）→
「邀请claim」（distinct_id=新账号 sub，属性【结果】= not-new/no-match/self/already/
归因成功… + ip_hash 关联键，与访问事件串漏斗）→ iOS 已有「邀请归因成功」。
key = iOS 同一只 phc_ 客户端 key（用户授权）：agent wrangler.jsonc vars + Pages
secret 两处。隐私红线不变：只送元数据、IP 只以 HMAC 哈希出现。
查看：app.posthog.com → Activity 筛「邀请」。
背景结论（2026-07-16 排查）：7-11 后零 referral 非 bug——主动邀请入口 7-16 才上线、
归因仅限新账号（重装不算：anon 身份在 iCloud 钥匙串）、CGNAT 放弃、1.3 刚在售。
测试方法：模拟器（钥匙串独立=真新账号）访问 voicedrop.cn/i/<码> → 装 app 首启。

## 锚点协议：长按目标结构化上传，提示词回归自然语言（2026-07-16，服务端已上线，iOS 随本班 TestFlight）

spec = `docs/superpowers/specs/2026-07-16-anchor-protocol-design.md`，plan 同名 plans/。
长按图/文字菜单动作把目标作为 `anchor` 字段随 WS instruct 上传（`{type:"image",key}` /
`{type:"line",line,text:整行原文}`），编辑 DO 队列存列（照 article_index 模式 ALTER 迁移），
`runEditTurn` 校验后 varLines 注入独立上下文行。要点：

- **校验宁缺勿错 + 漂移自愈**：image key 两代格式归一后 membership（legacy `[[photo:N]]`
  数字 token 经 doc.photos[N-1] 解析——final review 抓的 Critical，249a442 修）；line 行号
  +整行原文一致，正文被并发编辑动过时按整行唯一匹配修正行号，失败丢弃不注入。
- **行号口径单一真源** = linenum.js（1-based，与 edit_current_article 工具/iOS bodyRows 同构）。
- **无 anchor = 现状逐字节一致**（回归锁测试）；占位符 {{KEY}}/{{LINE}}/{{QUOTE}} 替换保留，
  双供给无冲突。语音自由指令/回答追问/库级命令无锚点（设计如此）。
- **Phase B 待办**：sys_* 模板改写自然语言（去占位符）——前置=新版覆盖足够（老 App 无
  anchor，模板去占位符会让老 App 多图文章退化）；改模板记得同步 iOS 内置兜底快照。
- 新建提示词输入框有空态引导（自然语言示例）。
- **真机手测清单**：① 多图文章长按第 2 张图选水彩 → 确改第 2 张（金标准）② 长按中间段
  选更简洁 → 确改那段 ③ 自建自然语言提示词（无占位符）多图精确命中 ④ 老提示词（带占
  位符）行为不变 ⑤ 语音自由指令回归。

## 提示词社区帖：分享即发帖 + 社区「提示词」tab（2026-07-15，服务端已上线，iOS 待真机手测+TestFlight）

spec = `docs/superpowers/specs/2026-07-15-prompt-community-posts-design.md`，plan 同名 plans/。
SDD 执行记录在 `.superpowers/sdd/progress.md`。**服务端已部署**（agent worker 36190a31 /
reco d785d93e / Pages 3a45768e，D1 migration 0003 已 apply），线上冒烟过：feed 115 帖带
kind=article、匿名 403、新 MCP 工具可用。iOS 4 个 commit 已合 main **未发 TestFlight**。

- **数据模型**：提示词帖 = `community/<shareId>.json` 的 `kind:"prompt"` 变体
  （`promptCode` 指向 `shares/<码>` 写穿副本，内容零复制实时读）；
  `shareId = HMAC("promptshare:<码>")` 从码派生（fork re-key/复活全自动成立）。
  D1 community_posts 加 `kind` 列，reco feed / community/list 双路径透传。
- **同生同死（四条路径全闭环）**：开分享=铸码+发帖；关分享/社区取消分享/举报
  resolve-remove/销号——都连 `shares/<码>` 一起删（后两条是最终全分支 review 抓的漏，
  aca6df2 修）。再开=同码同帖复活（firstSharedAt 重置，计划明文接受）。
- **门槛收紧（产品决策）**：POST /agent/prompt-share 需 Apple/微信 session，匿名 403
  needs_apple_signin——**匿名不再能铸码**。铸码前 checkArticlesShareable 关键词审核。
- **老 App 兼容**：community/get 对 prompt 帖合成 `articles:[{title:label,body:全文}]` +
  kind + promptCode，老客户端当文字帖渲染（可读/投币/回应，无导入按钮）。
- **iOS**：CommunityFeedView 四 tab（推荐/最新/回应/提示词，混排+客户端过滤）+
  TextCoverCard「提示词」角标；CommunityPostView「收下这条提示词」CTA（gate:
  kind=prompt && promptCode && !mine，走 PromptStore.shared.importPrompt）；
  PromptEditView 开关文案改「分享到社区」，403 拉起 Apple 登录重试一次
  （二次拒绝返回可见错误，不伪装成功——review 抓的竞态）。
- **真机首测后的修复轮（2026-07-16，四个包：a095346/32067ff/09e575d/470227c + 服务端两轮提速）**：
  ① feed 行映射漏 kind →「提示词」tab 恒空（FeedRow→CommunityPost 手工映射，**加字段
  必须三处同步**，代码里有警示注释）；② 分享失败文案按服务端错误码映射（笼统「操作失败」
  掩盖过 413/审核/401 排障）；③ 提示词帖详情页对齐落地页形态（分享码+内容盒+怎么用——
  合成 articles 只是老 App 降级，不是新版展示）；④ 开关闪烁 = 先放开 toggle 再刷状态的
  时序反了；⑤ **开分享 10 秒 = 15 个串行存储操作积垢**（必需仅 5：读树/读索引/验码/写索引/
  写副本；3 个读的是生产不存在的运营配置；发帖四连挪 waitUntil；黑名单预取并行+首铸跳
  importCount 保护读）——关键路径现 ~3 个来回。教训：每个功能各加一两跳没人算总账。
- **⚠️ token 坑（2026-07-16 真机 bug，a095346 修）**：`AuthStore.bearer` **永远是
  anonToken**（Apple 登录后也不变），登录证明在 `AuthStore.shared.session`（JWT）。
  任何要过「可追责身份」门槛的请求（社区写、prompt-share）必须送 `session ?? bearer`
  ——CommunityStore.shareToken 与 PromptLogic.shareAuthToken 都是这个式子。只送
  bearer 会 403 needs_apple_signin 且拉起登录也救不回（重试还是送 bearer）。
- **已知缺口：MCP 的 share_prompt 对所有人 403**——配对登录发的是 anon 型完整密钥，
  不是 session JWT，服务端无从验证 Apple 绑定（绑定不落盘，session 即证明）。要解得
  另立项（配对流程发 session / 服务端持久化绑定标记），暂记录。
- **真机手测清单（发 TestFlight 后必跑）**：① 开分享→社区三处立见（推荐/最新/提示词
  tab，卡片带角标）② 另一账号打开→全文+收下→长按菜单立即可用 ③ 投币/文章回应
  ④ 关开关→帖码同消（feed+短链「分享已停止」）⑤ 再开→同码同帖 ⑥ 匿名翻开关→
  拉起登录→重试成功 ⑦ 老版本 App 打开 prompt 帖当文字帖可读 ⑧ 自己的帖无导入按钮。
- 已知边界（有意不做）：删除提示词条目不自动关分享（帖码冻结，与码现状一致）；
  D1 挂时 R2 慢路径 prompt 卡无题无预览（窗口期展示降级）；导入成功双埋点
  （「社区提示词导入」+「提示词导入码兑换」，分析时注意）；4 个新中文 key 待夜间
  英文同步收敛。

## PostHog 产品分析已接入（2026-07-14，模拟器验证事件已送达）

- SPM 包 `posthog-ios`（project.yml `packages:`，from 3.0.0）；初始化在
  `Analytics.swift`（`VoiceDropApp.init()` 调用），host = US cloud。
- **key 链路**：`Secrets.xcconfig` 的 `POSTHOG_API_KEY` → project.yml info
  properties `PostHogAPIKey: $(POSTHOG_API_KEY)` → Info.plist 构建期替换 →
  `Bundle.main` 读取。**key 缺失/为空 = PostHog 整体不启用**（guard 直接 return，
  App 行为不变）。CI 侧 build.yml 重建 Secrets.xcconfig 时从 GitHub secret
  `POSTHOG_API_KEY`（已 gh secret set）写入——改 Secrets 相关内容记得三处同步：
  本地 xcconfig / Secrets.example / build.yml。
- DEBUG build 开 `config.debug`（console 可见每条事件上送日志）；Release 不开。
- 看数据：app.posthog.com → Activity。
- **identify（2026-07-14 二期）**：`Library.ownerScope()` 的 /whoami 成功后剥出 sub
  调 `Analytics.identify(sub)`（LibraryView 启动 task 顺手触发一次保证每次启动都走到）；
  `AppleAuth.signOut()` 调 `Analytics.reset()` 防串号。
- **手动埋点约 24 个事件（中文事件名）**，统一走 `Analytics.capture`。
  **隐私红线（隐私政策已对外承诺，加新埋点必须遵守）：只送元数据
  （类型/时长/计数/布尔），任何用户内容——正文/指令文本/转写——绝不进 PostHog。**
  分布：录音（开始/完成/失败/拍照/上传完成/上传失败，RecordSession/Uploader）、
  采访（开启/结束，RealtimeInterviewer）、语音编辑（发起——普通修改/回答追问/库级命令
  + 落地含耗时秒与成败，AgentSession/LibraryCommandSession）、原位编辑完成、
  文章打开、追问（回答/跳过）、分享（创建分享链接/发公众号/小红书导出）、
  社区（发到社区/取消分享/投币/社区互动/社区浏览 tab）、提示词（保存/分享开关/导入码兑换）、
  邀请归因成功、登录完成。
- **上下文 super properties（2026-07-15）**：`Analytics.screen(名, stem:)` 把
  「当前界面」「当前录音」注册成 super properties，之后**每条**事件自动带上——
  任何动作都能回答「用户当时在哪个界面、看哪条录音」；同时记「界面进入」事件
  形成动线。挂载点 5 个：录音列表（onAppear，回列表即清「当前录音」）、
  录音详情（带 recording.stem，时间戳文件名非内容）、社区、提示词管理、账户。
  加新界面时记得挂 `.onAppear { Analytics.screen("<名>") }`。
- **隐私政策已同步披露**（jianshuo.dev repo `voicedrop/privacy` + `voicedrop/en/privacy`，
  2026-07-14 已部署）：删掉了「没有第三方分析」旧承诺，新增 PostHog 条目。
  App Store Connect 隐私标签已由用户手动更新（2026-07-15）：新增「标识符→用户 ID」+
  「使用数据→产品交互」，均关联身份、用途=分析、不用于追踪（无需 ATT）。

## 键盘精修 v2：长按菜单「编辑」→ 原位编辑（2026-07-14，用户拍板重做后上线）

v1（PR #9 / commit `cc13560`）真机错误百出当天 revert（`50bd5b0`）后，用户明确
要求按新约束重做：**长按的所有 behavior 不变；编辑全程排版零变化；编辑完恢复
阅读态**。v2 实现（`InlineParagraphEditor.swift` + RecordingDetailView 最小改动）：

- **入口**：长按菜单 localRows「拷贝」下面加「编辑」。长按手势本身一行没动
  （v1 的教训：为拿触点坐标改成 sequenced 手势，菜单从「按住即弹」变成
  「松手才弹」——这就是行为回归，别再犯）。
- **排版零变化**：无描边框/出血/内边距/淡出；UITextView 与只读 Text 逐项对齐
  （16pt / lineSpacing 9 / 零 inset / 同色），`sizeThatFits` 按提议宽度自适应；
  编辑态顶栏「取消/完成」frame 锁 40pt 与平时工具栏同高。只有目标段被键盘盖住
  时才 `scrollTo(anchor: nil)` 最小滚动。
- **光标**：不做「落在长按点」（v1 的坐标换算是 bug 之源）；光标落段尾，
  点哪儿改哪儿全走 UITextView 原生行为。
- **数据层**（沿用 v1 已验证部分）：`ArticleBody.replacingLine` 按 bodyRows
  同一套「文字游程+图片标记各占一行」切分精确替换单行；`LibraryStore.saveArticles`
  现拉服务端原始 JSON 只 merge `articles` 一个 key 再 PUT（`ArticleDoc` 没建模
  `schema`/`status`/`model` 等字段，整 struct 重编码回传会冲掉它们——所有对
  `PUT /articles/<stem>` 的部分更新都必须走这个套路）；该端点不经 LLM、自动铸
  版本，undo/redo 天然可用。单测 `ArticleBodyLineReplaceTests`（9 例）。
- 编辑中锁交互：长按文字/图片菜单不弹、章节 chips `allowsHitTesting(false)`、
  说话条隐藏（退出恢复）。
- 教训存档（与 2026-07-12「实时预览 UI 已撤销」同款）：自绘手势 + UIKit 桥接的
  交互，模拟器/单测全绿≠能用，**必须真机手测过再发**。v2 经用户本地验证后才 push。

## 性能改造第二轮（2026-07-13，API 速度体检后落地）

服务端（jianshuo.dev repo）四连改 + 本 repo 一处，全部已上线实测：

- **community/list、community/replies 走 D1 展示索引直出**（7s → 0.2-0.3s），
  响应后 waitUntil 全量对账（reconcileIndex，与 admin reindex 共用）。
- **GET /articles 列表索引直出**（1.0-1.7s → ~0.45s）：article-store 四个写入口
  收口到 putArticleDoc 同步维护 articles-index.json；R2 listing 权威、退到
  waitUntil 对账。community/get 的索引自愈回写也挪进 waitUntil（0.85s → ~0.55s）。
- **GET /recordings 轻量录音列表**（新路由，~0.5s）：recordings-index.json
  （上传/直删 .m4a 同步维护）+ articles-index 的 sidecar 标记（empty/blocked/tags，
  /empty /blocked 路由与 .tags 上传/删除同步点亮熄灭）并发直出四个状态位。
  教训：delimiter listing 在 R2 内部仍要扫过全部 key（1.0-1.6s），不能放请求路径。
- **照片缩图归服务端（2026-07-14 定案，别在客户端缩图）**：jianshuo.dev zone 已开
  Cloudflare Images Transformations，展示面小图走
  `/cdn-cgi/image/width=512,quality=60/files/api/photo/<key>`（218KB→33KB，边缘缓存
  后 0.15s）。iOS 的 preferThumb 即这条路，zone 开关关掉时自动回退原图；安卓/网页
  以后同样拼这个 URL，客户端一律不做缩图、不传 .thumb 文件（曾试过端上旁挂
  .thumb.jpg，已撤销并清光 R2 遗留）。计费：5,000 唯一转换/月免费，超出 $0.50/千，
  当前量级 $0。PhotoService 另有磁盘缓存（photo key 不可变→永久可信）治重复下载。
- **本 repo：Library.loadOnce 首选 GET /recordings**（fetchRecordingRows），
  老服务端没有该路由 → 自动回退全量 GET /list 客户端自筛（老行为原样保留，
  ListResponse 别删）。/list 接口继续存在：老版本 App、24h 只读 token、Mac
  入库管道还在用，只是新 App 主界面不再碰它。

## 性能改造（2026-07-12，性能审计后落地）

三处结构性提速（jianshuo.dev repo 两处 + 本 repo 一处），审计结论：瓶颈在服务端，iOS 端整体健康。

- **Miner 按用户分片**（`agent/src/index.js` + `miner.js`）：上传/用户触发 →
  `idFromName("miner:<scope>")`，每个分片只 list 自己用户的前缀、只挖自己的录音——
  一个用户的长录音不再阻塞其他所有人；10s resume pass 不再全量扫桶。原单例
  `"miner"` 降级为 sweep 调度器（6h cron/admin 手动）：整桶 list 一次、把有活的
  scope 踢给对应分片，自己绝不挖矿（sweep 与分片因此不可能双挖同一条录音）。
  ops 错误计数照旧在单例。测试 `mine-sharding.test.js`。
- **GET /articles 列表摘要索引**（`functions/files/api/[[path]].js`）：per-user
  `users/<sub>/articles-index.json`，稳态 = prefix list + 1 次索引读，不再每篇
  整档 GET（schema-3 信封含 10 版正文+全文转写，此前只为取标题全读）。索引是
  **自愈缓存、只由该路由维护**：R2 listing 为准，etag 变了才重读该篇，删除自动
  剪除，坏了整体重建；所有写入方零改动。**transcript 保留在文章 doc 里（用户
  拍板不拆）**。注意 iOS 列表刷新走的是 `GET /list`（纯元数据），此索引主要提速
  网页文章列表/admin。测试 `articles-index-cache.test.js`。
- **iOS 详情页正文解析缓存**（`RecordingDetailView.swift` BodyParseCache）：
  bodyRows 的正则分段 + 每段 AttributedString(markdown:) 曾在每次重绘（按住说话
  开/关、高亮淡出）整篇重跑；现按 (body, photos) memoize，重绘 = 字典命中。
  引用类型 @State，body 求值中改内容不触发失效循环。

## ⚠️ 实时预览 UI 已撤销（2026-07-12 晚，用户拍板）——但服务端流式基建保留

正文内打字机（行级替换/插入 + 整篇幽灵稿）在真机上引入多个难预料的布局 bug，
用户决定撤销**全部预览渲染**（7a67fcd）：编辑/重写回到「一次性出结果」。
**别在没有用户明确要求时重新引入预览 UI。** 保留的部分：
- 服务端全部照旧（流式调用是 524 修复的根基；preview-delta/edit-preview 照发，App 忽略）；
- AgentSession 的预览消息解析（回调未挂 = 忽略）；
- preview-done → finishRestyle 双路收尾（长文重写超 HTTP 超时也能落定）+ restyle 300s 超时。

## 已撤销的原设计（存档）：编辑实时预览全家桶（2026-07-12，服务端仍在线 + E2E 实测）

LLM 调用全面改流式（anthropic.js 永远 stream:true，SSE 内部聚合、调用方零改动），
由此解锁三层实时预览 + 修复超长录音挖矿事故链：

- **524 根因修复**：非流式被 Anthropic 门口的 Cloudflare ~100s 掐线;2h12m 录音
  (4万字转写)168s 生成必死。流式后一次成功——那条录音已挖出 13 篇文章。
  连带:ASR checkpoint(.asrdone.json,完成即落盘,失败重试复用不重扣费,
  asrCharged 按 stem 终生一次)、连续失败熔断(5 次→.blocked(mine-failed)+
  admin 推送)、挖矿 max_tokens 8000→24000(截断报人话错误)。
- **重写幽灵稿**（/agent/restyle + write_article 工具）：preview-delta/reset/done
  经详情页 WS 广播,App 显示流式长出的新稿;preview-done 兜底 HTTP 超时收尾。
- **行级打字机**（edit_current_article 工具）：edit-preview {i,op,line,text},
  App 底部卡片显示「第 N 行 · 改写中」+ 流式新文本。
- **relay 透传**：中转 DO 把 SSE 原样管回,调用方聚合——地域封锁用户同样有增量。

核心部件 agent/src/preview.js（PreviewExtractor/EditOpsExtractor：JSON 流里剥
纯文本,任意 chunk 切断安全;makePreviewPusher/makeEditPreview 合批广播）。
E2E:重写 93 批增量/2107 字符,编辑打字机 replace_line 增量+updated 全过。

## 已上线：Prompt Manager 重构 Phase 1 —— ref/fork 模型服务端（2026-07-14 部署）

提示词后端整体换模型。spec = `docs/superpowers/specs/2026-07-13-prompt-manager-redesign.md`，
plan = `docs/superpowers/plans/2026-07-13-prompt-manager-phase1-server.md`。
**PR jianshuo.dev#22 已合（cf4b668），worker 版本 `f4cd16cd` 已部署。线上冒烟全过：
`GET /agent/prompts` 200（sys_* items）、三个老端点 404、公开导入预览查无码 404、无 token 401。**
⚠️ 冒烟时发现历史遗留（非本次引入）：**worker 的 `FILES_TOKEN` secret ≠ Pages/`~/code/.env` 的那份**
——老 admin 路由 `/agent/usage/admin/accounts` 用本地 token 也 401。admin 类路由（registry/usage admin）
要用 worker 自己那份 secret；prompt.jianshuo.dev 调优页自带正确 token，不受影响。要统一就
`wrangler secret put FILES_TOKEN`。

- **核心 = ref → fork**：模板 `agent/src/prompt-template.js`（R2 `config/prompt-template.json`
  可整体覆盖，**生产上当前两个 config 文件都不存在（404），代码字面量即真源**）+ 每用户
  `users/<sub>/prompts.json`。每项 `{"ref":"sys_*"}`（跟随模板最新）或完整实体（冻结，
  `forkedFrom` 标记 fork 来源）。**没有 prompts.json = 全跟随** → GET 绝不为新用户落盘（落盘=冻结）。
- **老语义 id（voice-editor.longpress.*）与 `/agent/ui-config*` 全部删除**。部署后老 app：
  长按菜单静默退内置默认（UIConfigStore.refresh 失败=保留现值，不崩）、老设置页「提示词」报
  加载失败。已确认接受；Phase 2 iOS 要紧跟。
- **端点**：`GET/PUT /agent/prompts`（写只有整树 PUT）、`POST /agent/prompts/{restore-defaults,import}`、
  `GET /agent/prompt-share/<code>`（**公开**导入预览，author 无名回空串）。`prompt-registry`
  改读写 `config/prompt-template.json`（对外形状不变）。铸码走新解析器 → **自建提示词第一次可分享**；
  PUT 保存活同步分享中的条目。老魔法数字继续能兑换（写穿副本不依赖 itemId）。
- **prompt-classify 已砍**（2026-07-13 用户拍板，实现过又删）：新建默认「都行」，无 AI 建议。
- **Phase 2（iOS）未做**，spec §9。**服务端遗留给 Phase 2 的三件事**（终审发现，记在
  worktree `.superpowers/sdd/progress.md`）：① 分享状态读端点（老的随 ui-config/custom 死了，
  PromptEditView 分享卡需要；用 POST 试探会把已关的分享复活）；② fork 一条正在分享的 sys_* 条目会让
  分享码永远停在旧内容（需设计决策：fork 时 re-key 或客户端转移）；③ registry PUT 无 MAX_PROMPT 上限（admin-only）。
- 对抗性 review 全程抓出 **12 个真实缺陷**（校验器可被 5MB 载荷打穿/会 throw 成 500、恢复默认重复
  补条目/超 200 上限、匿名作者显示成机器码等），全部修复 + 回归测试。计划文档已同步修正。

### Phase 2（iOS）——已上线（2026-07-14）：PR #24 已合并部署（worker `97c94d38`），iOS 合 main 后经 workflow_dispatch 发 **TestFlight build 99**

> ⚠️ 发版规矩（2026-07-09 起）：**push main 不会自动发 TestFlight**——commit message 带 `[tf]`
> 或 `gh workflow run build.yml -f destination=testflight` 才上传（苹果 ~20 包/24h 限额）。CI 绿 ≠ 出包。

### 第 6 轮拖拽（6a–6d）——分支 `prompt-drag-6a6d`，2026-07-14

handoff `design_handoff_prompt_manager 2/`。Phase 2 Task 7 的原生 `onMove` 排序**作废**，换全自定义拖拽：

- **`PromptDragEngine.swift`（新）**：纯几何逻辑（无 SwiftUI），`RowFrame`/`DropTarget`/`Scope`；
  `dropIndex`（手指 Y + 行帧 → 落点：同域排序 / `.intoGroup` / `.outOfGroup`）+ `apply`（落地，
  委托 `PromptLogic.moving*`）。24 个单测（含嵌套源不重复、两级封顶双保险、空组/边界）。
- **编辑态**（`PromptManagerView.swift` 重构）：普通态仍是 List（左滑删除等全保留）；编辑态换
  ScrollView+VStack——行帧经 PreferenceKey 收集（named coordinate space），**≡ 左手柄是唯一拖动
  发起点**（`DragGesture` 挂手柄上），拖起行画在 overlay 跟手（1.03 + 抬起投影；悬停 folder 加码
  1.04 + rotate -1°）。落点 = 44pt 琥珀虚线缝隙。folder 悬停 **0.3s** 张口（`#FBF3E9` 底 + `#D8A25B`
  边 + 4px 外发光环 + 图标变 `folder.badge.plus` + 「放进「X」」「松手收纳」）；拖组内行时 folder 卡
  下方出「移到分组外」落点区（接受域 = 组跨度之外任意处，落点=folder 之后——比设计字面更宽容，有意）。
- **手势生命周期**（review 抓的坑）：拖动中源行**高度塌 0 但保留视图身份**（从 ForEach 移除会杀死
  进行中的手势 → 浮层卡死）；换行拖动有 takeover guard；scenePhase 离开 active 强制复位。
- **known trade**：无拖动自动滚屏（列表典型 15 行，200 封顶）；dwell 计时在 View 层（Task.sleep，
  计划许可）；真机 QA 必测项=组内排序/收纳/拖出全链路 + 0.3s 手感。
- 数据层零改动（draft + 整树 PUT + baseline 冲突检查全复用），服务端零变更。

spec = `docs/superpowers/specs/2026-07-13-prompt-manager-redesign.md` §9，plan =
`docs/superpowers/plans/2026-07-14-prompt-manager-phase2-ios.md`（分 8 个 task，TDD，
逐 task 提交在 `prompt-manager-phase2` 分支）。Task 8（本次）删掉最后的老文件、跑完全量验证。

- **新文件**：`PromptStore.swift`（整树模型 `PromptNode`/`PromptAnchor` + 网络层 GET/PUT
  `/agent/prompts` + `restore-defaults`/`import` + 按 `appliesTo` 过滤出长按菜单用的
  `UIMenuConfig`——挪进 `ConfigMenu.swift` 消费，视觉不动）；`PromptManagerView.swift`
  （设置 → 提示词，新列表页，替换老 `InstructionSettingsView`；支持 5a 分组展示/1b 左滑删除/
  1d+1a 拖动排序含拖进分组/4a 新建入口）；`PromptEditView.swift`（编辑单条，两个开关+分享卡，
  分享卡 UI 从老 `InstructionSettingsView` 原样搬来）；`PromptNewSheet.swift`（新建提示词，3c，
  默认「都行」无 AI 分类建议——分类功能已在服务端砍掉）；`PromptImportSheet.swift`
  （导入码流程，4b）。**`VoiceDropTests` target 是本仓库第一个单测 target**
  （`VoiceDropTests/PromptStoreTests.swift`，68 个用例，覆盖模型/过滤/reorder/fork/merge 逻辑），
  项目由 xcodegen 生成，`project.yml` 的 `VoiceDrop.scheme.testTargets` 已声明；跑法：
  `xcodebuild test -project VoiceDrop.xcodeproj -scheme VoiceDrop -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:VoiceDropTests`
  （新增 `.swift` 文件后照例先 `xcodegen generate`）。
- **删除**：`UIConfigStore.swift`（Task 3，随长按菜单切到 PromptStore 一起删）、
  `InstructionSettingsView.swift`（Task 8，本次；分享卡 UI 已在 Task 5 原样搬进
  `PromptEditView.swift`，`ShareCodePayload`/`shareAction` 两边都是 `private`，删除前
  grep 全仓确认零外部引用）。
- **PromptStore 三级回退**：network（`GET /agent/prompts`）→ `UserDefaults` 本地缓存
  （上次成功拉取的整树）→ **内置兜底**（客户端字面量镜像服务端 `prompt-template.js` 的
  `sys_*` 默认值）。⚠️ **服务端模板字面量变了，客户端内置兜底不会自动跟着变**——iOS 这份
  是手抄的快照，改服务端默认提示词时记得同步改这份，否则断网用户（第三级）看到的是旧默认值。
- **fork-on-edit 语义**：编辑一条 `{"ref":"sys_*"}` 系统条目 = 客户端把它实体化成完整节点
  （`forkedFrom` 记来源），整棵树 PUT 落盘；分享码跟着走：PR jianshuo.dev#24
  `prompt-shares-readapi` 分支的 `rekeyForkedShares` 在服务端 PUT 保存时把 `shares/<码>`
  的 owner 索引从老 ref id 挪到新 fork id（码不变），随后现有的「保存时刷新分享内容」同步
  把 fork 后的新文本写进码。「恢复默认」= 整体丢弃 fork 换回 ref（未做单条粒度恢复，spec
  原说的按钮简化为整体操作，视为有意裁剪，见 Task 8 brief 的 Self-Review）。
- **菜单 = 从同一份列表客户端过滤**：`ConfigMenu.swift` 不再单独打一次网络请求，而是吃
  `PromptStore` 拉回的整树，按每个节点的 `appliesTo`（文字/图片…）本地过滤出对应长按菜单，
  长按文字菜单和长按图片菜单是同一份数据的两个视图，新建/编辑/删除立刻反映到两边。
- **AppRouter 7 位数字深链**：`https://voicedrop.cn/<7位魔法数字>` → `.promptImport` case →
  落 `PromptImportSheet`（与老的「AI 指令」魔法数字兑换页复用同一套 7 位码解析器/正则，
  只是落地视图从老设置页换成新 Prompt Manager 的导入 sheet）。
- **reorder = 本地草稿 + 整树 PUT**：拖动排序全在本地维护一份草稿树（`PromptStore` 的
  moving 系列纯函数，68 个单测里大头是这些——跨分组拖动、分组进分组拒绝、越界 clamp 等），
  松手才整树 PUT 落盘；PUT 带 baseline 冲突检测（保存前服务端整树若已变化于本地拉取时的
  快照，拒绝覆盖，避免多端并发排序互相打架——具体冲突提示见 `PromptStore.swift` 内注释）。
- ⚠️ **发版顺序硬约束**：iOS **不能在 jianshuo.dev PR #24（`prompt-shares-readapi`，
  截至 2026-07-14 仍 OPEN，未合并未部署）落地前上 TestFlight**——`PromptEditView` 的分享卡
  读分享状态靠 `GET /agent/prompt-shares`，这个端点是 PR #24 加的；没它，分享开关在新
  设置页会读不到状态（老的 `ui-config/custom` 里的 `shareCode`/`sharing` 字段已随 Phase 1
  删除）。同理 fork 后分享码保活也靠 PR #24 的 `rekeyForkedShares`，没部署的话 fork 一条
  正在分享的系统条目会让分享码停在 fork 前的旧内容。
- **手测清单**（人工 QA，见 `.superpowers/sdd/task-8-report.md`；模拟器脚本能力有限，
  交互手势必须真人跑一遍）：① 设置→提示词打开新列表（不再「加载失败」）② 长按文字/图片
  菜单 = 过滤视图，新建的文字项立刻出现在长按文字菜单 ③ 编辑一条系统项 → 徽标变「已自定义」
  → 长按菜单吃到新文本 ④ 删除 → 恢复默认能找回 ⑤ 导入码全流程（需 PR #24 部署）⑥ 分享
  开关 + fork 后码不变（需 PR #24 部署）⑦ 断网 → 长按菜单仍能渲染（内置兜底）⑧ **在展开的
  分组内部重新排序**（nested onMove，本轮最担心的风险点）⑨ 把一个动作拖进分组；分组内条目
  「移出分组」左滑；分组拖进分组应被拒绝 ⑩ 深链 voicedrop.cn/<7位码> 落到导入 sheet。

## 新功能：指令分享码「魔法数字」（2026-07-11，服务端已上线，真机手测通过，TestFlight 已发）

**2026-07-11 验证与部署（Mac 侧）**：agent 全量 75 文件 731 用例绿；iOS xcodebuild
BUILD SUCCEEDED（含改名后二次构建）；jianshuo.dev 分支已合 main 并部署——worker
版本 ded919c4 + Pages（jianshuo.dev/voicedrop/<码> 与 voicedrop.cn/<码> 均已线上
冒烟：查无码 404「分享已停止」）。**产品措辞全面改名「AI 指令」→「提示词」**
（用户拍板）：iOS 设置入口/编辑页（我的提示词/默认提示词）/分享卡「分享这条提示词」/
分享文案/String Catalog 七个 key（英文同步 prompt 措辞），服务端落地页/注入块
（【分享提示词开始/结束】、回复提「分享提示词」）/测试断言。R2 config/prompt-share.json
未 seed（走代码默认值，需要调再 seed）。iOS 已随真机手测通过合入 main 发 TestFlight。

用户在 设置 → AI 指令 → 编辑页开「分享这条指令」开关 → 得 7 位数字码（同时就是
voicedrop.cn/<码> 短链）；别人语音里说「用 <码> 改这段」→ 服务端识别、把共享指令
一次性注入本轮 prompt（不改使用者设置）。spec =
`docs/superpowers/specs/2026-07-11-prompt-share-magic-number-design.md`，plan 同名。
两仓库同分支 `claude/ai-instruction-storage-8jf5u2`（jianshuo.dev + voicedrop）。

- **一个注册表**：`shares/<码>` 与文章分享同命名空间——文章条目值是纯文本
  articleKey，指令条目是 typed JSON **写穿副本**（label+instruction 当前生效文本）。
  保存指令时 `ui-config-custom.js` 经 `refreshPromptShare` 同步重写（活绑定）；
  开关关 = 删 `shares/<码>`，owner 索引 `users/<sub>/prompt-shares.json` 保留 →
  再开**同码**复活。已知边界：运营改全局默认不推送到已分享的未自定义条目。
- **服务端**（jianshuo.dev）：`agent/src/prompt-share.js`（POST/DELETE
  /agent/prompt-share，铸码撞重摇、日上限/长度/开关走 R2 `config/prompt-share.json`
  `{enabled,dailyCapPerUser:20,maxLength:4000,notFoundNote}`）；兑换识别在
  `edit-turn.js`/`command-turn.js`（正则 `(?<![0-9])[1-9][0-9]{6}(?![0-9])`，先做
  ASR 断句归一，8 位+/首位 0 不命中，每轮取首个；查无注入软备注）；落地页
  `functions/voicedrop/[token].js` prompt 分支（纯数字码查无 → 「分享已停止」404）。
  GET /agent/ui-config/custom 每条多 `shareCode`/`sharing` 两字段。
  测试：`prompt-share.test.js`(31) + `prompt-share-landing.test.js`(5) + 两 turn 各 2；
  全量 75 文件 731 用例绿。
- **iOS**：只改 `InstructionSettingsView.swift`（分享卡 + setSharing + ShareSheet
  文案）。兑换侧零 iOS 改动（老版本 App 服务端部署后立即可用）。
- **部署顺序**：先 agent worker + Pages（`npx wrangler deploy`），可选 seed
  config/prompt-share.json，再 iOS TestFlight。
- **真机验证**（2026-07-11 全部通过）：① 开关 → 出码/关码/再开同码；② voicedrop.cn/<码> 落地页样式与
  「分享已停止」；③ 改文本保存后落地页（≤5min 缓存）与兑换同步；④ 另一账号语音
  「用 <码> …」按共享指令执行、回复提指令名、设置不变；⑤ 断句「123，4567」命中、
  错码回复无效、库级命令同样生效。**Linux 容器没跑过 xcodebuild，iOS 需先真机构建。**
- 二期挂起：VD社区原生提示词帖、一键导入收藏、中文数字码。

## 最近改动：社区列表页改 D1 索引后台（2026-07-14，已上线）

社区展示页后台从「R2 全量扫描」换成「reco 的 D1 物化索引」。**R2 community/*.json
仍是真源**，D1 表 community_posts 只是可全量重建的展示索引：

- **新端点 `GET /reco/feed`**（reco worker）：一次带回 列表元数据+推荐序+每帖红心/
  回应数+我赞过的。替代 app 老的 list(每帖2次R2读) + rank 两步。线上实测 106 帖
  0.23s，与 R2 list 逐项校验一致（ids/标题/封面/时间序零差异）。
- **双写**（files API，Pages 侧新增 RECO_DB 绑定=voicedrop-reco 同库）：share upsert /
  unshare delete / report hidden=1 / resolve 同步 / 销号 delete-by-owner / 孤儿 reap
  连索引删。**详情打开(community/get)顺手 upsert**——文章编辑后 feed 的过期卡片靠
  这个自愈。索引写失败一律吞掉不打断主路径。
- **重建**：`POST /files/api/community/reindex`（admin，FILES_TOKEN 在 ~/code/.env），
  幂等，回填/漂移兜底用。首次回填 indexed:107。
- **iOS**：`CommunityStore.load()` 首选 loadViaFeed()，失败/空索引回退老路径
  loadViaListAndRank()（R2 list + rank，兼容老服务端）。
- 已知边界：文章编辑不直接写索引（agent worker 挖矿/编辑不碰 D1），靠详情打开自愈
  ＋ reindex 兜底；如嫌不够，可给 agent 5min cron 加一次 reindex 调用。
- 迁移：reco/migrations/0002_community_posts.sql（已 apply --remote）。

## 最近改动：社区改双排瀑布流（2026-07-13，已上线服务端，iOS 待发版）

按 ~/Downloads/design_handoff_community_feed 方向 1a（小红书式图文混排）重做社区列表页：

- **iOS**：新文件 `CommunityFeedView.swift`（两列贪心 masonry；照片帖图封面高度随原图
  宽高比，文字帖三色暖渐变封面按 shareId hash 取色；标题细体不加粗——用户拍板；元信息行
  = 头像+作者+红心被赞数(常显)+回应数(>0)；回应帖 ↩ 胶囊角标；推荐/最新/回应分段 tab）。
  `LibraryView.communityContent` 的旧单列 List 已删，取消分享从侧滑改长按 context menu。
  「最新」= store.timeOrdered（服务端时间序快照，不经 reco）；「推荐」= reco 排序。
  曾做过「最新」专属单列时间流，用户拍板 revert——两 tab 同一副瀑布流、只差顺序。
- **服务端（都已部署）**：① Pages `functions/files/api/[[path]].js` community/list 每帖补
  hasPhoto/coverPhotoKey(完整 R2 key)/preview(前60字纯文本)——列表卡片素材一次带齐，
  客户端绝不该为每卡拉 fetchPost；② reco worker rank 响应加 likes(每帖被赞数) 给红心。
- **事故修复（2026-07-13）**：社区过百帖（106）后 reco 的 `IN (?,…)` 超 D1 100 绑定参数
  上限 → rank 整条 500 → app 静默回退（推荐==时间序、红心全 0）。修法：countsFor/likedBy
  按 90 分块合并；test/fakes.js 的 fake D1 bind 复刻 100 上限让单测能抓住此类回归。
- 设计稿里的顶栏大标题「社区」+搜索按钮没做（app 有自己的 tab 栏，搜索无行为定义）。

## 最近改动：采访员 prompt 按 OpenAI realtime 指南重构（2026-07-12，已部署）

`agent/src/realtime.js`（jianshuo.dev repo）的 INTERVIEWER_INSTRUCTIONS 从一段稠密硬约束
长句改成分节结构（角色/语气/何时不说话/怎么问/语言/听不清），依据
https://developers.openai.com/api/docs/guides/realtime-models-prompting ：

- **删「停顿超过三秒」**：模型感知不到时长，何时开口是 semantic_vad 的活，死指令只制造矛盾。
- **新增 `wait_for_user` no-op 工具**（session.tools）：治结构性冲突——create_response:true
  强迫每次 VAD 断句必须说话 vs 提示词要求沉默。静音/噪音/思考声/半句话时模型调它，回合
  安静结束；relay 和 app 都不处理这个调用（app 未知事件走 default:break，最多闭麦约 1 秒，
  有 15s watchdog 兜底）。
- 补：语言钉死始终中文（夹英文单词不切换）、听不清只澄清不脑补、反重复句式。
- **同日用户拍板问题方向：问宏观不问细节**——为什么重要/背后逻辑/更大趋势/判断立场，
  明确禁止追问数字、时间地点、具体场景（第一版写的「往细处挖」被否）。测试锁了方向。
- 测试锁行为：realtime-route.test.js 断言分节标题在、wait_for_user 在工具表里、计时/冷场
  措辞不在。全量 795 用例绿，wrangler 已部署，线上 relay 路由 426 验证过。
- **待真机实测**：wait_for_user 会不会被过度调用（该提问时也装哑）——若是，收紧工具
  description 的触发条件；「安静 vs 健谈」的老矛盾以后用这个工具调，别再改语气措辞。

## 最近修复：采访者自顾自说个不停（2026-07-10）

生产 ledger 坐实（多段采访 audio_out = audio_in 的 3~10 倍）。三个叠加根因、三处修：

- **服务端 `agent/src/realtime.js`（jianshuo.dev repo，已部署）**：① session.update 加
  `max_output_tokens: 300`——semantic_vad 自动触发的回应从不走 app 的 response.create(120)，
  此前无任何长度上限；② 提示词删「他一说完你就要接住，不让对话冷场」（这是在命令模型填满
  每个沉默），加三条铁律：说完即停 / **绝不连续发言**（等讲者说出新内容才能再开口）/
  听到回声噪音保持沉默。有测试锁行为（realtime-route.test.js：上限有界 + 铁律措辞在、
  冷场措辞不在）。
- **iOS 半双工开麦前清残留**：闭麦经常把讲者的话截成半截留在 OpenAI 输入缓冲里，开麦后
  第一帧新音频会把这半截「封口」→ semantic_vad 判定「说完了」→ 又自动回一条 → 连环。
  现在 `RealtimeInterviewer.openMic()`（resume 与 15s watchdog 两条路都走它）先发
  `input_audio_buffer.clear` 再放开上行（`RealtimeSession.clearInputBuffer()`）。
- **验证**：agent 全量 73 文件 687 用例绿；iOS xcodebuild BUILD SUCCEEDED；行为效果待
  真机采访实测——如果还犯，下一个观察点是 400ms 回声尾巴是否够长（EngineRecorder
  `.dataPlayedBack` → +400ms 开麦）以及 eagerness:"medium" 是否退回 "low"。

## 上一个大改：邀请奖励（referral，2026-07-09 上线）

带来新装的作者和新用户双边得算力。spec = `docs/superpowers/specs/2026-07-09-referral-rewards-design.md`，
plan = `docs/superpowers/plans/2026-07-09-referral-rewards.md`。**已部署 + 生产冒烟**（link 层与
IP 层端到端验证过；剪贴板层待 TestFlight 真机）。

- **归因三层**（新账号 24h 内 first-touch 一次，终身封笔）：① universal link 分享链接拉起 →
  `AppRouter` 里 `ReferralManager.shared.noteShareToken(id)`；② App 首启 hello → worker 用
  `CF-Connecting-IP` 反查 R2 `refhits/<ipHash>/<ts>`（落地页每次访问由 Pages 写入，HMAC 不存明文
  IP，lifecycle 2 天）——**24h 窗口内唯一 owner 才算**（CGNAT 多 owner 放弃，宁漏不错）；
  ③ 剪贴板兜底：落地页下载按钮点击写入本页 URL，App 端 `detectedPatterns` 先无感探测、疑似有
  URL 才真读（此时才弹系统粘贴条）。iOS 全在 `ReferralManager.swift`（RootView.task 触发）。
- **奖励 = 币记价、入账时刻实时汇率**：作者 12 币 / 新人 6 币（R2 `config/referral.json`
  `{enabled,authorCoins,newUserCoins,dailyCapPerOwner:30,requireDeviceCheck}` 零部署可调），
  入账走 mint 表 `kind='referral'`（subject_key=新账号 sub；唯一索引=每账号一生一次），
  **与投币同池同分母同保险丝**（sumCoins7d 无 kind 过滤），钱走 grantBucket
  `referral_author`/`referral_new`（账单显示「邀请奖励/受邀赠送」），90 天过期。
  owner 日封顶 30 装/天，超出只发新人侧。核心 = `agent/src/referral.js`
  （`POST /agent/referral/claim {source,token?,deviceCheckToken?}`）。
- **判新防刷**：`account.created_at` < 24h（服务端时间）+ DeviceCheck 两 bit
  （`agent/src/devicecheck.js`，复用 APNS .p8 的 ES256 JWT；**线上 requireDeviceCheck 暂 false**——
  等真机验证 APNs key 是否开了 DeviceCheck 服务，没开就建新 key 加 secrets `DC_KEY_P8`/`DC_KEY_ID`
  再改 true）+ owner==self 拒绝。
- **落地页 CTA**（`functions/voicedrop/[token].js` `ctaHtml`）：「你约得 X 算力，作者约得 Y」按
  访问时刻现价现算——现价 = R2 `config/mint-rate.json`（worker 每次投币/邀请铸币后 +6h cron 刷新，
  `publishMintRate`），读不到显示无数字通用文案。voicedrop.cn 反代自动带上（同一 Function）。
- 测试：`agent/test/referral.test.js`（21）+ `refhits.test.js`（6）+ `devicecheck.test.js`（9）+
  `referral-landing.test.js`（4）+ mint-rate 用例；全量 73 文件 685 用例绿。
- **已知遗留**：① requireDeviceCheck=false 期间重装刷币敞口（防线剩「每账号一次+判新」；验 key 后开回）；
  ② 剪贴板层真机未验；③ iOS 端归因成功 alert 文案朴素（RootView）；④ 主动「邀请好友」入口/作者
  主页 `/voicedrop/u/<token>` 二期。

## 上一个大改：Universal Links——voicedrop.cn 链接直接拉起 App（2026-07-09）

- **服务端（jianshuo.dev repo，已部署）**：AASA 文件两份——`voicedrop/.well-known/apple-app-site-association`（voicedrop.cn 经腾讯云 Caddy「补前缀」映射取到）+ 根 `.well-known/…`（jianshuo.dev 老分享链接，components 只声明 `/voicedrop/*`）；`_headers` 强制 `application/json`（Pages 对无扩展名文件默认 octet-stream）。策略 = voicedrop.cn 整站进 App，仅排除 `/files/*` 与 `/privacy/*`。已实测 voicedrop.cn / www / jianshuo.dev 三处 200 无跳转 + Apple CDN（`app-site-association.cdn-apple.com/a/v1/voicedrop.cn`）200。
- **新公开 API `GET /files/api/link/<id>`** → `{type:"article"|"community",owner,stem,title,articles:[{title,body}],photos?}`——解析 + **直接带正文**（只读阅读页就地渲染，免二次请求；暴露面与公开 HTML 页等同）；shares/ 未命中回落 community/ 指针；被举报帖 404（对齐公开页）。分享指向非 articles 键 / 文章已删一律 404。测试 `agent/test/link-resolve.test.js`。
- **分享页 Smart App Banner**（`functions/voicedrop/[token].js` metaTags）：`apple-itunes-app` app-id=6781565141、app-argument=分享 url。微信内点链接**不会**拉起 App（微信限制）；「在 Safari 中打开」后靠这条横幅一键进 App——同域页内点击不触发 universal link，横幅是唯一可靠的 web→app 跳板。
- **iOS**：⚠️ **entitlements 真源在 `project.yml` 的 `entitlements.properties`——`xcodegen generate` 每次整个重写 `.entitlements` 文件，直接改文件会被无声冲掉**（本次实施时踩到）。已加 `applinks:voicedrop.cn/www.voicedrop.cn/jianshuo.dev`。`AppRouter` 认 https URL（`universalLink(_:)` 静态解析，DeepLink 新 case `shareLink(id:fallback:)`/`web(URL)`）；`LibraryView.openShareLink` 调 link API——**全原生分流**：自己的文章开 `RecordingDetailView`；社区帖开 `CommunityPostView`（构造轻量 `CommunityPost(shareId:)`，视图自己经 community/get 拉全文/回复/投币态，投喂/喜欢/回应全可用）；别人的普通分享开新的只读阅读页 **`SharedArticleView`**（Community.swift 尾部，与帖子页同套排版：标题/章节 chips/正文段落/CommunityPhotoTile 内嵌图，`?s=<i>` 决定初始篇；无任何社区动作——非社区分享服务端没有投喂/喜欢的挂点）；解析失败/help 等才落 `SafariView` 兜底，绝不死链；「录音进行中丢弃深链」守卫天然覆盖新 case。`VoiceDropApp` 补 `.onContinueUserActivity(NSUserActivityTypeBrowsingWeb)`（部分 iOS 只走 activity 不走 onOpenURL）。
- **签名**：App ID 已开 Associated Domains capability（`fastlane produce enable_services --associated-domains`，本地 ASC env 直接可用）；`fastlane refresh_profiles` 已重发 profile 到 certs repo（beta lane 的 `readonly:false` 仍留着，CI 下次构建自取）。
- **已知遗留**：① `~/code/jianshuo.dev/infra/voicedrop-cn/Caddyfile` 在 repo 里是 **0 字节空文件**（README 的「10 分钟重建」不成立）——线上真配置在 `/etc/caddy/Caddyfile`，需要 ssh `ubuntu@49.235.147.96` 的人回填（本次会话权限拦了远程读取）；② 微信内直接拉起 App 未做（需微信开放平台 `wx-open-launch-app` 开放标签 + 服务号 JS 签名，另立项）；③ `?s=<index>` 段选择：别人分享的只读阅读页已按它选初始篇；**自己文章**的原生详情页仍打开整组未跳篇。
- 计划全文：`docs/superpowers/plans/2026-07-09-universal-links.md`。

## 上一个大改：录音后端统一 AVAudioEngine + AI 采访变录音内开关（2026-07-08）

录音与 AI 采访解耦：**所有录音默认走 `EngineRecorder`（AVAudioEngine）**，AI 采访员是录音过程中随时可开关的旁路——录音界面停止键左侧新增「采访」键（与右侧拍照对称），点一下连 relay、再点结束，每段独立计费（worker 在 WS close 结算）。列表里原来的隐藏采访入口已删除。

- **神圣不变量**：tap 里永远先写 m4a 再 tee PCM；采访/半双工/AI 播放只碰 tee 支流，动不到文件。
- **文件格式整段定格**（2026-07-08 评审修复）：`Sink` 在 start() 就按 `pref.highQuality`（标准 16kHz/32kbps · 高 24kHz/64kbps，同 `Prefs.recorderSettings` 契约）建 AAC 文件，**每个 tap buffer 经持久 `AVAudioConverter` 转进固定格式**——中途换路由（AirPods/蓝牙、采样率变化）只换 converter 输入侧，文件不断不裂。AI tee 也走持久 converter（相位跨 buffer 连续）。
- **路由切换恢复**：`AVAudioEngineConfigurationChange` → 拆 tap → 停引擎 → 按新原生格式重装 tap → 重启（老代码带旧格式 tap 重启会 NSException 崩溃）；播放引擎同时 tearDown，下一段 AI 音频懒重启。
- **半双工排水计数带 generation token**：`player.stop()` 会异步触发所有排队 buffer 的完成回调，旧 generation 的递减一律丢弃，防止快速关/开采访时新段计数被污染 → 提前开麦自听循环。
- **错误可见 + 不 promote 幽灵**：`engineError` 在普通录音界面也显示（不再只在采访 overlay）；stop() 校验文件存在，不存在返回 nil → UI 显示「录音失败」，绝不无声吞录音。
- **RealtimeSession 每段 generation + 计数复位**：采访反复开关时旧 WS 回调不再把新会话标 degraded，debugLine 只反映当前段。
- **中断（来电）先关 relay 再交 take**（onInterrupted 包装），计费不悬空。
- **深链不打断录音**：录音进行中收到 voicedrop:// 深链直接丢弃（以前会 dismiss cover 丢整段录音）。
- **tee 门控**：`teeEnabled` 关闭时 Sink 不做重采样/不 hop 主线程——普通录音零采访开销；level/tapBuffers 走 100ms tick 读原子快照，不再每 buffer 两次主线程 Task。
- **逃生门**：设置 → 数据与备份 → 「经典录音引擎」（`Prefs.classicRecorder`）切回 AVAudioRecorder（无采访键）。**新引擎稳定一两个版本后删掉此开关和分支。** `classic` 在 RecordSession 里用 @State 定格整段会话。
- **半双工背景**：设备上 VPIO/AEC 不可用（tap 0 buffers，已穷尽排查），AI 说话时静音上行、response.done+播放排空+400ms 尾巴后恢复。AI 声音会进录音（用户已接受）。
- **已知遗留**：RecordSession 里 classic/engine 仍是 if/else 分支（RecordingBackend 协议未完全启用——刻意不在稳定期重构）；真机需验证：录音中插拔 AirPods 前后段都在、采访中拔耳机不崩、AI 说话中关/开采访无卡麦。
- **服务端**：relay 在 voicedrop-agent worker `/agent/realtime/relay`（WS 中转 OpenAI gpt-realtime-2.1，key 不落设备，`response.done.usage` 计费）；采访员提示词在 `agent/src/realtime.js`（名字叫 VoiceDrop，默认沉默、卡住才插话）。

## 更早的大改：追问（follow-up questions，2026-07-07 上线）

成文后 AI 按篇追问 1–3 个「只有作者知道」的细节，作者按住说话回答，回答被织进正文。

- **数据形态**：问题是 `articles/<stem>.json` **doc 顶层 sidecar** `questions:[{id,articleIndex,text,status,createdAt}]`——不进 body、不进 versions，发公众号/分享页/社区/小红书全出口天然不带（曾经的「正文尾——追问——节」方案已废弃，那会全渠道泄漏）。
- **服务端**（jianshuo.dev repo）：MINE_SYSTEM 让模型在 JSON 里按篇给 `questions` 数组；`miner.js extractFollowups` 收进 doc 顶层（`parseArticles` 还会剥掉误写进正文的尾节兜底）；`PATCH /files/api/articles/<stem>/question` 改状态（元数据写，不铸版本，`article-store.setQuestionStatus`）；CONFIG.json `noFollowups:true` 关掉；重挖整组换新。**坑：Anthropic output_config schema 不支持数组 `maxItems`（线上 400）——上限只能靠 prompt+parse 截断。**
- **iOS**：`FollowupQuestions.swift`（FollowupState 状态机 + FollowupWrap 包裹卡 + 星标）。**交互（2026-07-07 按用户口述修正）**：缺省收起——只在原「按住 说话 修改」条右侧亮 52×52 星标（角标=未答数）；点星标 → 追问信息（题号/跳过/问题/进度条）**把原 push-to-talk 包起来**（`PushToTalkBar.wrapPill` 插槽），按住的还是原来那个条（文案换「按住 说话 回答」）；**松手立刻按普通指令入队**（`mapInstruction` 包成【回答追问】前缀，agent SYSTEM 认它做定点织入），当场标 answered+翻题，之后就是普通发信息 UI（队列气泡），没有专门等待态；织入落地后 diff 新旧正文对被补段落做几秒荧光高亮（锦上添花，不阻塞）。7 天未答客户端过滤；设置 →「成文后追问」开关。设计稿 `design_handoff_follow_up_questions/` 里 3a 的独立回答按钮和 3c 确认行已被这版交互取代。
- **续问（2026-07-07）**：对语音 agent 说「再追问我几个」→ `add_followups` 工具（agent/src/tools.js）在本回合上下文里自己出 1–3 题，`article-store.appendQuestions` 追加落库（去重、不铸版本）；App 在 onUpdate 里 `followup.merge(newDoc)` 接上新题重新亮星标（本地已推进的 answered/skipped 状态不被服务端回读回退）。注意：追问展开态下按住说话一律当回答（包【回答追问】前缀），想续问先收起卡片再说。
- **编辑落地高亮（2026-07-07）**：所有语音修改落地后 `BodyDiff.changedRows` 按内容 diff 新旧正文，变动行黄底 3.5s 淡出（`highlightLines`，按篇存）；追问织入共用此路。

## What it is

VoiceDrop: open-mic-and-record iOS app. You tap record → speak → it uploads the
audio to your own cloud space → a server miner transcribes it and writes one or
more 公众号-style articles in your voice → you read/share them in the app. Plus a
public web preview of any article.

## Repos & deploy

| Repo | Path | What | Deploy |
|---|---|---|---|
| voicedrop | `~/code/voicedrop` | iOS app (SwiftUI) + WeChat publish relay (`mining/relay_server.py`) + CI | push `main` → GitHub Actions `Build & Deploy` → **TestFlight** (fastlane). App Store submit = manual `appstore` workflow_dispatch → `fastlane release skip_build:true`. |
| jianshuo.dev | `~/code/jianshuo.dev` | Cloudflare **Pages** project `jianshuo-dev`: files API + public article page, backed by R2 bucket `jianshuo-dev-files` (binding `FILES`) | **manual** `npx wrangler pages deploy . --project-name jianshuo-dev --branch main` (not git-triggered; **must pass `--branch main`** or a detached-HEAD deploy silently lands in a Preview, not production — see 部署坑 2) |
| voicedrop-agent | `~/code/jianshuo.dev/agent` | Cloudflare **Worker** (Durable Objects; Pages can't host them) on route `jianshuo.dev/agent/*`: live article editing + real-time status. Same R2 `FILES` + `SESSION_SECRET` as Pages. | **manual** `cd ~/code/jianshuo.dev/agent && npx wrangler deploy` |
| claude-skills | `~/code/claude-skills/wjs-mining-voicedrop` | the Mac-side mining skill (WeChat drafts) | commit on `main`; publish hook syncs `wjs-*` to public repo |

App project is generated by **xcodegen** from `project.yml` (no checked-in
`.xcodeproj`; new `VoiceDropApp/*.swift` files are auto-included). Bundle id
`com.wangjianshuo.VoiceDrop`. Version **1.0**.

## Architecture & data flow

```
iOS app ──record──> users/<sub>/VoiceDrop-<ts>...m4a  (R2, per-user)
                          │
  Pages Function upload handler → dispatchMine → Miner DO (Worker)
   └ (also: cron every 6h; also: manual curl to /agent/mine/trigger)
   Miner DO: for each unprocessed m4a → Volcano ASR → Claude API → write
       users/<sub>/articles/<stem>.json  (+ .srt)   ← "已成文"
       or users/<sub>/articles/<stem>.empty         ← "无语音"
       mine run log → minelogs/<date>/<ts>-<stem>.json
                          │
iOS app `文章` tab ──list+download──> renders articles, share, delete
public web  jianshuo.dev/voicedrop/<token> ──> renders one article set (light theme)
```

**Upload resilience (`Uploader.swift`, 2026-06-28):** the Documents dir IS the pending queue — a `VoiceDrop-*.m4a` still on disk = not yet uploaded (shows 正在上传). A PUT now (1) holds a `UIApplication` background-task assertion so an upload kicked off in the foreground finishes even if the user locks/switches right after recording (the old foreground-only `URLSession.shared` task was cancelled on suspend → takes stuck on 正在上传 forever); (2) retries transient failures (5xx / network / timeout) with 1.5s→3s backoff, 4xx/auth stop immediately, a still-failing take stays on disk for the next drain (never lost); (3) `drainPending` no longer `break`s on the first failure — it skips the stuck take so one bad file can't wedge the queue; (4) drains are serialised (`isDraining`/`drainAgain`) to kill the foreground-refresh / post-record / scene-change race; (5) an `NWPathMonitor` re-drains when connectivity returns.

⚠️ **CF same-zone fetch gotcha (2026-06-25):** Pages Functions cannot `fetch('https://jianshuo.dev/agent/...')` to call the Worker zone route — CF routes same-zone internal fetches through Pages routing first, which returns 405 for POST on static paths (Worker never sees the request). **Fix**: `dispatchMine` uses `https://voicedrop-agent.jianshuo.workers.dev/agent/mine/trigger` (the Worker's `workers_dev` subdomain), bypassing Pages routing entirely. `wrangler.jsonc` must have `"workers_dev": true`.

Auth: per-user. App holds an anonymous capability token (`anon_…`, iCloud
Keychain) OR a Sign-in-with-Apple session JWT. **The app sends the anon token by
default for ALL calls (`AuthStore.bearer = anonToken`, 2026-06-27); the session JWT is
sent ONLY for the two server-gated community WRITES — share / unshare — which 403 a
non-Apple token. Apple sign-in just BINDS the Apple ID to the existing anon box, so the
session's scope is itself `users/anon-<hash>/` — anon and session resolve to the SAME
scope/user_sub.** Server admin token = `FILES_TOKEN` (sees all `users/*`). Files API
scopes every request to `users/<sub>/`.

## R2 layout & marker conventions (the contract everyone shares)

- `users/<sub>/VoiceDrop-<ts>-<dur>-<weekday>-<period>[-<city>-<district>].m4a` — audio (ASCII names).
- `users/<sub>/articles/<stem>.json` — mined article(s), v2 schema `{schema,id,sourceAudio,createdAt,transcript,srt,articles:[{title,body,style?,wechatMediaId?}],status,model}` (`style` = 文风版本 per-article 字段，见「文风版本 = per-article 字段」节). **Presence = 已成文.** (Photo references live in the body as `[[photo:<key>]]` markers — see below. **`photos` is no longer written** as of 2026-06-26; old articles may still carry a legacy `photos` array, read only to resolve their `[[photo:N]]` indices.)
- `users/<sub>/articles/<stem>.empty` — `{status:"empty",reason:"corrupt|silent|no-speech|too-short|no-article|asr-error:<code>"}`. **Presence = 无语音.** (`asr-error:<code>` = Volcano returned a deterministic business error in the query phase, e.g. `asr-error:45000151` — re-running gets the same code, so the recording is marked processed instead of retried forever. The app ignores `reason` and just shows 无语音.)
- `users/<sub>/articles/<stem>.srt` — subtitle sidecar.
- `users/<sub>/photos/<sessionTs>/<offset>-<rand>.jpg` — **场景照片**（录音时一边说一边拍，隐藏功能）. `sessionTs` = the recording's `yyyy-MM-dd-HHmmss` (correlates photo↔recording). **`<offset>` = 整数秒, the photo's offset from the recording start** — this IS "第几秒加进来"; absolute capture time is recoverable as `sessionTs + offset`, so the old absolute capture stamp was redundant. `<rand>` = a 3-char base36 tail. **Why offset+rand, not a capture timestamp (changed 2026-06-26):** the prior `<captureTs>` (`yyyy-MM-dd-HHmmss`) had **two bugs** — (1) seconds-only resolution **collided** when several photos landed in the same second (a 9-photo album import fires its `loadObject` callbacks near-simultaneously → same key → silent overwrite, lost photos); (2) it was 17 chars when 2–4 would do. The `<rand>` tail makes the key unique even within one offset-second (3 base36 = 46,656 combos → ~0.08% collision for 9 same-second photos). Helper is the single source of truth: `RecordingName.photoKey(sessionTs:offset:)` (iOS); both upload paths use it — editor insert (`RecordingDetailView.insertPhotos`, offset via `RecordingName.date(fromTimestamp:)`) and during-recording capture (`RecordSession.uploadPhoto`, offset = `date − sessionStart`). **Note** offset is only真·"录音内第几秒" for the during-recording path; for editor-inserted / album-imported photos it's "how long after recording it was added" (large but unique & harmless). **iOS-only change** — worker/web treat the marker token as an opaque key, so the renamed `<offset>-<rand>` segment is transparent to them. Square ≤1200px JPEG. Uploaded by the app via the normal `PUT upload/<key>` (lands in user scope). **Inline display:** the miner (`miner.js`) and the voice-edit agent (`index.js`) feed photos to Claude as vision input and insert **`[[photo:<relkey>]]`** markers — **the token IS the photo's relative R2 key** (e.g. `[[photo:photos/<sessionTs>/<offset>-<rand>.jpg]]`) — into the body at the spot the scene is described; the app/web resolve each marker's key directly and render the photo inline. **Why keys, not indices (changed 2026-06-26):** the old `[[photo:N]]` used a 1-based index into the `photos` array, which coupled every marker to that array's order — inserting/reordering a photo during voice-edit misnumbered the rest and showed "different marker, same image". A self-contained key has zero coupling: insert/delete a marker without touching any other. **The `photos` array is no longer written (2026-06-26):** the miner (`miner.js`) and the voice-edit agent (`index.js`) stopped writing it — consumers extract referenced keys straight from the body instead (web via `photoRefsInBodies`→`buildPhotoURLs`; iOS export via `ArticleBody.segments`; iOS detail view's `PhotoTile` already downloaded by marker key). **Legacy `[[photo:N]]` is still parsed for old articles** — resolver is `ArticleBody.resolvePhotoKey` (iOS, numeric→`photos[N-1]` else token-is-key) and `photoRefsInBodies`'s `/^\d+$/` branch, both mapping the index through the old article's surviving `photos` array. New writes from all paths use keys only; an old article's `photos` array is read-only legacy. Markers are **stripped** wherever photos can't be shown — WeChat HTML (`md_to_wechat_html`), exports, and share excerpts (all marker regexes widened to `[[photo:[^\]]+]]`). **Photos now load from ONE universal endpoint** (changed 2026-06-26): `GET /files/api/photo/<full R2 key>` — public, no auth, no per-post gating, serves any `users/*/photos/*.(jpg|png)` straight from its original location. Used everywhere: the public `/voicedrop/<token>` page emits `<img src="/files/api/photo/…">` (`buildPhotoURLs`, no more base64), and the community (`CommunityPostView` renders `ArticleBody.segments` with inline `CommunityPhotoTile`s, no longer `stripMarkers`). The editing agent is told to preserve markers (and their keys) verbatim.
- `users/<sub>/CLAUDE.json` — the user's **写作文风 (style only)**, schema-3 **versioned** envelope identical to articles (`{schema:3,head,versions:[{v,savedAt,source,style}],createdAt,updatedAt}`). Single source of truth = `functions/lib/style-store.js` (mirror of `article-store.js`), imported by the Pages Function, the agent worker (`tools.js`) and the miner (`miner.js`). Read/written via the dedicated **`/files/api/style`** route (GET read · PUT versioned write `{style[,source]}` · GET `style/history` · PATCH `style/head`). The 文风 is appended to the mining prompt. **The name is NOT here** — it stays in the legacy `CLAUDE.md` for now (見下), to be relocated later. **Backward compat (2026-06-29):** writers only ever write `CLAUDE.json`; every reader (`readStyleText`/`/style` GET) prefers `CLAUDE.json` and **falls back to parsing the old `CLAUDE.md`'s「# 我的文风」section** when no `CLAUDE.json` exists yet — so an old `CLAUDE.md` is retired the first time the user saves. iOS `SettingsView.swift` reads `GET /style` + saves `PUT /style` (empty style is skipped, since the route rejects blank writes). `read_style`/`write_style` agent tools speak the 文风 text and route writes through `/style`.
- `users/<sub>/CLAUDE.md` — **legacy; now holds the NAME only** (`# 我的名字\n<name>`). iOS still reads/writes it for the name; the author-extraction paths (community share endpoint + miner `community/<id>.json`) still pull the author from its `# 我的名字` regex — **unchanged**. Its「# 我的文风」section is read only as a fallback for users not yet migrated to `CLAUDE.json`. The name's permanent home is TBD.
- `users/<sub>/WECHAT.json` — `{appid, secret, enabled, thumb_media_id?, coverMediaIds:{<coverName>:<wechatMediaId>}}` (Settings tab). Drives WeChat draft publishing; `coverMediaIds` caches the per-cover WeChat material ids.
- `assets/wechat-covers/<style>.png` — **shared** cover image set (10: `style01`–`style10`), global (not per-user). One is picked per article by hash. Public via `/files/api/asset/wechat-covers`.
- `shares/<id>` — value is a full article key; backs the short public share link. `id = HMAC(key)[:10]`.
- `community/<shareId>.json` — a public **schema-2 live pointer** to a shared article: `{schema:2,shareId,owner,articleKey,author,firstSharedAt,replyTo?}` (no content copy — title/body read live from `articleKey`). `shareId = HMAC('community:'+articleKey)[:12]`. Global (cross-user). Editing the source article IS reflected immediately; deleting the source recording **reaps** this pointer (see Community self-heal below). Legacy schema-1 posts with inline `{title,articles}` may still exist and are read as-is.
- **"processed" = `.json` OR `.empty` exists.** Audio is NEVER auto-deleted; only the user deletes it in-app.
- `llmlogs/<YYYY-MM-DD>/<epochms>-<rand6>.json` — **every** Anthropic call (Worker miner + agent worker) recorded raw `{id,ts,source:mine|agent,user_scope,model,latency_ms,http_status,ok,turn_id,step,request,response|error,meta}`. Admin-only (outside `users/`). 30-day R2 lifecycle (`llmlogs-30d`). Viewer: `voicedrop/admin/llm.html` (reads via admin `GET /files/api/llmlog/{dates,list?date=}` + `download/<key>`). Best-effort write — never blocks mining/editing.
- `minelogs/<YYYY-MM-DD>/<epochms>-<stem>.json` — **每次 Miner DO 处理**一条录音的事件日志 `{ts,stem,audioKey,result:"mined|empty|error",elapsed_ms,events:[{ts,msg,data}]}`. Admin-only. Viewer: `voicedrop/admin/mine.html`. Best-effort —`result:"skip"`（已处理跳过）时不写。


## 文风版本 = per-article 字段（2026-07-03，迁移已完成）

- **`articles[i].style = N`（整数）= 这篇文章的文风版本**，per-article、随版本走（undo/redo 后
  chip 正确）。写入方：miner 正常挖矿 + restyle（`agent/src/miner.js` 两处 `{...a, style: v}`）。
  风格介绍文（style-intro）无 style 字段（历来如此）。
- **正文里不再有 `<!-- style: 风格 vN -->` 注释。** 隐形注释行曾让 iOS（渲染/编号前
  `stripOriginComment` 剥注释）与 agent `linenum.js`（不剥）的 第N行 错位 +1 → 语音编辑
  「改第3行」改错行。存量已由 `agent/scripts/migrate-style-field`（经 `wrangler dev --remote`
  直连生产 R2，走 wrangler OAuth，无需 FILES_TOKEN；游标分页防 504）一次性迁移：382 docs
  扫描、50 迁移（注释→字段、body 去注释、含全部 versions/history）、二次 dry-run 0、线上
  `<!--` 残留 0。迁移前全量备份 `~/Downloads/voicedrop-articles-backup-2026-07-03.ndjson`
  （另有每晚 R2 自动备份兜底）。
- ⚠️ **per-article 可扩展契约（以后加字段必读）**：tools.js 所有重建 `doc.articles` 的写路径
  一律「继承+覆盖」`{...a, title, body}` —— 未知字段（style / wechatMediaId / 未来任何字段）
  自动存活；**绝不要回退成 `{title, body}` 白名单重建**（会在每次编辑时静默丢字段，
  wechatMediaId 曾靠每处手搬才活着）。doc 顶层字段由 `writeArticleDoc` 的 `...rest` 保留；
  version 条目层固定 `{v,savedAt,source,articles}`（要加得改 article-store.js）。整篇重写
  （write_article）按 index 从旧文章继承，拆/并文章时字段可能错位（既有语义，chip 显错无害）。
  模型进不来未知字段（工具 input_schema 均 `additionalProperties:false`）。
- **linenum.js 防御性剥注释**：编号前剥一切 `<!--…-->`（镜像 iOS），残留注释在编辑回写时
  自动消失（自清洁）。测试：`agent/test/style-field.test.js`（编号 / 字段存活 / 迁移 transform）。
- **iOS**：`MinedArticle.style: Int?`；chip 与 `existingVersion(forStyle:)`（换风格「复用已有
  版本」匹配）先读字段、回退读 body 注释；`stripOriginComment` 保留当保险。老 build 读不到
  注释 → chip 显「选风格」，装新 build 恢复。
- 已知遗留：① 3 个 doc 曾带更老格式 `<!--风格vN-->`（无 `style:` 键），解析器历来读不出，
  迁移只剥注释未提字段——显示零回归；② legacy 数字图片标记（`[[photo:N]]`）越界时 iOS 跳行
  不计数而 linenum.js 计数——罕见旧数据的编号分歧，未修。
- Spec：`docs/superpowers/specs/2026-07-03-style-field-schema-design.md`。
- **无转写文章可重写（2026-07-03）**：合并（`merge_articles`→`writeStandaloneArticle`）、图片分享
  （看图挖矿）、style-intro 等文章 `transcript:""`，重写/换风格曾在 `restyleArticle`
  （`agent/src/miner.js`）开头 `no-transcript` 硬失败（422）。现在 transcript 为空时回退用
  **head 文章正文**当挖矿来源（正文即事实来源；新 doc 的 `transcript` 保持 ""，不伪造）；
  正文也空才仍报 no-transcript。同时**看图挖矿分支落盘打 `articles[i].style` = 文风 head 版本号**
  （此前文风文本进了 prompt 但没打字段 → iOS chip 显「选风格」）。测试
  `agent/test/restyle-body-fallback.test.js` + `mine-image.test.js` 的 style 标记用例。

## Files API (`jianshuo.dev/files/api/<path>`, Cloudflare Pages Function)

`functions/files/api/[[path]].js` — routes (all but `auth/apple` require a token):
- `POST auth/apple` — exchange Apple identity token → session JWT.
- `GET  list` / `GET download/<key>` / `PUT upload/<key>` / `DELETE file/<key>`.
- **`POST account/delete`** — **账号删除（Apple 5.1.1(v)，2026-07-06）**：永久删除调用者的一切——`users/<sub>/` 全部对象、本人社区帖（owner==scope）+ 其举报标记、指向本人 scope 的 `shares/<id>` 短链、`links/apple-<sub>.json` Apple 绑定。admin/只读 token 400/403；匿名与 Apple 登录用户皆可。iOS 入口：设置→账户→账户管理→删除账户（确认弹窗→调接口→清本机 Documents+UserDefaults→`signOut`+`resetAnonymous` 全新空身份）。算力 D1 账本（agent worker）不动——计费流水保留，user_sub 成孤儿无害。测试 `agent/test/account-delete.test.js`。
- `GET  whoami` — returns the caller's resolved data scope `{scope:"users/<sub>/"}`. The app caches it (`LibraryStore.ownerScope()`) and joins `scope + relKey` to load its OWN photos from the public `photo/<key>` endpoint — so even the owner's detail view uses the one photo URL, not the scoped download.
- `GET  share/<articleKey>` → `{url:"https://jianshuo.dev/voicedrop/<id>"}` (signs + stores `shares/<id>`).
- `POST mine` → dispatches `mine.yml` (token = `GH_DISPATCH_TOKEN` Pages secret). Dormant — the app's 加急处理 button was removed; kept for manual/debug use.
- **`POST style/collect`** `{type,title,text,source}` → writes a 风格数据集 corpus sample `users/<sub>/style/<id>.json`; blank text → 400. **`GET style/dataset`** → `{items:[{id,type,title,chars,source,collectedAt}],count,totalChars}` (newest-first, no `text`; tolerates legacy miner `collectStyle` samples). **`DELETE style/dataset`** → clears all `style/*.json`. Backs the Share Extension「风格数据集」sheet (接受分享, see below). `title`/`type` are string-guarded.
- `POST wechat/<articleKey>` → publish/update a WeChat draft **synchronously** via the VPS relay (see next section). 409 = not configured; 502 relays the real WeChat `{errcode,errmsg}`.
- `GET asset/wechat-covers` (list) / `GET asset/wechat-covers/<name>` (image bytes) — **public, no auth**; the cover set in the FILES bucket, read by the relay + miner to pick a per-article cover.
- `GET photo/<full R2 key>` — **public, no auth (2026-06-26).** The ONE photo endpoint used by every display surface (community, public share page, exported HTML). Serves any `users/*/photos/*.(jpg|jpeg|png)` straight from its original R2 location as a plain `<img src>` (CORS `*`, public cache). File-type allowlist + `..` block are the only guard — it can never serve articles/credentials. Full keys are unguessable (hashed sub + ts + rand). Replaced the short-lived gated `community/photo/<shareId>/<token>` design. Even the owner's own detail view (`PhotoTile`) loads through this (full key = `whoami` scope + relKey), so ALL photo display goes through this single endpoint.

`functions/voicedrop/[token].js` — public, unauth. Resolves `shares/<id>` → renders
that one article as a light-theme HTML page. **It ALSO resolves a VD社区 `shareId`
(2026-06-28):** if `shares/<id>` misses, it falls back to `community/<id>.json` (schema-2
live pointer) → renders THAT post's `articleKey` through the SAME downstream + og tags, so a
社区 post shares to WeChat exactly like an article (first photo + description) — **no separate
page** (公用，不造轮子). A reported post (`community/reports/<id>.json` present) returns 404
「已不可用」(Apple 1.2). Pinned by `og-tags.test.js`. **`?s=<index>`** (optional) renders/previews
only that one section of a multi-section doc — the app appends it (`shareURL(_:section:)`
from `articleIndex`) so a shared link reflects the section the user had selected; absent or
out-of-range falls back to the full set (old links unchanged). Non-token segment (e.g. `privacy`) →
`context.next()` (static `/voicedrop/` landing + `/voicedrop/privacy/` untouched).
Article pages emit **share-card meta tags** for X / WeChat (`metaTags()` in `[token].js`,
unit-pinned by `agent/test/og-tags.test.js`) — **all section-aware** (driven by `?s=<i>`):
- `og:title` **and `<title>`** = the SELECTED section's title (so s=1/s=2 cards show that
  section's title, not section 0's).
- `og:description` **and `<meta name="description">`** = a plain-text excerpt of THAT
  section's body (markers stripped). **WeChat's link-card crawler reads `<meta name=description>`,
  NOT `og:description`** — that's why both are emitted.
- `og:image` (+ `twitter:image` + `<link rel=image_src>`, card upgraded to
  `summary_large_image`) = **that section's OWN first `[[photo:…]]`** as an ABSOLUTE URL
  (`https://jianshuo.dev/files/api/photo/<full key>`, the public no-auth photo endpoint).
  **Each article carries its own image — no recycled static banner** (the old `/voicedrop/og.png`
  banner was dropped: one image on every share read as spam). A photo-less section emits **no
  `og:image`** and stays a clean text card (`twitter:card=summary`).

Pages secrets: `FILES_TOKEN`, `SESSION_SECRET`, `GH_DISPATCH_TOKEN`, `WECHAT_RELAY_URL`, `WECHAT_RELAY_SECRET`.

## WeChat 公众号 publish — synchronous, via the Tokyo VPS relay

App ⋯ → **发布公众号草稿** publishes a mined article as a WeChat draft and waits for the
REAL result (`created`/`updated` or the actual `errcode`), not the old fire-and-forget.

Flow: app `POST /files/api/wechat/<articleKey>` → Function reads the article JSON +
`users/<sub>/WECHAT.json` creds → POSTs `{appid,secret,cover_media_ids,article}` to the relay
and **awaits** → writes the returned `wechatMediaId`(s) back to the article JSON and the cover
cache to `WECHAT.json` → returns `{ok,created,updated}` / 502 `{errcode,errmsg}` / 409 not configured.
Idempotent: an existing draft is updated in place (no dupe).

**Why a relay:** WeChat's API only works from the IP whitelisted on the 公众号 — the Tokyo VPS
`66.42.45.128` — and Cloudflare `fetch` can't route through a proxy. So a tiny always-on service
runs ON that VPS and calls `api.weixin.qq.com` directly.

- **Relay** = `wechat-relay` systemd unit on the VPS: `python3.12 /opt/wechat-relay/relay_server.py`
  bound to `127.0.0.1:8848`. **Self-contained, stdlib-only** — `relay_server.py` holds the entire
  WeChat + cover toolchain (`wechat_access_token` / `md_to_wechat_html` / the `assets/wechat-covers`
  picker / `create|update|sync_wechat_drafts`); no R2 / `FILES_TOKEN`, no ASR, no Claude. **Dumb**:
  gets appid/secret + article per request, returns results; the Function persists. Code =
  `mining/relay_server.py` (single file). Deploy = `mining/deploy_relay.sh`
  (`VPS_SSH=root@66.42.45.128 ./mining/deploy_relay.sh` → rsync + drop stale `mine.py` + daemon-reload +
  restart + health). First-time provision = `mining/vps/provision.sh` (+ `wechat-relay.service`, `README.md`).
- **Exposed via a Cloudflare Tunnel** (zero open inbound port): `cloudflared` systemd unit, tunnel
  `wechat-pub` → proxied CNAME `wechat-pub.jianshuo.dev` → `127.0.0.1:8848`. Inbound auth = header
  `X-Relay-Secret` (= Pages `WECHAT_RELAY_SECRET` = VPS `/opt/wechat-relay/relay.env`). WeChat egress
  still exits `66.42.45.128`, so the whitelist is unaffected. **No fallback** by design — failures surface.
- `mining/mine.py`, `mining/publish_wechat.py`, and `.github/workflows/publish-wechat.yml` were all
  **deleted (2026-06-26)**. `mine.py`'s mining half was long superseded by the Worker miner
  (`agent/src/miner.js`, "port of mine.py to JS"); its WeChat half was the relay's only live use, now
  inlined into `relay_server.py`. The publish-wechat workflow path was superseded by this synchronous
  relay. See `mining/REMOVED.md` for the tombstone + git-restore commands. **Nothing runs `python mine.py`
  anymore** — there is no `mine.yml`, and `POST /files/api/mine` dispatches the Worker DO, not a workflow.

**Per-article 题图 (cover) — article's OWN first photo (2026-06-28):** the WeChat draft cover now uses
**the article body's FIRST `[[photo:<relkey>]]`** as `thumb_media_id`, so a photo article shares with its
real picture, not a generic style cover. `make_cover_resolver(token, owner, doc_id, cfg)` (in
`relay_server.py`) → `cover_for(a, force=False)`: fetch that article's first photo from the public
`/files/api/photo/<owner+relkey>` endpoint, upload ONCE as a permanent image material
(`_upload_cover_material`, `material/add_material type=image` — usable as a thumb), cache the media_id in
`WECHAT.json.coverMediaIds` under key `photo:<fullkey>` (the Function persists it, so re-publishing reuses
it). **Fallback chain (cover is always something):** no body photo / legacy numeric `[[photo:N]]` / fetch
fails → the per-doc style cover `resolve_cover_thumb` (one of `assets/wechat-covers/style01–10.png` by
`hash(doc.id)`, cached per cover NAME in `coverMediaIds`) → gray placeholder if the cover set is empty.
A photo-cover failure is caught and degrades to the style cover — it never fails the publish. On a create
40007 (cover material wiped) the cover is re-uploaded `force=True` and the create retried once.
**Note:** each unique photo cover consumes one permanent image material (huge quota; cached so each photo
uploads once) — inline body photos still use `media/uploadimg` (no quota).

**摘要 (digest) — generated (2026-06-28):** `create/update_wechat_draft` now set the draft `digest` from
`_digest_from_body(body)` (strip `[[photo:…]]` markers + markdown image/link/inline marks, collapse
whitespace, cap ~110 chars + `…`), so the WeChat share card shows a real summary instead of WeChat's raw
first-54-chars fallback. Empty body → no `digest` field (WeChat's auto-grab, as before).

> Public **link card** (系统分享 a `/voicedrop/<token>` URL into WeChat chat) is a SEPARATE path —
> `functions/voicedrop/[token].js` `metaTags()` already emits `og:image` = the section's first photo
> (absolute URL) + `<meta name=description>` summary + `<link rel=image_src>` for old WeChat.
> **iOS share-payload fix (2026-06-28):** the page og tags only matter if the app hands WeChat a **URL**, not
> text. `RecordingDetailView.share()` used to share ONE combined string (`正文 + 链接`) → WeChat posted it as a
> **plain text message with NO card** (this was why "依然没有图/description"). Now the share goes through
> **`ArticleShareItem: UIActivityItemSource`** (in `RecordingDetailView.swift`): for WeChat
> (`com.tencent.xin.*`, 发送给朋友 + 朋友圈) it returns the **bare URL** so WeChat builds the rich card from the
> page og tags, and it also supplies **`LPLinkMetadata`** (article title + first photo) so the card shows a
> thumbnail without waiting on WeChat's crawl; for **X / 其它** it still returns the combined inline-URL text (X
> drops a separately-attached URL item). Requires a **new TestFlight build** to take effect. If a shared link
> STILL shows no image after a new build, it's WeChat's per-URL link-card **cache** — test with a fresh share.
> (relay + Pages already redeployed 2026-06-28.)

**Inline body photos in WeChat drafts (2026-06-26):** the body's `[[photo:<relkey>]]` markers used to be
**stripped** from WeChat drafts (the markers never carried the actual image). Now the relay embeds them:
the Function passes `owner` (= `users/<sub>/`) in the publish payload; `relay_server.py` `make_photo_resolver`
fetches each photo from the public `GET /files/api/photo/<owner+relkey>` endpoint (no auth) and uploads it
via WeChat `media/uploadimg` (content-image API — no material-quota cost), then `md_to_wechat_html` replaces
the marker line with a centered `<img>`. **A photo failure never breaks the publish** — that one marker is
stripped and publishing continues. Legacy numeric `[[photo:N]]` and mid-paragraph markers don't resolve and
are stripped (as before). Requires the relay + the Pages Function both deployed (done 2026-06-26).
  - **Uploaded-URL cache (disposable, NOT in the article JSON):** a global map `appid+fullkey → {url,ts}` in
    a local scratch file on the relay box (`/opt/wechat-relay/imgcache.json`, `WECHAT_IMG_CACHE`-overridable),
    so re-publishing / voice-editing doesn't re-upload every photo each time. Entries >30 days old are treated
    as misses and re-uploaded; each write prunes expired ones (never grows unbounded). Per-appid scoped (a URL
    is only reused for the same WeChat account). Only successful uploads are cached. Losing the file = a
    one-time re-upload. The relay stays "dumb" (no R2 / no article-JSON writes) — this is pure scratch.

Infra (tunnel + DNS + VPS service) recorded in the iCloud `IT基础设施-更改记录.html` (2026-06-23).

## Files API — mine/trigger

`POST /agent/mine/trigger` (Worker) — kick the Miner DO to process pending audio.
- Auth: **any valid user token** (`anon_*` or Apple session JWT) OR admin `FILES_TOKEN`. No admin-only restriction — triggering is harmless.
- Called automatically by the Pages Function upload handler via `dispatchMine` (uses `workers.dev` URL, see CF same-zone fetch gotcha above).
- Manual: `curl -X POST https://voicedrop-agent.jianshuo.workers.dev/agent/mine/trigger -H "Authorization: Bearer <any-valid-token>"` → `queued`.

## Live agent Worker — voice editing + status (`agent/`, `voicedrop-agent`)

A **separate Cloudflare Worker** (Pages can't host Durable Objects), route `jianshuo.dev/agent/*` →
same-origin `wss://jianshuo.dev/agent/...`. Binds the same R2 `FILES` + `SESSION_SECRET` (verifies the
app's existing tokens) + `CLAUDE_API_KEY`. Two Durable Objects (`agent/src/index.js`):

- **`ArticleEditor`** (`wss://…/agent/edit?stem=<stem>`) — live **voice editing** of an article. The
  app holds the mic (`AgentSession.swift` `ArticleAgentSession`) and speaks change requests; each is
  queued **client-side and sent strictly serially** — the next only after the prior `updated` returns,
  so every edit builds on the last *result*. The DO reads the article + the user's `CLAUDE.md`, calls
  Claude to rewrite, writes the new `articles/<stem>.json` back to R2, and pushes the updated doc; the
  detail view reloads it in place. Mic UI: the mic button itself becomes the animated "正在改" indicator
  and queued instructions stack above it (`RecordingDetailView.swift`).
- **`Miner`** (singleton DO `idFromName("miner")`) — serialised mine runs via `alarm()`. Triggered by `POST /agent/mine/trigger` (any valid token) or the 6-hour cron (`scheduled` handler). Lists all users' unprocessed audio, runs Volcano ASR + Claude mining, writes `articles/<stem>.json` or `.empty`, writes `minelogs/`. POSTs `POST /agent/notify` with `FILES_TOKEN` after each recording to update `StatusHub`. Source: `agent/src/miner.js`.
- **`StatusHub`** (`wss://…/agent/status`, one instance per user `status:<scope>`) — real-time mining
  status. The Worker miner (`miner.js`) POSTs `POST /agent/notify` (auth `FILES_TOKEN`) at each mining phase; the hub
  broadcasts `{type:"status_update",stem,status}` (status ∈ `asr|mining|ready|empty`, passed through
  verbatim — no whitelist) to that user's app sockets, so rows flip **待处理 → 听录音 → 挖文章 → 已成文**
  (or → 无语音) with no polling (`StatusSession.swift` `onPhase/onDone`, `LibraryStore.markPhase/markDone`).
  Phases map to badges in `MiningPhase` (`asr`=听录音, `mining`=挖文章).
- **`/agent/asr` — 语音编辑听写的火山流式 ASR 代理（2026-06-28，token 安全）.** 语音编辑听写从 Apple 本地
  `SFSpeechRecognizer` 改走火山引擎 bigmodel **流式** ASR（对齐「ASR 用火山」；zh-CN 更准）。**服务端 = 哑中继**
  `agent/src/asr-proxy.js`：`resolveScope(bearer)` 验 app token（401 拦）→ 注入 worker 已有的
  `VOLC_ASR_APPID`/`VOLC_ASR_ACCESS_TOKEN`、**剥掉客户端 `Authorization`**（不外泄）→ `fetch` 出站到
  **`https://openspeech.bytedance.com/api/v3/sauc/bigmodel`**（资源 `volc.bigasr.sauc.duration`，**流式**，区别于
  挖矿的文件 `volc.bigasr.auc`）→ 双向 pipe。**客户端持全部协议、服务端持密钥**——app 永不接触火山凭证。**iOS 端**
  `VoiceDropApp/VolcASRProtocol.swift`（火山二进制协议：gzip 分帧+序列号）+ `VoiceEdit.swift` 的 `SpeechDictation`
  （`AVAudioEngine` 取麦克风→重采样 mono 16k→WebSocket 流到 `/agent/asr` 带 `AuthStore.bearer`），`project.yml` 加
  `-lz` 链 zlib。⚠️ **两个坑（都已修）：(1) CF Workers 出站 WebSocket 必须 `https://` 不能 `wss://`（否则
  `Fetch API cannot load`→500）；(2) 代理不能直接 `target.send(event.data)`——CF 把二进制帧的 `event.data` 给成
  Blob，`send(Blob)` 会强转成字符串 `"[object Blob]"`（13 字节），两个方向的二进制全毁：音频以文字 "[object Blob]"
  到火山→火山不转写→「说话和没说一样」。修法：两 socket 设 `binaryType="arraybuffer"` + `toSendablePayload()`
  把 Blob 转回 ArrayBuffer，经保序 promise 链转发。纯服务端修复，iOS build 107 无需重打。** ⚠️ **冒烟测必须
  「发真实音频 + 解码回包断言转写文字」**——之前只发配置帧、把强转的 "[object Blob]" 误当 13 字节有效帧（假阳性），
  导致坑 (2) 两次上线都没真正工作过。**iOS 与 worker 必须一起上**（先部署 worker、后发 build）。
  canonical spec：`docs/superpowers/specs/2026-06-28-voice-edit-volc-asr-proxy.md`。
  **历史**：先由 houleixx 两 PR 落地→验证可用→应要求回滚→再以一方提交按同设计重新引入（git 史含 merge→revert→re-add）。测试 `agent/test/asr-proxy.test.js`。

Secrets (`wrangler secret put`): `SESSION_SECRET` (same value as Pages — verifies Apple JWTs;
anon tokens work without it), `CLAUDE_API_KEY`, **`FILES_TOKEN`** (= Pages FILES_TOKEN; authenticates
`mine.py`'s `POST /agent/notify` — if missing, notify 401s and status never updates).
Deploy: `cd ~/code/jianshuo.dev/agent && npx wrangler deploy`.

**语音编辑引擎 = Haiku（2026-07-04，用户要求提速）**：R2 `config/model.json` 加
`"editModel":"claude-haiku-4-5"`（每轮 `resolveEditModel` 动态读，零部署即生效；库级语音指令同
通道一起换；挖矿模型仍 opus-4.8 不动）。计价 `usage.js PRICE` 是**精确键匹配**——editModel 必须
写 `claude-haiku-4-5` 这个键名，写带日期后缀的 id 会让计费查不到、成本记 0。

## 长按操作菜单（2026-07-04，worker 已上线，iOS 已在 main）

文章详情页长按**已出图的配图** / **段落**弹原生分组菜单，点选把配置好的指令（含该图精确
`[[photo:KEY]]` 或 第N行+开头引文）塞进现有语音编辑通道执行。spec（含定稿 JSON 契约与全部
指令文案）= `docs/superpowers/specs/2026-07-04-longpress-actions-menu-design.md`；计划 =
`docs/superpowers/plans/2026-07-04-longpress-actions-menu.md`。

- **服务端唯一新增 `GET /agent/ui-config`**（agent worker，任意有效用户 token，401 无 token）：
  按页面命名空间的 UI 配置文档（`pages.voice-editor.longpress.image/text`），真源 =
  `agent/src/ui-config.js` 字面量，**R2 `config/ui-config.json` 存在且带 schema+pages 则整体
  覆盖**（照 community-blocklist 先例，改 R2 = 零部署调菜单/文案）。scope 已解析未用，为
  per-user 合并预留。测试 `agent/test/ui-config.test.js`。
- **v1 菜单**：图片「图片风格」= 卡通(宫崎骏)/广告(用户定稿的设计师重设计指令)/水彩/素描/油画/胶片
  （`{{KEY}}`→relKey，PhotoTile 内替换）；文字「改写这段」= 更简洁/更口语/更书面/扩写一点
  （`{{LINE}}`/`{{QUOTE}}`=段首15字、双引号换单引号）+「插入图片→公众号题图」（指令直接说
  「放在文章最前面」+2.45:1，Claude 自己调 `new_photo` after_line=0；**不传 size 参数**，比例
  由提示词约束——用户定）+ 客户端本地「拷贝」（不进配置）。
- **iOS**：`UIConfigStore.swift`（Codable 模型 + 详情页出现时拉取 + UserDefaults 缓存 + 与服务端
  一致的内置兜底，schema>1 保留现值）、`ConfigMenu.swift` = **自绘覆盖层 `LongpressMenuOverlay`**
  （2026-07-04 视觉定稿：系统 contextMenu 改不了设计稿的暖纸配色/棱角，弃用）——正文 `.blur(3)`+
  scrim 压暗、被按元素抬起带大投影、#FAF6EF 菜单卡圆角13、组间 7pt 厚分隔、submenu 原位替换 +
  灰底返回行（设计稿 `Long Press Actions.dc.html` 2a/2b 的 token 全套）。挂载在
  `RecordingDetailView`：PhotoTile 仅 `image != nil` 时挂 0.35s 长按手势（制作中/失败态无入口、
  不挡重试按钮）；**段落行为挂菜单取消了 `.textSelection`**（手势冲突），「拷贝」行补偿。点选 =
  `agent.enqueue(...)`（与口述/插入照片同入口，队列/「正在改」/placeholder 全复用）。
- 部署状态：worker 已 deploy + 线上冒烟（401/200 + 菜单内容）；iOS 已 cherry-pick 到 main，
  **真机手测待做**（长按图→卡通→placeholder→出图；段落→更简洁；题图→顶部横幅；拷贝；
  制作中无菜单）。

## SDUI 自定义首页 — 方向已放弃，分支已删（2026-07-04）

**用户决定不要 SDUI 自定义首页方向**。Phase 1（iOS 渲染引擎：PageModel/PageStore/PageRenderer/
HomeLists + 测试 target，全部只在分支上、从未进 main）随分支 `design/sdui-homepage` 一起删除。
**找回**：永久存档 tag **`archive/sdui-homepage`**（已推 GitHub）= 删除时的分支尖（含 SDUI 全部
10 个 commit + 长按菜单 4 个），`git checkout archive/sdui-homepage` 查看，或
`git branch <名> archive/sdui-homepage` 重建分支，或 cherry-pick 单个 commit。长按菜单功能已
cherry-pick 单独活在 main；`users/<sub>/page.json` 的 R2 契约描述、两份 SDUI spec/plan 文档
（`2026-06-28-voicedrop-sdui-homepage-*`）都只在 tag 里（main 从未有过）。

## Community (VD社区)

### Apple App Store Guideline 1.2 — UGC compliance (2026-06-28)

VD社区 is cross-user UGC, so all four 1.2 pillars are implemented (and described in the App Review
notes `fastlane/metadata/review_information/notes.txt`):
- **① Filter (proactive, at share time):** `functions/lib/moderation.js` `checkArticlesShareable` scans
  the article's title+body for unambiguous objectionable keywords (CJK substring, ASCII word-boundary)
  when a user shares; `community/share` returns 403 `content_flagged` on a hit. **Zero-cost / zero-LLM** —
  runs only on share, not on every generation. Tunable without deploy via R2 `config/community-blocklist.json`
  (merged with the built-in list). Tests: `agent/test/moderation.test.js`. **History:** an earlier design did a
  Claude-haiku moderation pass at *generation* time (`miner.js moderateArticles`, stamped `doc.moderation`),
  but that was removed (judged every article incl. private ones); the function stays defined-but-dormant and
  `community/share` still honors a legacy `doc.moderation.flagged` defensively.
- **② Report → immediate takedown + review:** `POST community/report/<shareId>` (any signed-in user) writes
  `community/reports/<shareId>.json`, which `community/list` filters out **immediately** (hidden pending
  review). Admin reviews at **`/voicedrop/admin/reports`** (`GET community/reports` + `POST community/resolve/<id>`
  `{action:remove|restore}`). iOS ⋯「举报」calls report + removes locally + dismisses. 24h SLA (in the copy).
- **③ Block users:** ⋯「屏蔽此用户」→ `BlockStore` (`CommunityModeration.swift`) — **local UserDefaults only,
  never sent to the server**; the feed filters blocked authors client-side. Managed in 设置 → 已屏蔽用户.
- **④ EULA + contact:** first time a user toggles 「VD社区可见」, `CommunityTermsSheet` (社区公约, zero-tolerance)
  must be agreed (`CommunityTerms.agreed`). 设置 has 社区公约 + 联系我们/内容投诉 (mailto `jianshuo@hotmail.com`).

**2026-07-06 review (1.0 build 160) rejected on 3 counts** — response in progress:
- 5.1.1(v) no account deletion → **fixed**: `POST account/delete` (Files API) + 设置→账户→删除账户 (`AccountView.swift`), see Files API section.
- 1.2 UGC boilerplate again → all four pillars were already in build 160; the missing piece is the **App Store Connect age rating must be 18+** (ASC metadata, not code). Review notes updated (`fastlane/metadata/review_information/notes.txt`) to spell out every bullet incl. 18+, immediate-removal (report + unshare), 24h SLA + ejection.
- 2.5.4 UIBackgroundModes audio "plays no audible content" → it's for background RECORDING (legit use of the audio mode: lock-screen dictation + App Shortcut record). Keep the key; reply needs a physical-device screen recording showing recording continuing on the Home Screen.

App Store status: 1.0 / **build 101** submitted `WAITING_FOR_REVIEW` (2026-06-28, the UGC-compliant build).
Resubmit playbook = ASC API delete `appStoreVersionSubmission` (or cancel reviewSubmission) → PATCH version
`build` relationship to the target build → dispatch `appstore` workflow (`fastlane release skip_build:true`
uploads metadata incl. review notes + submits the attached build; `guard_not_in_review` needs the version
NOT in WAITING_FOR_REVIEW/IN_REVIEW first, hence the cancel).

The home has two tabs — **我的录音** + **VD社区** (`LibraryView.swift`). A user shares one of their
articles to a public community from the detail-view ⋯ menu (分享到 VD社区). Files API routes
(`functions/files/api/[[path]].js`):
- `POST community/share/<articleKey>` — writes a **schema-2 pointer** `{schema:2,shareId,owner,articleKey,
  author,firstSharedAt,replyTo?}` (NO content copy), preserving the original `firstSharedAt` on re-share.
  **Title/body are read LIVE from `articleKey` every request** — source edits show immediately (despite the
  word "snapshot" used elsewhere, this is a live pointer, not a frozen copy).
- `GET community/list` — all posts, **newest-first by first-share time**; each carries `mine` (owned).
- `GET community/get/<shareId>` · `GET community/shared/<articleKey>` (is-it-shared → drives the
  分享/更新 menu label).
- `POST community/unshare/<shareId>` — **owner-only** (403 otherwise); deletes the pointer.
- `GET community/get/<shareId>` also returns **`owner`** (= the photos' `users/<sub>/` prefix) and, for legacy
  posts, **`photos`** — the client joins `owner + relkey` (resolving legacy `[[photo:N]]` via `photos`) to build
  the full key, then loads the image from the universal `GET /files/api/photo/<full key>` endpoint (see Files API).
- **Inline community photos (2026-06-26):** previously `CommunityPostView` called `ArticleBody.stripMarkers` →
  shared posts lost every photo. Now it renders `ArticleBody.segments` and draws each `[[photo:…]]` as a
  `CommunityPhotoTile` whose `fullKey = owner + relkey` loads from the public `/files/api/photo/<key>` endpoint
  (`CommunityStore.photoData(fullKey:)`, no auth). **One photo logic everywhere** — the in-app community, the
  owner's own detail view (`PhotoTile`, full key via `whoami`), the public `/voicedrop/<token>` page, and any
  exported HTML all read straight from the photo's original R2 location via that same `photo/<key>` endpoint (the
  earlier gated `community/photo/<shareId>/<token>` approach was dropped). Needs both a Pages deploy **and** a new
  app build (TestFlight).
- **Orphan self-heal (2026-06-26):** because posts are live pointers, deleting the underlying recording
  used to leave an empty, titleless row that opened to「这篇分享已不可用」. Now `list`/`get`/`replies` resolve
  each pointer through `liveDocForPointer(pointerKey, p)`: live article present → show it; article gone **and
  audio gone too** (whole recording deleted) → **reap** the orphan pointer + drop it; article gone but **audio
  still present** (article mid-`重新生成` delete-then-remine) → keep the pointer, just hide the post until the
  re-mine lands (so regenerating a shared post never silently un-shares it). No app update needed — pure
  Pages-function fix; existing orphans vanish the next time anyone loads VD社区.

App side: `Community.swift` (`CommunityStore`, read-only `CommunityPostView`). Owners get swipe-to-remove
on their own posts. **⋯「分享」(2026-06-28)** now shares the public `/voicedrop/<shareId>?s=<i>` link via the
SAME `ArticleShareItem` as 我的录音 (full text + first-photo `LPLinkMetadata`), so a 社区 post gets a WeChat
link card with image + description (was plain text only, no card). Relies on `[token].js` resolving the
community shareId (above) — **needs a Pages deploy + a new app build**.

### 推荐排序 sidecar — voicedrop-reco（2026-06-26）

社区 feed 的排序由一个**独立、可随时拔掉**的 Worker `voicedrop-reco`（`~/code/jianshuo.dev/reco/`）
负责。canonical 文档 = `reco/README.md`。要点：
- 核心 `community/list` **零改动**（仍按 firstSharedAt 倒序）。app 拿到 list 后再问 reco
  `POST /reco/rank` 要顺序；**reco 挂/超时（2s）→ app 回退时间序**，feed 照常。
- reco 自带 D1 表 `engagement`（view/finish/like/report，每用户去重），算
  `(1 + view·1+finish·4+like·3+reply·5+report·(-9))/(ageHours+2)^1.5` + 作者打散。
- 互动上报：详情页进帖→view、滚到文底→finish、❤️→like、举报→report（`POST /reco/engage/<shareId>`，fire-and-forget）。
  ❤️ **不显示计数**，只反映"我赞过没"。**举报（2026-06-27）= 一次 engage 互动，负权重 `report:-9`（≈3 个负点赞）**：
  详情页 ⋯ 菜单「举报」→ 确认弹窗 →`engage(report)`，一次性、不可撤销、每用户去重；一个举报就把冷启动帖压成负分沉底，
  但不会让一两个举报抹掉一篇真有互动的热帖（防滥用）。权重 `W.report` 在 `reco/src/ranking.js`，可调。
- ❤️ **本地态同步修复（2026-06-27）**：`CommunityPostView` 点 ❤️ 时除了发 engage，还同步 `store.likedShareIds`，
  否则退出再进（`.task` 从 `likedShareIds` 重新播种 `liked`）会丢掉这次点赞，必须刷列表才回来。
- reco **完全独立：不碰 R2、不反调核心、不共享任何 secret**（2026-06-27 改）。互动上报用 app 的
  **anon token** 鉴权（`CommunityStore` 的 engage/rank 发 `AuthStore.anonToken`）——因为 Apple
  登录的 session scope 本身就是 `users/anon-<hash>/`，anon 与 session 解析出同一个 user_sub，所以
  reco **无需 SESSION_SECRET** 也能正确识别所有用户（含 Apple 登录者）。**reco 上当前未设、也不需要
  SESSION_SECRET**（auth.js 仍保留验 JWT 的死代码，无害）。部署独立：
  `cd ~/code/jianshuo.dev/reco && npx wrangler deploy`。
- **token 计费已做（2026-06-28）**：见下面「## 算力计费」。独立 D1 库 `voicedrop-usage`，绑在 **agent worker**（不进 engagement、不进 reco）。

## 算力计费 (usage billing)（2026-06-28 上线）

给每个用户一个**赠送的「算力」额度**，按真实成本扣，扣到 0 停。**算力 = 钱穿了件马甲：23 算力 = ¥1**（锚定钉死）。
单位**无现金价值、不可提现、不可退款**（绕开记账/退款法务风险）；将来真要「充值收钱」是另一个项目（带支付+法务），本期不做。
Spec/计划：`docs/superpowers/specs/2026-06-27-voicedrop-usage-billing-design.md` + `docs/superpowers/plans/2026-06-27-voicedrop-usage-billing.md`。

- **落点 = agent worker（不另起 worker）**：计费必须和花钱的地方紧耦合，所有 ASR+Claude 调用都在 `voicedrop-agent`。
  新 D1 `voicedrop-usage`（binding `USAGE`，id `317b7cd5-e926-49f0-a6c9-497e4740aea8`），`agent/migrations/0001_usage.sql`。
- **计价单一真源 `agent/src/usage.js`**：`FX=7.3` `RATE=23`；`PRICE`（sonnet $3/$15、haiku $1/$5 每 Mtok）；ASR `¥0.8/小时`。
  钱一律 **微元（1e-6 元）整数**存，`Math.ceil` 算（只多收不少收，绝不亏）；未知模型成本 0。显示用 `uyToSuanli`/`uyToYuan`。
  手感：典型录音挖一篇 ≈ 2 算力，haiku 改一刀 ≈ 1.4、sonnet ≈ 4；新用户一次性送 **500 算力**。
- **D1 两表 `agent/src/usage_store.js`**：`account`(user_sub PK, balance_uy/granted_uy/spent_uy 微元) + `ledger`(只追加流水, kind=grant|spend, reason, detail JSON, balance_uy 快照)。
  `ensureAccount` 懒建 + 首次送 500（`INSERT OR IGNORE` 防并发首触竞态，只有真创建者落 signup 行）；`debit`/`grant` 用 `db.batch()` 原子化；
  `editCount` = `COUNT(DISTINCT json_extract(detail,'$.turn_id'))`（数**真实编辑次数**，不是 Claude 调用次数——一次编辑是 agentic 循环含多次调用）。
- **挖文章计费（`agent/src/miner.js`）**：`meteredMineGate(env.USAGE,scope,durSec,now)` 在 `.json/.empty` skip 之后、ASR 之前判：
  `>3h→too-long`、余额≤0→`no-credit`、否则 ok。挡住就写 `.blocked` 标记（`{status,reason}`），`no-credit` **非终态**（下次余额够了删标记重挖；`too-long` 终态）。
  扣费：ASR（`audio_info.duration` 毫秒，有上限钳制防 1000x）+ 每次 Claude（mine 与 text 路径都扣），全 best-effort（`try/catch`+`if(env.USAGE)`，**失败绝不中断挖文章**）。
- **语音编辑计费（`agent/src/index.js` ArticleEditor）**：`meteredEditGate` 在调 Claude **之前**判（不足/超 100 编辑 → 拒绝、不空花），
  通过队列广播 `{type:"error",id,message}`（"算力不足，无法继续编辑" / "这篇已达编辑上限（100 次）"），队列把 gate-拒绝标 terminal（不无限重试）；每次编辑 Claude 调用后 best-effort 扣费。
- **`.blocked` 写入路由**：`functions/files/api/[[path]].js` 的 `PUT articles/<sub>/<stem>/blocked`（镜像 `/empty`）→ R2 key `users/<sub>/articles/<stem>.blocked`；
  文章 DELETE 时连 `.blocked` 一起清。三处 key 一致：写入路由 = miner stale-delete = iOS/list 检测。
- **读/admin 路由（agent worker，`handleUsageRoute`）**：`GET /agent/usage/balance`、`GET /agent/usage/ledger?limit=N`（用户自己 scope，401 无 token，D1 缺失/抛错→`degraded` 不崩）；
  `POST /agent/usage/grant`（**admin `FILES_TOKEN`**，活动送算力的原语，`reason=campaign:*`）、`GET /agent/usage/admin/accounts`（admin，全量）。**admin 路由严格鉴权**，用户路由只读自己。
- **防滥用硬闸**（独立于余额）：单条录音 ≤3 小时、单篇编辑 ≤100 次（真实编辑数）。¥10 量级余额通常先触发，这俩只拦极端。
- **iOS**：`UsageView.swift`（算力余额 + 明细 + "无现金价值"说明，从 `/agent/usage/balance|ledger` 读）；入口在 `AccountView.swift` 账户卡；
  `Library.swift`/`LibraryView.swift` 加 `.blocked` 检测 → 徽标 **余额不足 / 录音过长**（`.json/.empty` 优先）；`AgentSession.swift` 把编辑错误送进 `replyBubble`。
- **admin 账本页**：`voicedrop/admin/usage.html`（贴 admin token 看全量余额/消费，仿 `mine.html`）。
- **部署**：worker `cd ~/code/jianshuo.dev/agent && npx wrangler deploy`；Pages `cd ~/code/jianshuo.dev && npx wrangler pages deploy . --project-name jianshuo-dev --branch main`。
  ⚠️ **Pages 部署坑 1（node_modules）**：根目录有 `.claude/worktrees/*/node_modules`(>25MiB) 会让 `pages deploy .` 报错，且 `.assetsignore` 当前匹配不到深层 node_modules。解法：从 main 的**干净临时 worktree** 部署（`git worktree add --detach <tmp> main` → 在里面 `pages deploy .`），只传已提交内容。`.assetsignore`（排除 `reco/`+`node_modules`）**必须存在**，别误删。
  ⚠️ **Pages 部署坑 2（PREVIEW 而非 PRODUCTION，2026-07-01 踩过）**：`jianshuo-dev` 是 direct-upload 项目，生产分支 = `main`。`wrangler pages deploy` 按**当前 git 分支名**决定环境——从 `--detach` 的**游离 HEAD** worktree 部署，分支名是 `HEAD` → **静默部到 Preview（别名 head.jianshuo-dev.pages.dev）**，`jianshuo.dev` 生产不更新！症状：新 Function 路由带 token 返 **405**（落到老代码兜底），无 token 返 401（老代码也有鉴权，迷惑）。**必须显式加 `--branch main`**（或在非游离、真 checkout 到 main 的 worktree 里部）。验证：`npx wrangler pages deployment list --project-name jianshuo-dev | grep Production` 第一行 Source 应是你刚部的 commit；`curl` 生产带合成 anon token 应 200。
- **后续可做的小优化（非阻断，已记 `.superpowers/sdd/progress.md`）**：iOS `Entry.id=ts` 同秒可撞（改用 ledger 自增 id）；`fetchBlockReason` 串行可并行；usage 路由测试可补全；负 grant 语义。

## iOS app (`VoiceDropApp/`)

Home is **`LibraryView.swift`** (`RootView.swift` → `NavigationStack`) — a white-card list with two
tabs **我的录音 / VD社区**, a docked **pure-red record key** (→ full-screen recording takeover), and a
gear → **设置** (redesign "方案二"; the old `ContentView` 3-tab `TabView` is superseded).
- **我的录音** `LibraryView` + `Library.swift` (`LibraryStore`) — recording list with live badges
  **待处理 / 听录音 / 挖文章 / 已成文 / 无语音** (the two in-flight phases 听录音→挖文章 replace the old single
  处理中, both animated spinners). Phases are pushed via `StatusSession` (no polling); a just-uploaded
  take shows an **optimistic 待处理** row immediately (same `audioName` = same row id, so the badge changes
  in place — no disappear/flicker). 已成文 rows show the **article title** (concurrent fetch, cached by
  articleKey). Swipe-left → red **删除整条录音** (optimistic). **Easter egg**: long-press the 已成文 badge →
  重新生成这篇文章 (`deleteArticle`: delete article+markers, keep audio, then **`POST /files/api/mine`** to
  kick mine.yml right away — the row re-flows 待处理→听录音→挖文章→已成文; not "next cycle"). Confirm alert
  copy: 「重新生成这篇文章？／重新生成／删掉当前文章、保留录音，立即重新挖一遍。生成的内容可能和原来不同。」
- **VD社区** — see the Community section above.
- **录音 (takeover)** `RecordSession.swift` — full-screen, opens **idle** (tap-to-record). Records to a
  **staging name** `recording-<ts>.m4a`, promoted to the enriched `VoiceDrop-*` name only after finalize
  → fixes the moov-less/0-byte corrupt-upload race; uploads on finish. **Encoder = speech-tuned AAC
  (`Prefs.recorderSettings` in `Theme.swift`, 2026-06-28):** mono, **标准 16 kHz / 32 kbps · 高 24 kHz /
  64 kbps** (was 44.1 kHz / 64k·96k). The audio only ever feeds in-app playback + Volcano ASR (16 kHz native),
  so 44.1 kHz wasted bits — the new rate **halves the file size & upload time** (≈1.2 MB vs 2.4 MB per 5 min on
  标准) with no ASR-accuracy loss. New recordings only; old files & the `.m4a`/moov contract unchanged. **Faint 拍照 trigger** (spec =
  `handoff_recording_camera/README.md`): a **very subtle thin `camera` icon** (`#A89E8E` @ 0.45 opacity, no
  container) in the blank area right of the 停止 key, at that area's **horizontal midpoint (≈75% of screen
  width)**, with a 「拍照」label (11pt `#C2B8A8`) below it. Implemented as an `.overlay(alignment:.center)` on the
  停止 button (icon center = 停止 circle center) with `.offset(x:98)`, so it never affects layout and the 停止 key
  stays整屏居中. Tapping opens a full-screen camera (`PhotoCapture.swift`,
  `AVCaptureSession` video-only so recording is NOT interrupted). Camera design = "Photo Capture.dc.html". **Square
  viewfinder** (rule-of-thirds grid + border + empty-state hint), top bar = live "● 录音中 · MM:SS" (or
  "已拍 N 张" pill once shots exist) + a **完成** button (gray→orange) that closes and uploads. Bottom bar =
  photo-library import (left, `PHPickerViewController`, multi-select≤9, no permission prompt), shutter
  (center), front/back **flip** (right). **Continuous capture:** camera stays open; each shot lands in a
  **filmstrip** of thumbnails, each deletable via a ✕ — shots are held locally and **all uploaded on 完成**
  (so delete is a pure local removal, no R2 orphan race). Every shot/import is center-cropped to a 1:1
  square (≤1080px JPEG, auto-quality to <900KB, WYSIWYG with the square preview; `SquareImage.jpeg` is a
  nonisolated top-level helper so off-main capture/PHPicker callbacks don't trip a main-actor assertion)
  and uploaded to `photos/<sessionTs>/<captureTs>.jpg`. **Rotation follows the phone's PHYSICAL orientation,
  NOT a hardcoded angle** (`AVCaptureDevice.RotationCoordinator`, iOS17+): preview angle =
  `videoRotationAngleForHorizonLevelPreview` **observed via KVO** (the coordinator resolves orientation
  asynchronously, so a single synchronous read returns a stale value — this was the bug behind the
  front-camera-sideways saga); capture angle = `videoRotationAngleForHorizonLevelCapture` read at capture time
  in `configurePhotoConnection()` (the photo connection is recreated when the input swaps on flip, so a
  one-shot post-flip apply races it). The coordinator is rebuilt + re-observed for the new device on flip.
  **Do NOT hardcode `videoRotationAngle = 90` and do NOT manually mirror the PREVIEW** — preview front-mirror
  is left to the system (`automaticallyAdjustsVideoMirroring`); manual `isVideoMirrored` on the preview
  reverses the rotation sense and scrambles the front camera. The photo connection IS manually mirrored for
  front (selfie WYSIWYG). **`sessionTs` = the recorder's own start instant** (`AudioRecorder.startDate`, same source as the
  audio filename — NOT a separate `Date()`, which drifted across a second boundary and broke audio↔photo
  correlation). No visible affordance on the record screen yet — enable a real button once it proves useful.
- **文章详情** `RecordingDetailView.swift` — **顶部播放键 + 进度圆环** (design "Player Edit Toolbar"): 成文页
  去掉整条 inline 播放条，播放键收进**顶部导航右上角、在 ⋯ 左边**（40pt，外圈 2.5pt 细圆环显示 `player.progress`，
  内圈赭红实心 play/pause），正文上移、阅读区更大。进入编辑态时播放键位置不动，在播放键与 ⋯ 之间插入
  「插入照片 + 撤销/重做」，**⋯ 始终保留**（`navPlayButton`/`insertPhotoButton`/`undoRedoGroup`/`moreMenu`，间距 10）。
  ⋯ 改为白底灰点（与赭红圆环主次分明）。
  **待处理 / 无语音** 状态仍用居中的大 `playerCard`（设计只重做了成文页）。 + the article
  rendered **with photos混排 inline** (`ArticleBody.segments` splits the body at `[[photo:N]]` markers;
  `PhotoTile` downloads each via the auth'd Files API and shows a full-width square; unreferenced photos
  append at the end). Per-article chip switcher only when >1. **Voice-edit locators** (design "Voice Edit
  Locators"): while the user holds-to-talk, **line numbers** (第N行) fade
  in floating in the **left margin** — absolutely positioned via `.overlay(alignment:.topLeading)` + `offset`
  so the text never reflows — and **图N badges** fade in on each image's top-left corner. **`bodyRows()` numbers
  EVERY row — paragraph AND image — on ONE continuous 第N行 counter (2026-06-27)**: a photo marker is its own
  line and consumes a line number too, so paragraph line numbers accumulate across images and the displayed
  第N行 lines up 1:1 with the raw body the agent edits (an image row shows BOTH its 第N行 in the margin and its
  图M badge in the corner). Before this, 第N行 counted text paragraphs only — an image was skipped, so a
  paragraph after an image showed a number lower than its true line position ("行号对不上").
  **The model READS the line number, never counts it (2026-06-28).** The whole point is "模型理解的行 == 用户标的行".
  Relying on the model to count 第N行 from the body is fragile (it miscounts long/image-laden bodies), so the
  worker now hands it the numbers: `agent/src/linenum.js` (`numberBodyRows`/`locatorTable`) numbers a body with
  the EXACT algorithm as iOS `bodyRows()`+`ArticleBody.segments` (continuous counter, photo-marker line = one
  line + 图M), and `edit-turn.js` injects a **行号对照** block (`第3行：…` / `第4行 = 图2：[[photo:…]]`) into the
  user message for the article the user is viewing. The prompt (`index.js` REVISE_SYSTEM) tells the model to
  locate 第N行/图M **strictly by that table, not by counting**, and to omit numbers from output. `linenum.js` is
  the SHARED contract — **if you change the numbering, change BOTH `linenum.js` (with its `test/linenum.test.js`)
  AND the Swift `bodyRows`/`segments` in lockstep**, or the model's number drifts from the user's. Multi-article:
  iOS renumbers 第1行 per displayed article, so the app sends **`articleIndex`** with each `instruct`
  (`AgentSession.swift` `EditRequest.articleIndex`, persisted in `EditQueueStore`/`PersistedEdit`, carried
  through the durable queue's new `article_index` column → `runEditTurn({articleIndex})`), and the worker numbers
  THAT article. Old apps omit it → defaults to article 0. **iOS build + worker deploy must ship together** — a
  mismatch (e.g. old app's text-only numbers vs. new worker's image-inclusive table) mislocates edits. The live
  transcript bubble tints spoken 第N行/图N references accent (`highlightedTranscript`, regex `第[0-9]+行|图[0-9]+`).
  ⋯ menu: **发布/更新公众号草稿** ·
  **分享/更新 VD社区** · 系统分享 (labels flip once published/shared) · **编辑 = hold-to-talk voice editing**
  (serial queue, mic-as-indicator — see the agent Worker section). 系统分享 = `share()`: builds the full
  text (所有 section 标题+正文, markers stripped) + the `?s=<section>` short link, wrapped in
  **`ArticleShareItem`** which adapts per target — WeChat gets the bare URL (rich link card from page og
  tags + `LPLinkMetadata` title/首图), X / 其它 get the combined inline-URL string (X drops a separate URL
  item). See the WeChat link-card note above.
- **设置** `SettingsView.swift` (`SettingsStore`) — **名字** + **文风** (→ full-screen editor sheet) →
  `users/<sub>/CLAUDE.md`; **微信公众号** AppID/AppSecret (format- + live-validated before save) →
  `WECHAT.json`; **账户** anon ID + copy ID / access token. **「其他」card (2026-06-28)** now holds just
  **关于**（NavigationLink → `AboutView`）+ **版本**; the four secondary items（隐私说明 / 社区公约 / 已屏蔽用户
  / 联系我们·内容投诉）moved one level down into `AboutView` (in `SettingsView.swift`), shown only after tapping 关于.

## Server miner — now the Worker DO (`agent/src/miner.js`)

- **The Python miner `mining/mine.py` was deleted (2026-06-26).** All mining runs in the Worker `Miner`
  DO (`agent/src/miner.js`, a JS port of the old mine.py), triggered on upload + 6-hour cron + `POST
  /files/api/mine` (→ dispatches the Worker DO, **not** a workflow). Idempotent: skips anything with a
  `.json` or `.empty` marker. The only surviving Python is `mining/relay_server.py` (the WeChat publish
  relay — see the WeChat section above) and the Volcano ASR helpers; `mine.py`/`publish_wechat.py` are in
  the `mining/REMOVED.md` tombstone with git-restore commands.
- **R2 list truncation (fixed 2026-06-24):** R2 `list()` has a hard `limit: 1000`. With >1000 objects in the bucket (audio × 3 files + community/assets/links), the `/list` endpoint silently truncated — newest article JSONs (alphabetically last) were cut off, so the miner saw them as unprocessed and re-mined every run. Two fixes: (1) `functions/files/api/[[path]].js` `/list` now paginates via cursor loop until `listed.truncated` is false; (2) the miner does a per-key HEAD check (`env.FILES.head(key)`, always strongly consistent) before processing, so a lagged or truncated list can never cause a re-mine. HEAD support also added to the `/download` route.
- Per recording: presign R2 key → Volcano **async file ASR** (empty→`.empty no-speech`) → Claude API (`MINE_MODEL`, default claude-sonnet-4-6) → write `.json`. (No local download/ffprobe — the file API takes a URL.)
- **JSON is forced**: `_articles_from` strips ``` / ```json fences + stray leading `json`, extracts the outermost `{…}`; if unparseable it **raises (retries next cycle)** — never stores raw model text as a body. (Assistant prefill is NOT used — sonnet-4-6 rejects it with 400.)
- Reads the owner's `CLAUDE.md` and appends it after the system prompt.
- ASR = 火山 bigmodel `volc.bigasr.auc`, **resumable across alarm passes** (`miner.js` `transcribeResumable`, 2026-06-28). **Why (long-audio bug):** the old synchronous `asrPoll` blocked one Miner/DO invocation in a `while(deadline)` loop polling `query` to completion; a 60-min recording takes minutes → blows the per-invocation **subrequest limit** ("Too many subrequests") → errored ~90s in, left no marker, retried forever ("ASR timed out"). **Now:** submit once → persist `{taskId,logId,submittedAt}` to an R2 **sidecar `articles/<stem>.asr.json`** → `asrPollBounded` polls ≤`ASR_POLLS_PER_PASS`(3) per pass → not done returns `pending` (keep sidecar, recording stays unprocessed); the **Miner DO `alarm()` reschedules `setAlarm(+MINE_RESUME_MS=10s)` while `runMine` returns `moreWork`**, next pass reads the sidecar and **resumes the SAME task** (no re-submit) until done (delete sidecar) or `ASR_MAX_AGE_MS`(30min) aged-out guard → `.empty asr-error:timeout`. `runMine` spends a `MINE_SUBREQ_BUDGET`(30) per invocation across audio/text/style, deferring the rest (`truncated`→`moreWork`). Done-detection still keys off `audio_info.duration` (or `result.text`); empty → `.empty no-speech`; deterministic Volcano error (e.g. 45000151) → `.empty asr-error:<code>` (sidecar deleted), stops retrying; non-deterministic errors keep the sidecar → retry next pass. **Usage billing intact:** the `done` return still carries `asrDurMs`, charged once (pending passes return before any debit). Tests: `agent/test/asr-resumable.test.js`. *(The old `mining/volc_asr_file.py` Python helper is dead — ASR runs entirely in the JS Worker miner.)*
- Timestamped profiling logs end with `DONE: N mined · M empty · Ts [ASR x% · LLM y% · net z%]` (ASR is the long pole).

## CI / CD & concurrency

- `mine.yml`: `concurrency {group: mine, cancel-in-progress: false}` → **never two mine runs in parallel** (serialized, latest pending wins).
- `build.yml`: `concurrency {group: build, cancel-in-progress: false}` → also serialized, so two builds can't collide on the same `latest_testflight_build_number+1`. Ignores `mining/**` pushes (miner changes don't trigger TestFlight builds).

## Release state (as of 2026-07-15)

- **App Store**: **1.3 在售**（2026-07-15 过审自动发布，guard_not_in_review 放行 1.4 提审即为旁证）；**1.4 / build 247（`1beb7de`，PostHog 24 事件 + 上下文 super properties）已提审 `WAITING_FOR_REVIEW`**（2026-07-15，`automatic_release: true` 过审即发布）。ASC 隐私标签用户已手动更新（2026-07-15：标识符→用户 ID + 使用数据→产品交互，关联身份、用途=分析、不追踪）。提审流程：project.yml MARKETING_VERSION 垫到目标版本 + 更新双语 `fastlane/metadata/*/release_notes.txt` → push main（不带 `[tf]`，只验编译）→ dispatch `appstore`（`fastlane release skip_build:true` 复用 TestFlight 已处理 build）→ 打 `release/<v>` tag 推远端（CI 里 lane 打的 tag 不会推回来）。(Resubmit = cancel review submission via ASC API `PATCH reviewSubmissions/{id} canceled:true`, then dispatch `appstore`.)
- **TestFlight public beta**: external group "Public Beta", link **https://testflight.apple.com/join/PbzFFRS2** (works once build 18 passes Beta App Review). Private group "Private Beta" has `gyjll@hotmail.com`.
- Beta review contact reused from Cathier app: Jianshuo Wang / jianshuo@hotmail.com / +8613916146826.

## Tests — backward-compat is the contract (`agent/test/`, `npm test`)

117 vitest cases (run `cd ~/code/jianshuo.dev/agent && npm test`). The guiding rule:
**the server must forever serve old data AND old clients** — a new app build (e.g. a
future build 94) ships only after the old contract is pinned green. New version → push
only once the old one is stable. Coverage by legacy surface:

- **Schema migration** (`article-store.test.js`): v1 (top-level title/body) → schema-2
  (top-level `articles`+`history`) → schema-3 (`versions[head]`) all migrate in memory
  without losing content. `resolveArticles`/`withTopLevelArticles` (the SINGLE source of
  truth every reader shares) are unit-pinned directly, across all three shapes + empty.
- **Legacy docs on disk through the new API** (`articles-api.test.js`): reading/writing a
  v1 or schema-2 doc via `GET/PUT /articles/<stem>` reconstructs top-level `articles`,
  keeps `wechatMediaId`, and a NEW build editing an OLD article keeps the original as v1
  (undo still works). `/download/<key>` (build ≤77 raw-download clients) reconstructs v1 +
  schema-2 + schema-3. Anon-token (`anon_…`, the DEFAULT auth path) + `whoami` go through
  real `onRequest`.
- **Community** (`community-api.test.js`, new): legacy schema-1 inline posts read verbatim
  (markers + `photos` array kept), schema-2 pointers resolve the LIVE article (incl. a v1
  source doc), `list` mixes both schemas newest-first + reaps orphans, the Apple write-gate
  (anon→403 `needs_apple_signin`, admin→403) and owner-only unshare hold.
- **Photo markers** (`photo-markers.test.js`): new `[[photo:<relkey>]]` AND legacy
  `[[photo:N]]` both resolve/strip.

When changing any reader of an article/community doc, add the legacy shape to its test
BEFORE the change — these are characterization guards (a v1-fallback removal was verified
to fail 4 of them). Don't delete a legacy branch without deleting its test on purpose.

## 设备配对登录（device-link）— 新设备登录老账号

新设备输入老账号的 **6 位短码**（设置→账户里那串 = `sha256(anon_token)` 前 6 位十六进制，大小写不敏感）→
老设备弹出 **4 位验证码** → 在新设备输入 → 老设备把自己的 `anon_…` 密钥**端到端加密**经服务器中转给新设备 →
新设备 adopt，登录成功。本质 = 把老设备钥匙串里的密钥安全搬到新设备（因为 anon 身份不可重新签发：
`scope = users/anon-<sha256(token)[:32]>/`，服务器不存 token、签不出指向老账号的新 token）。

canonical 设计/计划：`docs/superpowers/specs/2026-06-27-device-link-pairing-design.md` +
`docs/superpowers/plans/2026-06-27-device-link-pairing.md`。

**Worker 侧（`agent/`，jianshuo.dev）：**
- 纯逻辑模块 **`agent/src/devicelink.js`**（vitest 全测）：`genDistinctCodes` / `buildBroadcastMessage` /
  `resolveMatchingScopes`（用 `FILES.list` 按 `users/anon-<6hex>` 前缀去重匹配账号，零注册表）/ 配对状态机
  `createPairing`·`verifyPairing`·`completePairing`·`isExpired`。常量 `CODE_TTL_MS=120000`、`MAX_ATTEMPTS=5`、`MAX_MATCH=10`。
- 新增 **`LinkBroker` Durable Object**（`agent/src/index.js`，`idFromName(pairingId)` 一对一）：存配对状态 +
  持新设备的 wait-WebSocket，`alarm()` 2 分钟自清。薄壳，逻辑全在 devicelink.js。已加 wrangler binding + migration `v4`。
- 新增路由 **`/agent/link/{start,socket,verify,complete,cancel}`**：start 解析匹配账号→每账号一个互异 4 位码→
  向每个匹配 scope 的 StatusHub 推 `link_request{pairingId,code,pubkey}`；verify 命中→推 `link_release`，**不向新设备泄露 scope**；
  complete 鉴权 **callerScope===releasingScope**（只有真主人能放行）→把密文 blob 经 socket 投给新设备。
- **`StatusHub` 广播泛化**（唯一改的现有代码）：`/broadcast` 现转发任意 `payload`，`status_update` 向后兼容（`/agent/notify` 不受影响）。

**端到端加密**：X25519 → HKDF-SHA256（salt `voicedrop-device-link/v1`、info `anon-token`、32B）→ AES-GCM。
`blob = {epk, sealed}`（sealed = `AES.GCM.combined`）。**服务器只过 pubkey 和 blob，从不解密、不持久**（除 complete→ready 瞬时中转）。

**iOS 侧（`VoiceDropApp/`）：**
- **`DeviceLink.swift`**（新）：`DeviceLinkCrypto`（CryptoKit 加解密）/ `DeviceLinkResponder`（老设备：收 `link_request` 弹
  `DeviceLinkApprovalSheet` 显码+「不是我」，收 `link_release` 加密 token→complete）/ `DeviceLinkStore`+`DeviceLinkView`
  （新设备：输 6 位→开 socket→输 4 位→`link_ready` 解密→`AuthStore.adoptToken`→发 `.vdDidAdoptAccount` 刷新列表）。
- `AppleAuth.swift` 加 **`AuthStore.adoptToken(_:)`**（替换匿名身份、清 session）。`StatusSession.swift` 的 `handle` 在
  `status_update` 前先分支 `link_request`/`link_release`。`LibraryView` 接审批卡 + adopt 后刷新。
- **「登录已有账号」入口已从 `AccountView` 移除（2026-07-03，用户要求）**：app 内不再有新设备侧发起配对的 UI，
  `DeviceLinkView`/`DeviceLinkStore`（新设备侧）成为无入口的保留代码——**别删**：协议实现还在被 wjs-voicedrop skill 的
  vd-login.mjs（CLI 扮演新设备）复用参考；老设备侧（`DeviceLinkResponder`/`DeviceLinkApprovalSheet`，挂在 LibraryView）
  仍在服务 skill 登录的审批弹窗，是活代码。同日 `AccountView` 数据卡里的「查看全部文章」行也移除（含
  `SettingsStore.articlesPageURL()` + `ArticlesLinkError`）；服务端 `GET /token/articles` 路由未动（web 文章页还在用）。

**安全**：4 位码 5 次/2 分钟（暴力≈5/10000，且真主人在自己设备看得到登录尝试）；token 全程 E2E；complete 强制 scope 匹配。
**已知延后**：/start 的 IP+token 限流（Worker 无 KV 计数基建，本期只做「必须带有效 bearer」最小闸门）。

**未来扩展（spec §11，本期未做）**：CLI/headless 分身登录——让 skill 以「你」的身份登录某账号，**服务器零改动**（CLI 扮演通用
「新设备」，两处客户端适配：可移植 X25519+AES-GCM、自生成一次性 anon bearer）。方案 A=整把全权令牌复制到 `~/.config`（不可吊销）。

**部署/测试状态（2026-06-28）**：代码完成、Worker 全量测试绿（vitest）、iOS BUILD SUCCEEDED。**Worker 部署 + 端到端两机手测
DEFERRED 给用户**：`cd ~/code/jianshuo.dev/agent && npx wrangler deploy`（含 migration v4）+ iOS 推 main→TestFlight。
两个特性分支 `device-link-pairing`（jianshuo.dev + voicedrop 各一），待合并。

## 接受分享 (Share Collect) — iOS Share Extension 收件（2026-07-01，已合并 main + 已上线）

VoiceDrop 是 iOS 系统分享目标。从别的 app 点「分享」→ 自定义 SwiftUI sheet（**替换了老的 `SLComposeServiceViewController`**）按内容类型分派：

| 分享 | sheet | 去向 |
|---|---|---|
| **音频 / 图片** | 成文 sheet（`AudioComposeView` 波形版 / `PhotoComposeView` 缩略图版） | 挖文章 |
| **文字 / 网页 URL / 文档(.pdf/.docx/.rtf)** | `StyleDatasetView`（风格数据集） | 风格语料 →「提取文章风格」蒸馏成写作风格新版本 |

- **客户端提取一切文字**（`VoiceDropShare/ShareExtraction.swift`：PDFKit / `NSAttributedString` / readability——微信特判 `#js_content`），服务端不碰 docx/URL 解析。
- **图片 = 静音占位 `.m4a` + 照片传 `photos/<sessionTs>/`**，复用 miner「无语音+有照片→vision 看图写短文」分支（`IMAGE_ONLY_SYSTEM`，`agent/src/prompts/mine.js`）。**关键不变量：`PhotoComposeView.generate()` 必须先传完所有照片、最后才传静音音频**——因为上传端点对任何 `VoiceDrop-*.m4a` 落地就 `waitUntil(dispatchMine)`，音频先到会让 miner ASR 空转→找不到照片→写 `.empty(no-speech)`→照片被孤儿化。`sessionTs`(照片路径) 与 `audioName` 时间戳同源于一个 `Date()`，miner `sessionTs(audioKey)=parts.slice(1,5).join("-")` 精确匹配。
  - **静音音频内嵌代码，不用 bundle 资源（2026-07-01 修）**：`VoiceDropShare/SilentAudio.swift` = 960 字节静音 m4a 的 base64 常量（`putData`）。原来 `Bundle.main.url(forResource:"silent")` 在 release build 可能返 nil → 占位音频不上传 → 照片成孤儿、列表不显示。服务端同一份在 `agent/src/silent-m4a.js`（写风格 intro 用）。
  - **图片解码用 ImageIO 降采样，防 OOM 崩溃（2026-07-01 修，关键）**：`SquareCrop.jpeg(fromFile:)` 用 `CGImageSourceCreateThumbnailAtIndex`（`kCGImageSourceThumbnailMaxPixelSize:640`）**在解码阶段就限到 ≤640**，永不加载全分辨率位图。原来 `UIImage(data:)+draw` 会全分辨率解码大相机照片 → 在 Share Extension ~120MB 限制里 OOM → 进程被杀 → 分享瞬间消失、零上传。顺带把 vision token 从 ~1500 降到 ~545/张。
- **iOS 主 app 零改动**：占位录音是普通录音，天然进「我的录音」列表/详情/删除；图片经 `[[photo:key]]` 内联渲染。
- **iOS 文件**（`VoiceDropShare/`）：`ShareViewController`(UIHostingController 入口)、`ShareRouter`(@MainActor,类型分派+loadPayload)、`ShareRootView`、`ShareExtraction`、`ShareAPI`(上传/语料/提取/mine 客户端,复用 `Networking.swift` 的 `API.filesBase/agentBase`/`setBearer`/`isOK`)、三个 sheet。`RecordingName.swift` 已加入扩展 target。
- **服务端**：语料 `POST style/collect`·`GET style/dataset`·`DELETE style/dataset`（Pages,见上）；**`POST /agent/style/extract`** `{clearAfter}`（agent worker,`agent/src/style-extract.js` 蒸馏,读 `style/*.json`→Claude→`writeStyleDoc` 新版本,`clearAfter` 删语料,best-effort 扣算力,401/400 空数据集,语料总量 48000 字上限防 500;**2026-07-02 起降为 fallback**,主路径改走下面的挖矿任务流)；miner `mineOneAudio` 的「无语音+有照片→vision」（图片-only 用短提示词,不追加 `PHOTO_INSTR` 的口述话术）。
- **文风蒸馏 = 一次调用（`agent/src/style-extract.js`，2026-07-02 从两步合回一次）**：`DISTILL_SYSTEM` = `wjs-distilling-style` 的 **Prompt B** + `# 输出格式` 要求 `风格名：<≤5 字>` 作首行，一把出「名字+Style Card」；`splitNameAndCard` 用正则 `/^\s*风格名\s*[:：]\s*(.+)$/` 抠名字拼到风格文本**第一行**（iOS 版本名 + intro 标题都取第一行）。**为什么合成一次**：原来大 prompt 把「样本少于 3 篇」提醒顶到第一行，改用 marker+正则一次调用就够，省一次 Claude。
- **提取风格 = 挖矿任务流（2026-07-02 重构，去掉 sidecar，类型 tag 放文件名）**：客户端上传静音占位 `.m4a`，文件名尾 token 打 `TaskStyleExtract`（`clearAfter` 时不带 `Keep`）→ `triggerMine`。服务端 `classifyKey`→`"task"`，`runMine` 像扫 audio/style 一样扫出 → `mineOneAudio` 里 `taskSpec(key)`（读文件名尾 token → `{type,clearAfter}`）分派到 `TASK_HANDLERS["style-extract"]=mineStyleExtract`：`notifyStatus mining`→读 `style/*.json` 语料→`distillStyle`→`writeStyleDoc CLAUDE.json` 新版本→`buildStyleIntroArticle` 写成**该占位音频自己的** `articles/<stem>.json`（列表里像普通录音 待处理→处理中→已成文；**介绍文章正文列出这次蒸馏用到的素材清单**——每份「标题 — 来源」，标题缺失退回来源/文件名，`buildStyleIntroArticle(style, samples)` 收数组，2026-07-02 加）→`notifyStatus ready`→`clearAfter` 清 `style/`+`VoiceDrop-style-`→扣算力。空语料→写「风格数据集为空」文章。**类型 tag 就在文件名里，和 `VoiceDrop-style-`/`VoiceDrop-mine-` 同一机制，没有第二个文件**；以后新任务只加 `TASK_HANDLERS` 一项。**为什么不用原来的 `/agent/style/extract` 端点**：同步调用会让分享页空转等蒸馏、异步 `waitUntil` 又静默失败没进度；挖矿流稳、有进度、能重试、界面统一。
- **deeplink（`voicedrop://`，2026-07-01 新增）**：集中式 `VoiceDropApp/AppRouter.swift`（`DeepLink` enum + URL 解析），`VoiceDropApp` `onOpenURL→router.handle`，`LibraryView` `onReceive(router.$pending)` 应用（**切 tab + 清 push/settings/record 再落地**——老实现只设 tab，栈上 push 的详情没弹→落错页）。scheme 在 `project.yml` `CFBundleURLTypes`。地址：`voicedrop://` + `recordings`/`community`/`settings`/`record`/`article/<stem>`。
- **⚠️ Share Extension 不呼起主 app（2026-07-02 定论，`99da3bf` 删除跳转逻辑）**：iOS 不让分享扩展可靠呼起宿主 app——`NSExtensionContext.open` 官方只对 Today/widget 扩展生效，`openURL:`/`sharedApplication` selector walk 是私有 API 路径（真机没跳 + 有审核风险）。**试过 `ctx.open`（无效）和 responder-chain selector（真机仍没跳）后，`ShareViewController` 删掉全部呼起尝试**，分享/提取完成后直接 `completeRequest` 关闭分享页；任务在后台挖矿，用户自行开 app 看「我的录音」。`didFinish` 幂等防二次 completeRequest。app 侧 `voicedrop://` scheme/AppRouter/onOpenURL **保留未动**（标准 URL scheme，非审核风险，可留作内部深链）。**别再尝试从分享扩展自动呼起主 app**。
- **规格/计划**：`docs/superpowers/specs/2026-07-01-voicedrop-share-receive-design.md` + `docs/superpowers/plans/2026-07-01-voicedrop-share-receive.md`；设计 `design_handoff_share_collect/Share Collect.dc.html`。测试：`agent/test/{mine-image,style-corpus,style-extract,style-extract-route,share-routing}.test.js`（`share-routing` 含 `classifyKey`/`taskSpec` 用例；`mine-image` 含 style-extract 任务用例；全套 384 绿）。
- ✅ **静音片→干净空 已真机/线上验证**：给 3 个孤儿照片 session 补静音 `.m4a`+触发挖矿 → 全部 vision 挖成图文（火山对 960 字节静音片返回**干净空**、走 `if(!transcript)` vision 分支，不是 `AsrError`）。假设成立，图片路径放心。
- **部署状态（SHIPPED 2026-07-01，2026-07-02 重构提取风格为任务流）**：两个 `feat/share-collect` 已合并 main。Worker 多次 `wrangler deploy`（含 vision 挖图 / 语料接口 / 一次起名 / **提取风格挖矿任务流 `taskSpec`+`TASK_HANDLERS`**，最新版 live，jianshuo.dev `8f0ceb2`）。Pages 已部署生产（**注意坑 2：必须 `--branch main`，游离 HEAD 会静默进 preview**）。iOS 提取风格改文件名 tag（`5d72482`）走 TestFlight 构建中。
  - **⚠️ git 坑（2026-07-02）**：`~/code/jianshuo.dev` 工作目录当时停在 `feat/paint-service`（并行 paint 会话），直接 commit 会落错分支。做法：临时 `git worktree add` 一个 `main` worktree，改代码 / 跑测试 / `wrangler deploy` 全在里面，`git push origin main` 后再删 worktree——不碰 paint 会话。worktree 无 `node_modules`，`better-sqlite3` 是原生模块、软链会失败，得在 worktree 里真跑一次 `npm install`。

## 语音指令 (Voice Command) — 长按红键对文章库下语音指令（2026-07-02，SDD 建成，待真机验证）

「我的录音」首页**长按底部红键** → 列表每篇浮圈序号 → 说一句自然语言指令（「把③和④合并」「删掉第②篇」「把①换个更口语的标题」「②③④换风格重写」「这几篇归到『上海』」）→ Claude 理解意图并对文章库执行。规格/计划：`docs/superpowers/specs/2026-07-02-voicedrop-voice-command-design.md` + `docs/superpowers/plans/2026-07-02-voicedrop-voice-command.md`。

- **复用语音编辑栈**：`SpeechDictation` + `/agent/asr` 火山代理 + `runAgentLoop` + `ArticleQueue` + 反馈气泡 原样复用；抽出共享 `PushToTalkBar`（`VoiceDropApp/PushToTalkBar.swift`，从 `RecordingDetailView` 抽）+ `VoiceAgentSession` 协议（`ArticleAgentSession` 与新 `LibraryCommandSession` 都 conform）。
- **服务端（jianshuo.dev，已 live）**：新 `/agent/command` WS → **`LibraryAgent` DO（每用户一个**，区别于 `ArticleEditor` 每文章一个；wrangler migration **v5**）→ `runCommandTurn`（`src/command-turn.js`，编号 refs→stem + 命令工具子集 `toolDefsFor(COMMAND_TOOL_NAMES)`）→ 库级工具（`src/tools.js`）：`merge_articles`（Claude 揉成新一篇、**另存+留原文**、写静音 `.m4a` 锚点才进列表）、`delete_article`（**破坏性→暂存 pending，不在 loop 内删**）、`restyle_article`、`tag_article` + 复用 `list/read_article`、`read/write_style`。计费 `meteredCommandGate`（余额门，无每篇上限，reason `"command"`）。
- **分级确认**：合并留原文=非破坏→直接执行；唯一破坏性=删除→ DO 发 `{type:"confirm"}`、客户端 `.alert` 确认 → `{type:"confirm",id}` 才真删（`deleteArticleFiles`）。**关键不变量**：暂存的破坏性动作在 `ArticleQueue._runRow` 里靠 `res._pending` **视为未完成**（不 markDone、不广播 updated/reply），否则会在确认前误报「已完成」并孤立 pending。
- **编号→stem 防错位**：客户端把当前所见有序清单 `refs:[{n,stem,title}]` 随指令发，agent 按 refs 映射「第N篇」，不让服务端另排。
- **计费 = Claude tool-use agent**，deploy：jianshuo.dev main（Phase1 T1–T9），Worker version `4dfe42fd`（含 LibraryAgent）。412+ 测试绿（`command-tools`/`command-turn`/`usage-command`/`queue` `_pending`/`share-routing`）。
- **⚠️ 交互待真机调优（#1）**：当前是「长按红键进命令态 → 再按住 `PushToTalkBar` 说话」两次触摸，不是 Q2 定的单次连续对讲机（跨视图两个手势识别器无法共享一次触摸）。真机体验后决定要不要把红键本身做成 `LongPressGesture.sequenced(before: DragGesture)` 的一次性握持。
- **范围外/后续**：两套 agent（ArticleEditor / LibraryAgent）**本期并存**，完全统一（单 `/agent` + scope 参数）留后续；`publish_wechat`/`share_to_community` 因单篇绑定 `ctx.articleKey`、库级无 stem，**已从命令集移除**（详情页仍可发/分享），要语音发布需 v2 给这俩加 stem 参数；命令态列表按住时不滚（引用可见项）。
- **功能级 WS 冒烟**：服务端连通已验（`/agent/command` 返 426），端到端 merge/delete 冒烟推迟到真机（需真 WS 握手+token）。

## Known issues / TODO

- A few pre-fix recordings may carry garbage/empty article JSONs from old buggy miner runs; the Gianyar one was re-mined clean. Could sweep R2 for stragglers.
- App's title cache is in-memory; a re-mine done outside the app won't refresh the row title until app restart.

## Credentials (local)

`~/code/.env`: `FILES_TOKEN`, `VOLC_ASR_*` / `VOLC_TTS_*`, `CLAUDE_API_KEY`,
`ASC_API_KEY_ID` / `ASC_API_ISSUER_ID` / `ASC_API_KEY_CONTENT`. ASC app id `6781565141`.
