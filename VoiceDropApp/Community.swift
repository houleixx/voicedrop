import SwiftUI
import UIKit
import Observation

/// One community post as listed (metadata only).
struct CommunityPost: Decodable, Identifiable, Hashable {
    let shareId: String
    let author: String?
    let title: String?
    let firstSharedAt: Double?      // ms epoch
    let updatedAt: Double?
    let count: Int?
    let mine: Bool?                 // owned by the current user (can un-share)
    let replyTo: String?            // shareId this post is replying to, if any
    // 瀑布流卡片素材（community/list 服务端补齐，旧响应缺省为 nil → 文字卡兜底）。
    var hasPhoto: Bool? = nil       // 正文含 [[photo:…]] 标记
    var coverPhotoKey: String? = nil // 第一张图完整 R2 key（owner 已拼），走公开 /photo/<key>
    var preview: String? = nil      // 正文前 ~60 字纯文本（无标记无 markdown）
    var id: String { shareId }
}

/// The full shared snapshot (title + articles), read-only.
struct CommunityFullPost: Decodable {
    let shareId: String
    let author: String?
    let title: String?
    let articles: [MinedArticle]?
    let firstSharedAt: Double?
    let replyTo: String?
    let owner: String?          // the photos' "users/<sub>/" prefix → build full photo keys
    let photos: [String]?       // legacy [[photo:N]] resolution; nil for new posts
}

/// 一篇分享的投币状态（/agent/feed/state 的条目）。
struct FeedState: Decodable {
    var count: Int
    var fed: Bool
}

/// POST /agent/feed 的响应（成功与业务错误共用一个壳）。
struct FeedResult: Decodable {
    let ok: Bool?
    let already: Bool?
    let error: String?
    struct Suanli: Decodable { let author: Double; let feeder: Double }
    let suanli: Suanli?
}

@MainActor
@Observable
final class CommunityStore {
    var posts: [CommunityPost] = []
    /// 服务端原始返回顺序（纯 firstSharedAt 时间序）——「最新」tab 直接用这份，
    /// 不经 reco；posts 则会被 applyRanking 重排成「推荐」顺序。
    var timeOrdered: [CommunityPost] = []
    var loading = false
    var error: String?

    private let base = API.filesBase
    private let recoBase = API.recoBase
    private var token: String { AuthStore.shared.bearer }

    /// Community WRITES (share / unshare) need an Apple-verified identity — the server
    /// 403s a bare anon token. Send the session JWT when present; a missing one yields a
    /// 403 the caller catches to trigger Sign in with Apple, then retries. Everything
    /// else (incl. reco engage/rank, uploads, lists) uses `token` = the anon default.
    private var shareToken: String { AuthStore.shared.session ?? token }

    /// shareIds the current user has liked — filled by `applyRanking()`, seeds the ❤️ state.
    var likedShareIds: Set<String> = []

    /// 每帖被赞总数（shareId → n）——rank 响应顺路下发，瀑布流卡片的红心数。
    var likeCounts: [String: Int] = [:]

    /// 投币点亮态：shareId → (count, fed)。由 loadFeedStates() 批量填充。
    var feedStates: [String: FeedState] = [:]
    /// 每帖收到的回应数（shareId → 数量）。load() 里从 posts 的 replyTo 汇总，
    /// 瀑布流卡片的回应数直接读这里（原来是 applyRanking 的局部变量）。
    var replyCounts: [String: Int] = [:]
    /// 当前币价（算力/币），随 feed/state 响应更新，展示用。
    var coinPrice: Double = 0

    /// All shared posts, newest-first by first-share time.
    /// 2026-07-14 起首选 /reco/feed（D1 展示索引）：列表 + 推荐序 + 红心 + 回应数 +
    /// 我赞过的一次带回（老路径的 list+rank 两步、每帖 2 次 R2 读全省了）。
    /// feed 不可用（reco 挂了 / 索引空）→ 回退 R2 真源老路径，社区永远有的看。
    func load() async {
        guard !token.isEmpty else { return }
        loading = true; error = nil
        defer { loading = false }
        if await loadViaFeed() { return }
        await loadViaListAndRank()
    }

    /// /reco/feed 的行：CommunityPost 的字段 + 每帖互动数。
    private struct FeedRow: Decodable {
        let shareId: String; let author: String?; let title: String?
        let preview: String?; let coverPhotoKey: String?; let hasPhoto: Bool?
        let count: Int?; let firstSharedAt: Double?; let updatedAt: Double?
        let replyTo: String?; let mine: Bool?
        let likes: Int?; let replies: Int?; let liked: Bool?
    }

