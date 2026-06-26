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

@MainActor
@Observable
final class CommunityStore {
    var posts: [CommunityPost] = []
    var loading = false
    var error: String?

    private let base = URL(string: "https://jianshuo.dev/files/api")!
    private let recoBase = URL(string: "https://jianshuo.dev/reco")!
    private var token: String { AuthStore.shared.bearer }

    /// reco identity = the iCloud-Keychain anon token, ALWAYS (even when signed in
    /// with Apple). The core's Apple session scope is itself `users/anon-<hash>/`
    /// (Apple sign-in only BINDS the Apple ID to the existing anon box — see core
    /// auth/apple), so the anon token resolves to the SAME user_sub. Sending it to
    /// reco is identity-equivalent and means reco needs no SESSION_SECRET at all.
    private var recoToken: String { AuthStore.shared.anonToken }

    /// shareIds the current user has liked — filled by `applyRanking()`, seeds the ❤️ state.
    var likedShareIds: Set<String> = []

    /// All shared posts, newest-first by first-share time.
    func load() async {
        guard !token.isEmpty else { return }
        loading = true; error = nil
        defer { loading = false }
        var req = URLRequest(url: base.appending(path: "community").appending(path: "list"))
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true else { error = "加载失败"; return }
            struct R: Decodable { let posts: [CommunityPost] }
            posts = try JSONDecoder().decode(R.self, from: data).posts
            await applyRanking()
        } catch { self.error = error.localizedDescription }
    }

    /// Ask reco how to order the feed; on success reorder `posts` and record what I liked.
    /// On failure/timeout keep the time-sort — the feed always shows.
    private func applyRanking() async {
        guard !posts.isEmpty, !recoToken.isEmpty else { return }
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
        req.timeoutInterval = 2   // timeout → fall back to time-sort
        req.setValue("Bearer \(recoToken)", forHTTPHeaderField: "Authorization")
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
            if reordered.count == posts.count { posts = reordered }  // replace only on full coverage
        } catch { /* fall back: keep time-sort */ }
    }

    /// Share (or re-share) one of the user's articles. Returns shareId on success, nil on failure.
    /// `replyTo` links this post to another post's shareId.
    func share(_ rec: Recording, replyTo: String? = nil) async -> String? {
        needsAppleSignIn = false
        guard !token.isEmpty, rec.hasArticles else { return nil }
        if let id = await postShare(rec, replyTo: replyTo) { return id }
        if needsAppleSignIn {
            await AuthStore.shared.signInWithApple()
            guard AuthStore.shared.isAuthenticated else { return nil }
            return await postShare(rec, replyTo: replyTo)
        }
        return nil
    }

    /// Returns shareId if this recording is currently shared to the community, nil otherwise.
    func sharedShareId(_ rec: Recording) async -> String? {
        guard !token.isEmpty, rec.hasArticles else { return nil }
        var req = URLRequest(url: base.appending(path: "community").appending(path: "shared").appending(path: rec.articleKey))
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true else { return nil }
            struct R: Decodable { let shared: Bool; let shareId: String? }
            let r = try? JSONDecoder().decode(R.self, from: data)
            return r?.shared == true ? r?.shareId : nil
        } catch { return nil }
    }

    private var needsAppleSignIn = false

    private func postShare(_ rec: Recording, replyTo: String?) async -> String? {
        var req = URLRequest(url: base.appending(path: "community").appending(path: "share").appending(path: rec.articleKey))
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let replyTo {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONEncoder().encode(["replyTo": replyTo])
        }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(code) {
                needsAppleSignIn = false
                struct R: Decodable { let shareId: String? }
                return (try? JSONDecoder().decode(R.self, from: data))?.shareId
            }
            needsAppleSignIn = (code == 403) &&
                ((try? JSONDecoder().decode([String: String].self, from: data))?["error"] == "needs_apple_signin")
            return nil
        } catch { return nil }
    }

    @discardableResult
    func unshare(_ shareId: String) async -> Bool {
        needsAppleSignIn = false
        guard !token.isEmpty else { return false }
        posts.removeAll { $0.shareId == shareId }
        if await postUnshare(shareId) { return true }
        if needsAppleSignIn {
            await AuthStore.shared.signInWithApple()
            if AuthStore.shared.isAuthenticated { if await postUnshare(shareId) { return true } }
            await load(); return false
        }
        await load(); return false
    }

    private func postUnshare(_ shareId: String) async -> Bool {
        var req = URLRequest(url: base.appending(path: "community").appending(path: "unshare").appending(path: shareId))
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if (200..<300).contains(code) { needsAppleSignIn = false; return true }
            needsAppleSignIn = (code == 403) &&
                ((try? JSONDecoder().decode([String: String].self, from: data))?["error"] == "needs_apple_signin")
            return false
        } catch { return false }
    }

    func isShared(_ rec: Recording) async -> Bool {
        guard !token.isEmpty, rec.hasArticles else { return false }
        var req = URLRequest(url: base.appending(path: "community").appending(path: "shared").appending(path: rec.articleKey))
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true else { return false }
            struct R: Decodable { let shared: Bool }
            return (try? JSONDecoder().decode(R.self, from: data))?.shared ?? false
        } catch { return false }
    }

    func fetchPost(_ shareId: String) async -> CommunityFullPost? {
        guard !token.isEmpty else { return nil }
        var req = URLRequest(url: base.appending(path: "community").appending(path: "get").appending(path: shareId))
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true else { return nil }
            return try JSONDecoder().decode(CommunityFullPost.self, from: data)
        } catch { return nil }
    }

    /// Download a photo by its full R2 key (`users/<sub>/photos/…`) via the public
    /// `/photo/<key>` endpoint — no auth, the same URL the web pages use. One photo
    /// logic everywhere: read straight from the photo's original location.
    func photoData(fullKey: String) async -> Data? {
        guard !fullKey.isEmpty else { return nil }
        let enc = fullKey.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? fullKey
        guard let url = URL(string: "\(base.absoluteString)/photo/\(enc)") else { return nil }
        do {
            let (data, resp) = try await URLSession.shared.data(from: url)
            guard (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true else { return nil }
            return data
        } catch { return nil }
    }

    /// Report one engagement. Failures are silently ignored — when reco is down the
    /// core experience is unaffected.
    func engage(_ shareId: String, action: String, on: Bool? = nil) async {
        guard !recoToken.isEmpty else { return }
        var req = URLRequest(url: recoBase.appending(path: "engage").appending(path: shareId))
        req.httpMethod = "POST"
        req.timeoutInterval = 3
        req.setValue("Bearer \(recoToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["action": action]
        if let on { body["on"] = on }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: req)
    }

    /// Posts that are responses to `shareId`, oldest-first.
    func loadReplies(_ shareId: String) async -> [CommunityPost] {
        guard !token.isEmpty else { return [] }
        var req = URLRequest(url: base.appending(path: "community").appending(path: "replies").appending(path: shareId))
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true else { return [] }
            struct R: Decodable { let posts: [CommunityPost] }
            return (try? JSONDecoder().decode(R.self, from: data))?.posts ?? []
        } catch { return [] }
    }
}

