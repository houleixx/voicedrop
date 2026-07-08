import Foundation

// Small networking helpers shared by every API caller (Library, Community,
// Settings, Uploader, AgentSession, …). Single source of truth: the bearer-auth
// header, the HTTP success check, and URL-path percent-encoding each lived as
// copy-pasted boilerplate in 30 / 24 / 8 spots. Change here once.

extension URLRequest {
    /// Set the `Authorization: Bearer <token>` header.
    mutating func setBearer(_ token: String) {
        setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
}

extension URLResponse {
    /// HTTP status code, or 0 if this isn't an HTTP response. Named `httpStatusCode`
    /// (not `statusCode`) to avoid colliding with HTTPURLResponse.statusCode.
    var httpStatusCode: Int { (self as? HTTPURLResponse)?.statusCode ?? 0 }
    /// True for a 2xx HTTP response.
    var isOK: Bool { (200..<300).contains(httpStatusCode) }
}

extension String {
    /// Percent-encode for use as a URL path segment, falling back to self.
    var urlPathEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? self
    }
}

/// THE single source of truth for every backend host/URL. Was hardcoded as
/// `URL(string: "https://jianshuo.dev/…")!` in ~14 spots across the app (and the
/// Share Extension) — point the app at a staging host by editing only `host` here.
/// Compiled into BOTH targets (this file is in VoiceDropShare too).
enum API {
    static let host = "jianshuo.dev"
    static let filesBase = URL(string: "https://\(host)/files/api")!   // Files API (articles, files, photos, share, wechat, community)
    static let agentBase = URL(string: "https://\(host)/agent")!       // Agent worker (mine trigger, usage, link REST)
    static let recoBase  = URL(string: "https://\(host)/reco")!        // Reco worker (ranking, engagement)
    static let agentWS   = "wss://\(host)/agent"                        // WebSocket base: append /edit, /status, /asr (+ query)
    static let agentLink = URL(string: "https://\(host)/agent/link")!  // DeviceLink REST (start / verify / …)
    /// Public share / community page for a share id. 分享页走 voicedrop.cn
    ///（.cn 域名，微信内打开不弹提示）；app 的 API 仍走 jianshuo.dev。
    static func sharePage(_ id: String) -> URL { URL(string: "https://voicedrop.cn/\(id)")! }
}

/// Cross-process bridge between the VoiceDrop app and its Share Extension. The
/// two run in separate sandboxes; the App Group is the only channel they share.
/// We mirror just the bearer token here (not the Keychain itself) so the
/// extension can upload as the same user without any Keychain migration risk.
/// Compiled into BOTH targets.
enum AppGroup {
    static let id = "group.com.wangjianshuo.VoiceDrop"

    /// Same R2-backed upload endpoint the in-app `Uploader` PUTs to (derived from API).
    static let uploadBase = API.filesBase.appendingPathComponent("upload")

    private static let bearerKey = "bearer"
    private static var store: UserDefaults? { UserDefaults(suiteName: id) }

    /// Called by the app whenever its anon token loads or changes.
    static func publishBearer(_ token: String) { store?.set(token, forKey: bearerKey) }

    /// Read by the extension at upload time. Empty until the app has run once.
    static var sharedBearer: String { store?.string(forKey: bearerKey) ?? "" }
}