    private func loadViaFeed() async -> Bool {
        var req = URLRequest(url: recoBase.appending(path: "feed"))
        req.timeoutInterval = 5
        req.setBearer(token)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard resp.isOK else { return false }
            struct R: Decodable { let posts: [FeedRow]; let order: [String] }
            let r = try JSONDecoder().decode(R.self, from: data)
            let rows = r.posts.filter { !BlockStore.isBlocked($0.author) }   // local block list (Apple 1.2)
            guard !rows.isEmpty else { return false }   // 索引空（未回填/漂移）→ 老路径兜底
            let mapped = rows.map { row in
                CommunityPost(shareId: row.shareId, author: row.author, title: row.title,
                              firstSharedAt: row.firstSharedAt, updatedAt: row.updatedAt,
                              count: row.count, mine: row.mine, replyTo: row.replyTo,
                              hasPhoto: row.hasPhoto, coverPhotoKey: row.coverPhotoKey,
                              preview: row.preview)
            }
            timeOrdered = mapped                        // feed 本身就是时间倒序
            let byId = Dictionary(uniqueKeysWithValues: mapped.map { ($0.shareId, $0) })
            let reordered = r.order.compactMap { byId[$0] }
            posts = reordered.count == mapped.count ? reordered : mapped
            likeCounts = rows.reduce(into: [:]) { $0[$1.shareId] = $1.likes ?? 0 }
            replyCounts = rows.reduce(into: [:]) { if let n = $1.replies, n > 0 { $0[$1.shareId] = n } }
            likedShareIds = Set(rows.filter { $0.liked == true }.map(\.shareId))
            return true
        } catch { return false }
    }

    /// 老路径（R2 真源 community/list + /reco/rank），feed 兜底与老服务端兼容。
    private func loadViaListAndRank() async {
        var req = URLRequest(url: base.appending(path: "community").appending(path: "list"))
        req.setBearer(token)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard resp.isOK else { error = String(localized: "加载失败"); return }
            struct R: Decodable { let posts: [CommunityPost] }
            posts = try JSONDecoder().decode(R.self, from: data).posts
                .filter { !BlockStore.isBlocked($0.author) }   // local block list (Apple 1.2)
            timeOrdered = posts                                // 服务端时间序快照（reco 重排前）
            replyCounts = posts.reduce(into: [String: Int]()) { acc, p in
                if let to = p.replyTo { acc[to, default: 0] += 1 }
            }
            await applyRanking()
        } catch { self.error = error.localizedDescription }
    }

    /// Ask reco how to order the feed; on success reorder `posts` and record what I liked.
    /// On failure/timeout keep the time-sort — the feed always shows.
    private func applyRanking() async {
        guard !posts.isEmpty, !token.isEmpty else { return }
        let payload = posts.map { p -> [String: Any] in
            ["shareId": p.shareId,
             "firstSharedAt": p.firstSharedAt ?? 0,
             "author": p.author ?? "",
             "replyCount": replyCounts[p.shareId] ?? 0]
        }
        var req = URLRequest(url: recoBase.appending(path: "rank"))
        req.httpMethod = "POST"
        req.timeoutInterval = 2   // timeout → fall back to time-sort
        req.setBearer(token)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["posts": payload])
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard resp.isOK else { return }
            struct R: Decodable { let order: [String]; let liked: [String]; let likes: [String: Int]? }
            let r = try JSONDecoder().decode(R.self, from: data)
            likedShareIds = Set(r.liked)
            likeCounts = r.likes ?? [:]
            let byId = Dictionary(uniqueKeysWithValues: posts.map { ($0.shareId, $0) })
            let reordered = r.order.compactMap { byId[$0] }
            if reordered.count == posts.count { posts = reordered }  // replace only on full coverage
        } catch { /* fall back: keep time-sort */ }
    }

    /// Share (or re-share) one of the user's articles. Returns shareId on success, nil on failure.
    /// `replyTo` links this post to another post's shareId.
    func share(_ rec: Recording, replyTo: String? = nil) async -> String? {
        guard !token.isEmpty, rec.hasArticles else { return nil }
        return await withAppleRetry({ await postShare(rec, replyTo: replyTo) }, isSuccess: { $0 != nil })
    }

    /// Returns shareId if this recording is currently shared to the community, nil otherwise.
    func sharedShareId(_ rec: Recording) async -> String? {
        guard !token.isEmpty, rec.hasArticles else { return nil }
        var req = URLRequest(url: base.appending(path: "community").appending(path: "shared").appending(path: rec.articleKey))
        req.setBearer(token)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard resp.isOK else { return nil }
            struct R: Decodable { let shared: Bool; let shareId: String? }
            let r = try? JSONDecoder().decode(R.self, from: data)
            return r?.shared == true ? r?.shareId : nil
        } catch { return nil }
    }

    private var needsAppleSignIn = false

    /// Set `needsAppleSignIn` from a gated 403 — the ONE place that knows the
    /// `needs_apple_signin` contract (was inlined in postShare + postUnshare).
    private func markNeedsAppleSignin(code: Int, data: Data) {
        needsAppleSignIn = code == 403 &&
            (try? JSONDecoder().decode([String: String].self, from: data))?["error"] == "needs_apple_signin"
    }

    /// Run a community write once; if it failed with a gated 403, prompt Apple
    /// sign-in and retry exactly once. The single share/unshare retry handshake.
    private func withAppleRetry<T>(_ op: () async -> T, isSuccess: (T) -> Bool) async -> T {
        needsAppleSignIn = false
        let first = await op()
        guard !isSuccess(first), needsAppleSignIn else { return first }
        await AuthStore.shared.signInWithApple()
        guard AuthStore.shared.isAuthenticated else { return first }
        return await op()
    }

    private func postShare(_ rec: Recording, replyTo: String?) async -> String? {
        var req = URLRequest(url: base.appending(path: "community").appending(path: "share").appending(path: rec.articleKey))
        req.httpMethod = "POST"
        req.setBearer(shareToken)
        if let replyTo {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONEncoder().encode(["replyTo": replyTo])
        }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = resp.httpStatusCode
            if (200..<300).contains(code) {
                needsAppleSignIn = false
                struct R: Decodable { let shareId: String? }
                return (try? JSONDecoder().decode(R.self, from: data))?.shareId
            }
            markNeedsAppleSignin(code: code, data: data)
            return nil
        } catch { return nil }
    }

    @discardableResult
    func unshare(_ shareId: String) async -> Bool {
        guard !token.isEmpty else { return false }
        posts.removeAll { $0.shareId == shareId }                 // optimistic
        let ok = await withAppleRetry({ await postUnshare(shareId) }, isSuccess: { $0 })
        if !ok { await load() }                                   // failed → resync the optimistic removal
        return ok
    }

    private func postUnshare(_ shareId: String) async -> Bool {
        var req = URLRequest(url: base.appending(path: "community").appending(path: "unshare").appending(path: shareId))
        req.httpMethod = "POST"
        req.setBearer(shareToken)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = resp.httpStatusCode
            if (200..<300).contains(code) { needsAppleSignIn = false; return true }
            markNeedsAppleSignin(code: code, data: data)
            return false
        } catch { return false }
    }

    func isShared(_ rec: Recording) async -> Bool {
        guard !token.isEmpty, rec.hasArticles else { return false }
        var req = URLRequest(url: base.appending(path: "community").appending(path: "shared").appending(path: rec.articleKey))
        req.setBearer(token)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard resp.isOK else { return false }
            struct R: Decodable { let shared: Bool }
            return (try? JSONDecoder().decode(R.self, from: data))?.shared ?? false
        } catch { return false }
    }

    func fetchPost(_ shareId: String) async -> CommunityFullPost? {
        guard !token.isEmpty else { return nil }
        var req = URLRequest(url: base.appending(path: "community").appending(path: "get").appending(path: shareId))
        req.setBearer(token)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard resp.isOK else { return nil }
            return try JSONDecoder().decode(CommunityFullPost.self, from: data)
        } catch { return nil }
    }

    /// Download + decode a photo by its full R2 key (`users/<sub>/photos/…`) via the
    /// public `/photo/<key>` endpoint — no auth, the same URL the web pages use. One
    /// photo logic everywhere (incl. the shared in-process image cache).
    func photoImage(fullKey: String, preferThumb: Bool = false) async -> UIImage? {
        await PhotoService.image(fullKey: fullKey, preferThumb: preferThumb)
    }

    // MARK: 投币（互助扩散：作者 2 币、投币者 0.5 币，即时换算力到账）

    /// 批量拉取投币状态（详情页进入时）。匿名 token 也可查（同一用户 anon/Apple scope 一致）。
    func loadFeedStates(_ shareIds: [String]) async {
        guard !token.isEmpty, !shareIds.isEmpty else { return }
        var req = URLRequest(url: API.agentBase.appending(path: "feed/state"))
        req.httpMethod = "POST"
        req.timeoutInterval = 3
        req.setBearer(token)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["share_ids": shareIds])
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard resp.isOK else { return }
            struct R: Decodable { let states: [String: FeedState]; let price_suanli_per_coin: Double? }
            let r = try JSONDecoder().decode(R.self, from: data)
            feedStates.merge(r.states) { _, new in new }
            if let p = r.price_suanli_per_coin { coinPrice = p }
        } catch { /* 状态查不到就保持未点亮，投币接口自身兜底幂等 */ }
    }

    /// 投币。服务端一人一篇只能一次（唯一键幂等）；需 Apple 实名 —— 匿名 403 时
    /// 复用 share 的 withAppleRetry 握手：弹 Apple 登录成功后自动重试一次。
    func feed(_ shareId: String) async -> FeedResult? {
        guard !token.isEmpty else { return nil }
        let r = await withAppleRetry({ await postFeed(shareId) },
                                     isSuccess: { $0?.ok == true || $0?.already == true })
        if r?.ok == true || r?.already == true {
            var s = feedStates[shareId] ?? FeedState(count: 0, fed: false)
            if !s.fed && r?.already != true { s.count += 1 }
            s.fed = true
            feedStates[shareId] = s
        }
        return r
    }

    private func postFeed(_ shareId: String) async -> FeedResult? {
        var req = URLRequest(url: API.agentBase.appending(path: "feed"))
        req.httpMethod = "POST"
        req.timeoutInterval = 8
        req.setBearer(shareToken)   // 投币要实名：session JWT 优先，缺了服务端 403 触发登录
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["share_id": shareId])
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = resp.httpStatusCode
            let r = try? JSONDecoder().decode(FeedResult.self, from: data)
            if (200..<300).contains(code) { needsAppleSignIn = false; return r }
            markNeedsAppleSignin(code: code, data: data)
            return r
        } catch { return nil }
    }

    /// Report one engagement. Failures are silently ignored — when reco is down the
    /// core experience is unaffected.
    func engage(_ shareId: String, action: String, on: Bool? = nil) async {
        guard !token.isEmpty else { return }
        var req = URLRequest(url: recoBase.appending(path: "engage").appending(path: shareId))
        req.httpMethod = "POST"
        req.timeoutInterval = 3
        req.setBearer(token)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["action": action]
        if let on { body["on"] = on }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: req)
    }

    /// Report a post for objectionable content (Apple 1.2). The server HIDES it from
    /// the community immediately (pending owner review); we also drop it from the local
    /// feed right away so the reporter never sees it again.
    @discardableResult
    func report(_ shareId: String, reason: String = "") async -> Bool {
        guard !token.isEmpty else { return false }
        posts.removeAll { $0.shareId == shareId }
        var req = URLRequest(url: base.appending(path: "community").appending(path: "report").appending(path: shareId))
        req.httpMethod = "POST"
        req.timeoutInterval = 5
        req.setBearer(token)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["reason": reason])
        do { let (_, resp) = try await URLSession.shared.data(for: req); return resp.isOK }
        catch { return false }
    }

    /// Posts that are responses to `shareId`, oldest-first.
    func loadReplies(_ shareId: String) async -> [CommunityPost] {
        guard !token.isEmpty else { return [] }
        var req = URLRequest(url: base.appending(path: "community").appending(path: "replies").appending(path: shareId))
        req.setBearer(token)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard resp.isOK else { return [] }
            struct R: Decodable { let posts: [CommunityPost] }
            return (try? JSONDecoder().decode(R.self, from: data))?.posts ?? []
        } catch { return [] }
    }
}