/// Format a ms-epoch time as "6月22日" (or include year if not this year).
func communityDate(_ ms: Double?) -> String {
    guard let ms else { return "" }
    let date = Date(timeIntervalSince1970: ms / 1000)
    let f = DateFormatter()
    f.locale = Locale(identifier: "zh_CN")
    f.dateFormat = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year) ? "M月d日" : "yyyy年M月d日"
    return f.string(from: date)
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
    @State private var selectedReply: CommunityPost?
    @State private var replyToFull: CommunityFullPost?   // the post this article responds to
    @State private var selectedOriginal: CommunityPost?  // navigate to original post
    @State private var sharePayload: SharePayload?
    @State private var toast: String?
    @State private var liked = false
    @State private var finishedReported = false

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
                                Text(full?.author ?? "匿名").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.accent)
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
        .sheet(item: $sharePayload) { ShareSheet(items: [$0.text]) }
        .task {
            liked = store.likedShareIds.contains(post.shareId)
            await store.engage(post.shareId, action: "view")
            full = await store.fetchPost(post.shareId)
            loading = false
            async let repliesTask = store.loadReplies(post.shareId)
            if let replyToId = full?.replyTo ?? post.replyTo {
                replyToFull = await store.fetchPost(replyToId)
            }
            replies = await repliesTask
        }
        .onDisappear { _ = recorder.stop() }
    }

    // MARK: Nav bar (⋯ menu)

    private var navBar: some View {
        HStack {
            NavSquare(systemName: "chevron.left", stroke: Theme.inkRead, border: Theme.borderRead) { dismiss() }
                .accessibilityLabel("返回")
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
                Button { Task { await startResponse() } } label: {
                    Label("写回应", systemImage: "mic")
                }
                Button { sharePost() } label: {
                    Label("分享", systemImage: "square.and.arrow.up")
                }
                Button(role: .destructive) { showToast("举报功能即将上线") } label: {
                    Label("举报", systemImage: "flag")
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
            .accessibilityLabel("更多")
        }
        .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 8)
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
                Text((orig.articles?.first?.title ?? orig.title ?? orig.author) ?? "原文")
                    .font(.system(size: 12)).lineLimit(1).truncationMode(.tail)
                Image(systemName: "chevron.right").font(.system(size: 10))
            }
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Theme.accentSoft, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var repliesSection: some View {
        if !replies.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Rectangle().fill(Theme.borderRead).frame(height: 1).padding(.top, 32)
                ForEach(replies) { reply in
                    Button { selectedReply = reply } label: {
                        HStack(spacing: 6) {
                            Text(reply.author ?? "匿名")
                                .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.accent)
                                .layoutPriority(1)
                            Text(communityDate(reply.firstSharedAt))
                                .font(.system(size: 12)).foregroundStyle(Theme.metaRead)
                                .layoutPriority(1)
                            if let title = reply.title {
                                Text("· \(title)")
                                    .font(.system(size: 13)).foregroundStyle(Theme.bodyRead)
                                    .lineLimit(1).truncationMode(.tail)
                            }
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11)).foregroundStyle(Theme.faint)
                        }
                        .padding(.vertical, 11)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(Rectangle().fill(Theme.borderRead).frame(height: 0.5), alignment: .bottom)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
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
        guard granted else { showToast("请在设置里开启麦克风权限"); return }
        location.start()
        do {
            try recorder.start()
            withAnimation { recorderPhase = .recording }
        } catch {
            showToast("无法开始录音")
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
        let place = await location.placeTag()
        let finalName = RecordingName.make(start: take.start, duration: take.duration, place: place)
        var finalURL = AudioRecorder.documentsDir.appending(path: finalName)
        do {
            try FileManager.default.moveItem(at: take.url, to: finalURL)
        } catch {
            let fallback = "VoiceDrop-\(RecordingName.timestamp(take.start)).m4a"
            let fallbackURL = AudioRecorder.documentsDir.appending(path: fallback)
            if (try? FileManager.default.moveItem(at: take.url, to: fallbackURL)) != nil {
                finalURL = fallbackURL
            }
        }
        // LibraryView.onChange picks this up when the article is mined and auto-shares with replyTo.
        UserDefaults.standard.set(post.shareId, forKey: "vd.pendingReply.\(finalURL.lastPathComponent)")
        if Prefs.shared.iCloudBackup {
            let toArchive = finalURL
            await Task.detached { ICloudArchive.save(toArchive) }.value
        }
    }

    // MARK: Share this post

    private func sharePost() {
        let title = full?.articles?.first?.title ?? post.title ?? "VoiceDrop 分享"
        let author = full?.author ?? post.author ?? "匿名"
        sharePayload = SharePayload(text: "《\(title)》— \(author)\n来自 VoiceDrop 社区")
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

    private func timeString(_ t: TimeInterval) -> String {
        let s = Int(t); return String(format: "%02d:%02d", s / 60, s % 60)
    }
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
        RoundedRectangle(cornerRadius: 12)
            .fill(Theme.card)
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay {
                if let img = image {
                    Image(uiImage: img)
                        .resizable().scaledToFill()
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    ProgressView().tint(Theme.accent)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            // Bind to the key (not view identity) so a shifted marker re-fetches.
            .task(id: fullKey) {
                image = nil
                guard let data = await store.photoData(fullKey: fullKey) else { return }
                image = UIImage(data: data)
            }
    }
}
