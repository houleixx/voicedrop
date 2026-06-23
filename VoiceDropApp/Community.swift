import SwiftUI
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
    var id: String { shareId }
}

/// The full shared snapshot (title + articles), read-only.
struct CommunityFullPost: Decodable {
    let shareId: String
    let author: String?
    let title: String?
    let articles: [MinedArticle]?
    let firstSharedAt: Double?
}

@MainActor
@Observable
final class CommunityStore {
    var posts: [CommunityPost] = []
    var loading = false
    var error: String?

    private let base = URL(string: "https://jianshuo.dev/files/api")!
    private var token: String { AuthStore.shared.bearer }

    /// All shared posts, newest-first by first-share time (server-sorted).
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
        } catch { self.error = error.localizedDescription }
    }

    /// Share (or re-share) one of the user's articles to the community.
    func share(_ rec: Recording) async -> Bool {
        guard !token.isEmpty, rec.hasArticles else { return false }
        var req = URLRequest(url: base.appending(path: "community").appending(path: "share").appending(path: rec.articleKey))
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            return (resp as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } == true
        } catch { return false }
    }

    /// Un-share (delete) one of the user's own community posts. Removed from the
    /// list immediately (optimistic); reloads if the server rejects it.
    @discardableResult
    func unshare(_ shareId: String) async -> Bool {
        guard !token.isEmpty else { return false }
        posts.removeAll { $0.shareId == shareId }
        var req = URLRequest(url: base.appending(path: "community").appending(path: "unshare").appending(path: shareId))
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let ok = (resp as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } == true
            if !ok { await load() }
            return ok
        } catch { await load(); return false }
    }

    /// Whether this article is currently shared to the community (drives the
    /// 分享 / 更新 menu label).
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
}

/// Format a ms-epoch share time as "6月22日" (or a year if not this year).
func communityDate(_ ms: Double?) -> String {
    guard let ms else { return "" }
    let date = Date(timeIntervalSince1970: ms / 1000)
    let f = DateFormatter()
    f.locale = Locale(identifier: "zh_CN")
    f.dateFormat = Calendar.current.isDate(date, equalTo: Date(), toGranularity: .year) ? "M月d日" : "yyyy年M月d日"
    return f.string(from: date)
}

// MARK: - Community read view (read-only article)

struct CommunityPostView: View {
    let store: CommunityStore
    let post: CommunityPost

    @Environment(\.dismiss) private var dismiss
    @State private var full: CommunityFullPost?
    @State private var loading = true
    @State private var articleIndex = 0

    private var articles: [MinedArticle] { full?.articles ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                NavSquare(systemName: "chevron.left", stroke: Theme.inkRead, border: Theme.borderRead) { dismiss() }
                    .accessibilityLabel("返回")
                Spacer()
            }
            .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 8)

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

                            if articles.count > 1 { chipRow.padding(.top, 16) }

                            Text((try? AttributedString(markdown: a.body, options: .init(
                                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                failurePolicy: .returnPartiallyParsedIfPossible))) ?? AttributedString(a.body))
                                .font(.system(size: 16)).foregroundStyle(Theme.bodyRead)
                                .lineSpacing(9).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, articles.count > 1 ? 16 : 20)
                        }
                    }
                    .padding(.horizontal, 20).padding(.bottom, 40)
                }
            }
        }
        .background(Theme.readBG.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task { full = await store.fetchPost(post.shareId); loading = false }
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
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