/// Format a ms-epoch time as "6月22日" (or include year if not this year).
func communityDate(_ ms: Double?) -> String {
    guard let ms else { return "" }
    let date = Date(timeIntervalSince1970: ms / 1000)
    let fmt = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year) ? "M月d日" : "yyyy年M月d日"
    return DateFormatter.zh(fmt).string(from: date)
}

// MARK: - Community post view

struct CommunityPostView: View {
    let store: CommunityStore
    let post: CommunityPost
    /// Called after the user finishes recording a response (trigger library refresh + upload).
    var onRecordFinished: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss

    @State private var full: CommunityFullPost?
    @State private var loading = true
    @State private var articleIndex = 0
    @State private var replies: [CommunityPost] = []
    @State private var replyPreviews: [String: String] = [:]   // shareId → 2-line body preview (设计稿 1d 卡片)
    @State private var selectedReply: CommunityPost?
    @State private var replyToFull: CommunityFullPost?   // the post this article responds to
    @State private var selectedOriginal: CommunityPost?  // navigate to original post
    @State private var sharePayload: SharePayload?
    @State private var toast: String?
    @State private var liked = false
    @State private var feeding = false      // 投币请求在途，防连点
    @State private var finishedReported = false
    @State private var showReportConfirm = false
    @State private var showBlockConfirm = false

