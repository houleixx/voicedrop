import SwiftUI
import SafariServices

/// Deep-link targets for the `voicedrop://` URL scheme AND universal links
/// (https://voicedrop.cn/…). One address per main page. The Share Extension and
/// any external link open these; `AppRouter`
/// parses the URL and `LibraryView` applies it (switching tab AND clearing any
/// pushed detail/settings so the link always lands cleanly — the earlier
/// "just set the tab" approach left you on whatever detail page was open).
///
/// Addresses:
///   voicedrop://recordings        我的录音（列表根）
///   voicedrop://community         VD社区
///   voicedrop://settings          设置
///   voicedrop://record            开始录音（全屏）
///   voicedrop://record?tag=创业   开始录音，挖出的文章缺省带该标签
///   voicedrop://article/<stem>    某篇文章详情（stem 形如 VoiceDrop-2026-07-01-…）
///
/// Universal links (entitlement applinks: voicedrop.cn / www / jianshuo.dev):
///   https://voicedrop.cn/                     → 我的录音（落地页 = App 主页）
///   https://voicedrop.cn/<7位魔法数字>        → .promptImport：Prompt Manager 导入 sheet
///     预填该码（Task 6）——纯 7 位数字，文章分享 id 是 10 位 hex、社区帖 12 位，判在
///     .shareLink 之前，两者不会互相误判。
///   https://voicedrop.cn/<分享id>             → .shareLink：问服务端这个 id 指向谁
///     （GET /files/api/link/<id>）——自己的文章开原生详情页，别人的分享/社区帖
///     开站内 Safari（页面本身就是完整阅读体验）
///   https://jianshuo.dev/voicedrop/<token>    → 同上（老分享链接）
///   其余路径（/help/ 等）                      → .web：站内 Safari 兜底，绝不死链
enum DeepLink: Equatable {
    case recordings
    case community
    case settings
    case record(tag: String?)
    case article(String)
    case shareLink(id: String, fallback: URL)
    case promptImport(code: String)
    case web(URL)
}

@MainActor
final class AppRouter: ObservableObject {
    /// One shared instance: the SwiftUI App owns it as its StateObject AND the
    /// App Intents (开始录音) reach it directly — an in-app intent has no access
    /// to the view hierarchy's environment.
    static let shared = AppRouter()

    /// The last deep link received, awaiting application by LibraryView. Cleared
    /// after it's applied so re-subscribing doesn't re-trigger it.
    @Published var pending: DeepLink?

    func handle(_ url: URL) {
        let scheme = url.scheme?.lowercased()
        if scheme == "https" || scheme == "http" {
            if let link = Self.universalLink(url) {
                pending = link
                // 邀请归因第 1 层：分享链接拉起 App = 确定归因（24h 内新装才实际生效）。
                if case .shareLink(let id, _) = link { ReferralManager.shared.noteShareToken(id) }
            }
            return
        }
        guard url.scheme?.lowercased() == "voicedrop" else { return }
        switch (url.host ?? "").lowercased() {
        case "", "recordings", "home": pending = .recordings
        case "community":              pending = .community
        case "settings", "setting":    pending = .settings
        case "record":
            let tag = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "tag" }?.value
            pending = .record(tag: (tag?.isEmpty ?? true) ? nil : tag)
        case "article":
            // voicedrop://article/<stem>  → path components after the host
            let stem = url.pathComponents.filter { $0 != "/" }.joined(separator: "/")
            pending = stem.isEmpty ? .recordings : .article(stem)
        default:                       pending = .recordings
        }
    }

    /// Map a universal link to a deep link. Unknown host → nil (not ours, ignore);
    /// known host but unroutable path → .web (in-app Safari), so a link that
    /// already opened the app never dead-ends. A single root segment that looks
    /// like a share id (voicedrop.cn/<id>, 也含社区帖 12 位 id) becomes .shareLink —
    /// resolution (own article vs someone else's) happens in LibraryView, which
    /// has the store + network; a false positive (e.g. /welcome) just resolves
    /// to 404 and falls back to the web page, mirroring the server's own
    /// static-fallthrough behavior in functions/[token].js.
    static func universalLink(_ url: URL) -> DeepLink? {
        guard let host = url.host?.lowercased() else { return nil }
        var segs = url.pathComponents.filter { $0 != "/" }
        switch host {
        case "voicedrop.cn", "www.voicedrop.cn":
            break
        case "jianshuo.dev", "www.jianshuo.dev":
            guard segs.first == "voicedrop" else { return nil }
            segs.removeFirst()
        default:
            return nil
        }
        guard let first = segs.first else { return .recordings }   // 落地页 = App 主页
        // 7 位纯数字＝提示词魔法数字（Task 6），判在 shareLink 前面：文章分享 id 是 10 位
        // hex、社区帖 12 位，跟 7 位数字没有交集，但 shareLink 的宽正则会把纯数字也吃进去，
        // 所以窄的先判。
        if segs.count == 1, first.range(of: "^[1-9][0-9]{6}$", options: .regularExpression) != nil {
            return .promptImport(code: first)
        }
        if segs.count == 1, first.range(of: "^[A-Za-z0-9_-]{6,16}$", options: .regularExpression) != nil {
            return .shareLink(id: first, fallback: url)
        }
        return .web(url)
    }
}

/// In-app Safari for universal links the app can't render natively (someone
/// else's share, /help/, …) — the link still opens inside VoiceDrop instead of
/// bouncing back out to Safari.app.
struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ vc: SFSafariViewController, context: Context) {}
}