    // Recording a response
    @State private var recorder = AudioRecorder()
    @State private var location = LocationTagger()
    @State private var recorderPhase: RecorderPhase = .idle
    @State private var pulse = false

    enum RecorderPhase { case idle, recording }

    private var articles: [MinedArticle] { full?.articles ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            navBar
            if loading {
                Spacer(); ProgressView().tint(Theme.accent); Spacer()
            } else if articles.isEmpty {
                Spacer()
                Text("这篇分享已不可用").foregroundStyle(Theme.secondary).font(.system(size: 15))
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if let a = articles[safe: articleIndex] {
                            Text(a.title)
                                .font(.system(size: 23, weight: .semibold)).foregroundStyle(Theme.inkRead)
                                .lineSpacing(5).fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 18)
                            HStack(spacing: 8) {
                                Text(full?.author ?? String(localized: "匿名")).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.accent)
                                Text(communityDate(full?.firstSharedAt)).font(.system(size: 13)).foregroundStyle(Theme.metaRead)
                            }
                            .padding(.top, 8)
                            if let orig = replyToFull { replyToChip(orig).padding(.top, 10) }
                            if articles.count > 1 { chipRow.padding(.top, 16) }
                            communityBody(a).padding(.top, articles.count > 1 ? 16 : 20)
                        }
                        repliesSection
                        Color.clear.frame(height: 1)
                            .onAppear {
                                guard !finishedReported else { return }
                                finishedReported = true
                                Task { await store.engage(post.shareId, action: "finish") }
                            }
                    }
                    .padding(.horizontal, 20)
                }
                .contentMargins(.bottom, recorderPhase == .recording ? 76 : 20, for: .scrollContent)
                .animation(.easeInOut(duration: 0.2), value: recorderPhase)
            }
        }
        .background(Theme.readBG.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .bottom) { if recorderPhase == .recording { recordingBar } }
        .overlay(alignment: .bottom) { toastView }
        .navigationDestination(item: $selectedReply) { reply in
            CommunityPostView(store: store, post: reply, onRecordFinished: onRecordFinished)
        }
        .navigationDestination(item: $selectedOriginal) { orig in
            CommunityPostView(store: store, post: orig, onRecordFinished: onRecordFinished)
        }
        .sheet(item: $sharePayload) { ShareSheet(items: $0.activityItems) }
        .confirmationDialog("举报这篇分享？", isPresented: $showReportConfirm, titleVisibility: .visible) {
            Button("举报并下架", role: .destructive) {
                // 举报立即让它从社区下架（待人工审核），并从本地列表移除。
                Task { await store.report(post.shareId) }
                showToast(String(localized: "已举报，内容已下架待审核"))
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { dismiss() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("举报后这篇会立即从社区下架，并在 24 小时内由人工审核处理。")
        }
        .confirmationDialog("屏蔽此用户？", isPresented: $showBlockConfirm, titleVisibility: .visible) {
            Button("屏蔽", role: .destructive) {
                BlockStore.block(full?.author ?? post.author)
                store.posts.removeAll { ($0.author ?? "") == (full?.author ?? post.author ?? "") }
                showToast(String(localized: "已屏蔽，TA 的内容将不再显示"))
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { dismiss() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("屏蔽后，你将不再看到 \(full?.author ?? post.author ?? String(localized: "该用户")) 的任何社区内容。可在「设置」里取消屏蔽。")
        }
        .task {
            liked = store.likedShareIds.contains(post.shareId)
            Task { await store.loadFeedStates([post.shareId]) }
            await store.engage(post.shareId, action: "view")
            full = await store.fetchPost(post.shareId)
            loading = false
            async let repliesTask = store.loadReplies(post.shareId)
            if let replyToId = full?.replyTo ?? post.replyTo {
                replyToFull = await store.fetchPost(replyToId)
            }
            replies = await repliesTask
            await loadReplyPreviews()
        }
        .onDisappear { _ = recorder.stop() }
    }

    // MARK: Nav bar (⋯ menu)

    private var navBar: some View {
        // spacing 0：投喂/点赞是 38pt 热区里的 18pt 图标（自带 ~10pt 视觉留白），
        // 相邻即得 ~20pt 视觉间隙；⋯ 是实心 38pt 方块（无留白），补 10pt 左边距
        // 凑成同样的 ~20pt——否则点赞看起来左松右挤。
        HStack(spacing: 0) {
            NavSquare(systemName: "chevron.left", stroke: Theme.inkRead, border: Theme.borderRead) { dismiss() }
                .accessibilityLabel("返回")
            Spacer()
            feedButton
            Button {
                liked.toggle()
                // Keep the store's liked-set in sync so re-entering this view (which seeds
                // `liked` from `store.likedShareIds`) reflects the tap without a list refresh.
                if liked { store.likedShareIds.insert(post.shareId) }
                else { store.likedShareIds.remove(post.shareId) }
                Task { await store.engage(post.shareId, action: "like", on: liked) }
            } label: {
                Image(systemName: liked ? "heart.fill" : "heart")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(liked ? Theme.accent : Theme.inkRead)
                    .frame(width: 38, height: 38)
            }
            .accessibilityLabel(liked ? String(localized: "取消赞") : String(localized: "赞"))
            Menu {
                Button { Task { await startResponse() } } label: {
                    Label("写回应", systemImage: "mic")
                }
                Button { Task { await sharePost() } } label: {
                    Label("分享", systemImage: "square.and.arrow.up")
                }
                Button(role: .destructive) { showReportConfirm = true } label: {
                    Label("举报", systemImage: "flag")
                }
                Button(role: .destructive) { showBlockConfirm = true } label: {
                    Label("屏蔽此用户", systemImage: "hand.raised")
                }
            } label: {
                RoundedRectangle(cornerRadius: Theme.R.nav)
                    .fill(Theme.ink)
                    .frame(width: 38, height: 38)
                    .overlay {
                        Image(systemName: "ellipsis").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                    }
                    .navButtonShadow()
            }
            .padding(.leading, 10)
            .accessibilityLabel("更多")
        }
        .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 8)
    }

    // MARK: 投币（赞旁边：给作者 2 币、自己 0.5 币，按当前币价即时换算力到账）

    private var fedState: FeedState? { store.feedStates[post.shareId] }

    private var feedButton: some View {
        let fed = fedState?.fed ?? false
        let gold = Color(red: 0.93, green: 0.65, blue: 0.10)
        return Button {
            guard !fed, !feeding else { return }
            feeding = true
            Task {
                let r = await store.feed(post.shareId)
                feeding = false
                if r?.ok == true, r?.already != true, let s = r?.suanli {
                    showToast(String(localized: "已投币：你 +\(suanliText(s.feeder))，作者 +\(suanliText(s.author)) 算力"))
                } else if r?.already == true {
                    showToast(String(localized: "已经投过这篇了"))
                } else if r?.error == "cannot_feed_own" {
                    showToast(String(localized: "不能给自己的文章投币"))
                } else if r?.error == "pool_exhausted" {
                    showToast(String(localized: "今日算力池已发完，明天再来"))
                } else if r?.error == "needs_apple_signin" {
                    showToast(String(localized: "投币需要先用 Apple 登录"))
                } else {
                    showToast(String(localized: "投币失败，稍后再试"))
                }
            }
        } label: {
            Image(systemName: fed ? "bolt.circle.fill" : "bolt.circle")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(fed ? gold : Theme.inkRead)
                .frame(width: 38, height: 38)
                .opacity(feeding ? 0.4 : 1)
        }
        .disabled(fed || feeding)
        .accessibilityLabel(fed ? String(localized: "已投币") : String(localized: "投币"))
    }

    private func suanliText(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }

    // MARK: Article body (text + inline session photos)

    /// Render the body with `[[photo:…]]` markers turned into inline image tiles —
    /// the same scene photos the owner sees, fetched cross-user via the gated
    /// `community/photo` endpoint. (Previously the markers were stripped, so shared
    /// posts lost all their photos.)
    @ViewBuilder private func communityBody(_ a: MinedArticle) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(ArticleBody.segments(a.body)) { seg in
                switch seg {
                case .text(let t):
                    Text(textAttributed(t))
                        .font(.system(size: 16)).foregroundStyle(Theme.bodyRead)
                        .lineSpacing(9).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .photo(let token):
                    if let owner = full?.owner,
                       let relKey = ArticleBody.resolvePhotoKey(token, photos: full?.photos ?? []) {
                        CommunityPhotoTile(store: store, fullKey: owner + relKey)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func textAttributed(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible))) ?? AttributedString(s)
    }

    // MARK: Article chips

    private var chipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(articles.enumerated()), id: \.offset) { i, a in
                    Button { articleIndex = i } label: {
                        Text(a.title).lineLimit(1)
                            .font(.system(size: 13, weight: i == articleIndex ? .semibold : .regular))
                            .padding(.horizontal, 14).padding(.vertical, 6)
                            .background(i == articleIndex ? Theme.accentSoft : Theme.card,
                                        in: RoundedRectangle(cornerRadius: Theme.R.chip))
                            .overlay(RoundedRectangle(cornerRadius: Theme.R.chip)
                                .stroke(i == articleIndex ? .clear : Theme.borderRead, lineWidth: 1))
                            .foregroundStyle(i == articleIndex ? Theme.accent : Theme.metaRead)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Replies section

    private func replyToChip(_ orig: CommunityFullPost) -> some View {
        Button {
            let origPost = CommunityPost(shareId: orig.shareId, author: orig.author,
                                         title: orig.articles?.first?.title ?? orig.title,
                                         firstSharedAt: orig.firstSharedAt, updatedAt: nil,
                                         count: orig.articles?.count, mine: nil, replyTo: orig.replyTo)
            selectedOriginal = origPost
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.turn.up.left").font(.system(size: 11, weight: .medium))
                Text("回应").font(.system(size: 12, weight: .medium))
                Text((orig.articles?.first?.title ?? orig.title ?? orig.author) ?? String(localized: "原文"))
                    .font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                Image(systemName: "chevron.right").font(.system(size: 10))
            }
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Theme.accentSoft, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // 设计稿 Reply Display 1a「续文」：回应就是正文的续篇，同一张纸往下读——
    // 「N 篇回应」分隔线后，每篇回应带左侧细色条 + 作者行，正文直接展开接排；
    // 长文折叠（8 行），点「继续阅读 ↓」或整块进回应详情页。
    @ViewBuilder private var repliesSection: some View {
        if !replies.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Rectangle().fill(Color(hex: "DDD5C7")).frame(height: 1)
                    Text("\(replies.count) 篇回应")
                        .font(.system(size: 12, weight: .bold)).kerning(2)
                        .foregroundStyle(Color(hex: "A79F93"))
                        .layoutPriority(1)
                    Rectangle().fill(Color(hex: "DDD5C7")).frame(height: 1)
                }
                .padding(.top, 30)
                ForEach(replies) { reply in
                    Button { selectedReply = reply } label: { replyContinuation(reply) }
                        .buttonStyle(.plain)
                        .padding(.top, 26)
                }
            }
        }
    }

    private func replyContinuation(_ reply: CommunityPost) -> some View {
        let body = replyPreviews[reply.shareId] ?? ""
        return HStack(alignment: .top, spacing: 0) {
            RoundedRectangle(cornerRadius: 1.5).fill(Color(hex: "E8C7B8")).frame(width: 3)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(reply.author ?? String(localized: "匿名"))
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
                    Text("回应 · \(communityDate(reply.firstSharedAt))")
                        .font(.system(size: 12)).foregroundStyle(Color(hex: "9A9387"))
                }
                if let title = reply.title, !title.isEmpty {
                    Text(title)
                        .font(.system(size: 19, weight: .semibold)).foregroundStyle(Color(hex: "2B2823"))
                        .lineSpacing(5).fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                }
                if !body.isEmpty {
                    Text(body)
                        .font(.system(size: 16)).foregroundStyle(Theme.bodyRead)
                        .lineSpacing(8).lineLimit(8)
                        .padding(.top, 10)
                }
                if body.count > 160 {
                    Text("继续阅读 ↓")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
                        .padding(.top, 10)
                }
            }
            .padding(.leading, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Fetch each reply's full post once and distill a plain-text preview for its
    /// card (markdown/photo markers stripped). Concurrent, best-effort — a card
    /// without a preview just shows author + title.
    private func loadReplyPreviews() async {
        let pending = replies.filter { replyPreviews[$0.shareId] == nil }
        guard !pending.isEmpty else { return }
        let found = await withTaskGroup(of: (String, String).self) { group -> [(String, String)] in
            for r in pending {
                group.addTask {
                    let body = await store.fetchPost(r.shareId)?.articles?.first?.body ?? ""
                    return (r.shareId, Self.previewText(body))
                }
            }
            var out: [(String, String)] = []
            for await t in group { out.append(t) }
            return out
        }
        for (id, p) in found { replyPreviews[id] = p }
    }

    /// Plain-text continuation body: photo markers and markdown syntax out,
    /// whitespace collapsed. Clipped at ~600 chars — the view clamps to 8 lines,
    /// so this only bounds memory; >160 chars triggers the 继续阅读 affordance.
    nonisolated private static func previewText(_ body: String) -> String {
        var t = body.replacingOccurrences(of: #"\[\[photo:[^\]]+\]\]"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"[#>*`\-]+"#, with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(t.prefix(600))
    }

    // MARK: Recording bar (visible while recording a response)

    private var recordingBar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 6) {
                Circle().fill(Theme.recordRed).frame(width: 8, height: 8)
                    .opacity(pulse ? 1 : 0.35)
                    .animation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true), value: pulse)
                Text(timeString(recorder.elapsed))
                    .font(.system(size: 15, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.ink)
            }
            Spacer()
            miniWaveform
            Spacer()
            Button { Task { await stopResponse() } } label: {
                Circle().fill(Theme.card).frame(width: 48, height: 48)
                    .overlay(Circle().stroke(Color(hex: "E8DECF"), lineWidth: 1))
                    .overlay(RoundedRectangle(cornerRadius: 5).fill(Theme.recordRed).frame(width: 18, height: 18))
                    .shadow(color: .black.opacity(0.06), radius: 5, x: 0, y: 2)
            }
            .buttonStyle(.plain).accessibilityLabel("停止录音")
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .background(Theme.card)
        .overlay(Rectangle().fill(Theme.borderRead).frame(height: 1), alignment: .top)
        .onAppear { pulse = true }
        .onDisappear { pulse = false }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var miniWaveform: some View {
        let bars: [Double] = [0.30, 0.56, 0.82, 0.48, 0.95, 0.65, 0.38, 0.74, 0.52]
        return HStack(alignment: .bottom, spacing: 2) {
            ForEach(bars.indices, id: \.self) { i in
                let frac = bars[i] * (0.12 + recorder.level * 0.88)
                RoundedRectangle(cornerRadius: 2)
                    .fill(frac > 0.5 ? Theme.recordRed : Color(hex: "EBA89F"))
                    .frame(width: 3, height: max(3, 28 * frac))
            }
        }
        .frame(height: 28)
        .animation(.easeOut(duration: 0.1), value: recorder.level)
    }

    // MARK: Response recording flow

    private func startResponse() async {
        guard recorderPhase == .idle else { return }
        let granted = await AudioRecorder.ensurePermission()
        guard granted else { showToast(String(localized: "请在设置里开启麦克风权限")); return }
        location.start()
        do {
            try recorder.start()
            withAnimation { recorderPhase = .recording }
        } catch {
            showToast(String(localized: "无法开始录音"))
        }
    }

    private func stopResponse() async {
        guard let take = recorder.stop() else { withAnimation { recorderPhase = .idle }; return }
        withAnimation { recorderPhase = .idle }
        await promote(take)
        onRecordFinished?()
        dismiss()
    }

    private func promote(_ take: AudioRecorder.Recording) async {
        let finalURL = await RecordingPromoter.promote(take, place: await location.placeTag())
        // LibraryView.onChange picks this up when the article is mined and auto-shares with replyTo.
        UserDefaults.standard.set(post.shareId, forKey: "vd.pendingReply.\(finalURL.lastPathComponent)")
    }

    // MARK: Share this post

    /// Share this 社区 post EXACTLY like one of your own articles: hand WeChat the
    /// public `/voicedrop/<shareId>` link (the page resolves a community shareId too),
    /// so it builds a rich link card — first photo + description — from the page og tags.
    /// X / 其它 get the full text + inline link. Same `ArticleShareItem` as 我的录音.
    private func sharePost() async {
        let title = full?.articles?.first?.title ?? post.title ?? String(localized: "VoiceDrop 分享")
        let author = full?.author ?? post.author ?? String(localized: "匿名")
        // Full text (every section, markers stripped) — matches the article-list share.
        let arts = full?.articles ?? []
        let allText = arts.isEmpty
            ? String(localized: "《\(title)》— \(author)\n来自 VoiceDrop 社区")
            : ArticleBody.shareText(arts)
        guard var comps = URLComponents(url: API.sharePage(post.shareId), resolvingAgainstBaseURL: false) else {
            sharePayload = SharePayload(text: allText); return
        }
        comps.queryItems = [URLQueryItem(name: "s", value: String(articleIndex))]
        guard let url = comps.url else { sharePayload = SharePayload(text: allText); return }
        let image = await firstPhotoImage()                  // best-effort card thumbnail
        sharePayload = SharePayload(text: allText + "\n\n" + url.absoluteString,
                                    url: url, title: title, image: image)
    }

    /// First photo of the currently-shown article — the WeChat link-card thumbnail.
    /// Best-effort: nil when there's no photo or the fetch fails (then WeChat falls back
    /// to the page's og:image). Loads cross-user via the public `/photo/<key>` endpoint.
    private func firstPhotoImage() async -> UIImage? {
        guard let owner = full?.owner,
              let body = full?.articles?[safe: articleIndex]?.body,
              let relKey = ArticleBody.firstPhotoKey(in: body, photos: full?.photos ?? []) else { return nil }
        return await store.photoImage(fullKey: owner + relKey)
    }

    // MARK: Toast

    private func showToast(_ msg: String) {
        toast = msg
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if toast == msg { toast = nil }
        }
    }

    @ViewBuilder private var toastView: some View {
        if let toast {
            Text(toast)
                .font(.system(size: 15)).foregroundStyle(Theme.inkRead)
                .padding(.horizontal, 18).padding(.vertical, 12)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(Theme.borderRead, lineWidth: 1))
                .padding(.bottom, recorderPhase == .recording ? 90 : 32)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func timeString(_ t: TimeInterval) -> String { t.clockString }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// A square inline photo inside a community post, loaded from the public
/// `/photo/<fullKey>` endpoint — the same photo URL used by the web pages.
struct CommunityPhotoTile: View {
    let store: CommunityStore
    let fullKey: String          // "users/<sub>/photos/…/x.jpg"

    @State private var image: UIImage?

    var body: some View {
        // 占位态保持 1:1 正方形；图加载成功后壳子跟随图片真实宽高比（与详情页 PhotoTile 同规则）。
        RoundedRectangle(cornerRadius: 12)
            .fill(Theme.card)
            .aspectRatio(image.map { $0.size.width / max($0.size.height, 1) } ?? 1, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay {
                if let img = image {
                    Image(uiImage: img)
                        .resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    ProgressView().tint(Theme.accent)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .animation(.easeInOut(duration: 0.25), value: image != nil)
            // Bind to the key (not view identity) so a shifted marker re-fetches.
            .task(id: fullKey) {
                image = nil
                image = await store.photoImage(fullKey: fullKey)
            }
    }
}

// MARK: - 别人的分享：只读阅读页（universal link 原生落地）

/// GET /files/api/link/<id> 的响应——分享短链解析 + 正文。App 用 owner 判断
/// 是不是自己的文章；不是自己的、也不是社区帖时，正文就地喂给 SharedArticleView。
struct SharedArticle: Decodable {
    let type: String            // "article" | "community"
    let owner: String           // "users/<sub>/"（拼照片 full key 用）
    let stem: String
    let title: String?
    let articles: [MinedArticle]?
    let photos: [String]?       // legacy [[photo:N]] 解析用；新文章无此字段
}

/// 别人分享的文章（非社区帖）的只读阅读页——voicedrop.cn/<id> universal link
/// 指向他人文章时的原生落地。与 CommunityPostView 同一套阅读排版（标题/章节
/// chips/正文段落/内嵌照片），但没有任何社区动作（投币/回应/举报都不适用）。
struct SharedArticleView: View {
    let store: CommunityStore      // 只用它取照片（公共 photo 端点）
    let shared: SharedArticle
    @State var articleIndex: Int   // 初值 = 分享链接的 ?s=<i>（分享者当时选中的那篇）

    @Environment(\.dismiss) private var dismiss
    private var articles: [MinedArticle] { shared.articles ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                NavSquare(systemName: "chevron.left", stroke: Theme.inkRead, border: Theme.borderRead) { dismiss() }
                    .accessibilityLabel("返回")
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            if articles.isEmpty {
                Spacer()
                Text("这篇分享已不可用").foregroundStyle(Theme.secondary).font(.system(size: 15))
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if let a = articles[safe: articleIndex] {
                            Text(a.title)
                                .font(.system(size: 23, weight: .semibold)).foregroundStyle(Theme.inkRead)
                                .lineSpacing(5).fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 10)
                            if articles.count > 1 { chipRow.padding(.top, 16) }
                            articleBody(a).padding(.top, articles.count > 1 ? 16 : 20)
                        }
                        Color.clear.frame(height: 24)
                    }
                    .padding(.horizontal, 20)
                }
            }
        }
        .background(Theme.readBG.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }

    @ViewBuilder private func articleBody(_ a: MinedArticle) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(ArticleBody.segments(a.body)) { seg in
                switch seg {
                case .text(let t):
                    Text((try? AttributedString(markdown: t, options: .init(
                        interpretedSyntax: .inlineOnlyPreservingWhitespace,
                        failurePolicy: .returnPartiallyParsedIfPossible))) ?? AttributedString(t))
                        .font(.system(size: 16)).foregroundStyle(Theme.bodyRead)
                        .lineSpacing(9).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                case .photo(let token):
                    if let relKey = ArticleBody.resolvePhotoKey(token, photos: shared.photos ?? []) {
                        CommunityPhotoTile(store: store, fullKey: shared.owner + relKey)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var chipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(articles.enumerated()), id: \.offset) { i, a in
                    Button { articleIndex = i } label: {
                        Text(a.title).lineLimit(1)
                            .font(.system(size: 13, weight: i == articleIndex ? .semibold : .regular))
                            .padding(.horizontal, 14).padding(.vertical, 6)
                            .background(i == articleIndex ? Theme.accentSoft : Theme.card,
                                        in: RoundedRectangle(cornerRadius: Theme.R.chip))
                            .overlay(RoundedRectangle(cornerRadius: Theme.R.chip)
                                .stroke(i == articleIndex ? .clear : Theme.borderRead, lineWidth: 1))
                            .foregroundStyle(i == articleIndex ? Theme.accent : Theme.metaRead)
                    }
                }
            }
        }
    }
}
