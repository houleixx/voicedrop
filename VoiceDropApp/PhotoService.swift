import Foundation
import UIKit

/// THE single place for scene-photo HTTP I/O. Download and upload were each
/// copy-pasted in two stores (LibraryStore / CommunityStore / RecordSession),
/// already drifting in URL encoding. Centralize so the endpoint, auth, and
/// encoding live once.
enum PhotoService {
    /// Decoded-image cache, keyed by full R2 key. Photo keys are immutable content
    /// addresses (an AI edit mints a NEW key, it never rewrites the old one), so a
    /// hit can be trusted forever — no TTL, no revalidation. NSCache evicts under
    /// memory pressure on its own; cost is the decoded bitmap size, not the JPEG size.
    // NSCache is documented thread-safe; it just isn't marked Sendable.
    nonisolated(unsafe) private static let decodedCache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.totalCostLimit = 128 << 20   // ~128MB of decoded pixels (~20 张 1080p 图)
        return c
    }()

    /// Fetch + decode a photo, front-loaded by the in-process image cache: a repeat
    /// visit to an article renders its photos instantly instead of re-downloading.
    /// `ignoringLocalCache` skips the cache READ (a retry must probe the network) but
    /// a successful fetch is always written back.
    static func image(fullKey: String, ignoringLocalCache: Bool = false) async -> UIImage? {
        if !ignoringLocalCache, let hit = decodedCache.object(forKey: fullKey as NSString) { return hit }
        guard let d = await data(fullKey: fullKey, ignoringLocalCache: ignoringLocalCache),
              let ui = UIImage(data: d) else { return nil }
        let px = ui.size.width * ui.size.height * ui.scale * ui.scale
        decodedCache.setObject(ui, forKey: fullKey as NSString, cost: Int(px * 4))
        return ui
    }

    /// Download a photo by its FULL R2 key via the public `/photo/<key>` endpoint
    /// (no auth — the one photo URL the app, community, and web pages all use).
    ///
    /// `ignoringLocalCache` exists because CFNetwork can pin a failed response for a
    /// URL despite the server's `no-store` (seen 2026-07-09: an AI photo's 制作中-window
    /// miss stuck forever while Safari showed the same URL fine). Retry attempts MUST
    /// bypass the local cache or a cached failure can never self-heal.
    static func data(fullKey: String, ignoringLocalCache: Bool = false) async -> Data? {
        guard !fullKey.isEmpty,
              let url = URL(string: "\(API.filesBase.absoluteString)/photo/\(fullKey.urlPathEncoded)")
        else { return nil }
        var req = URLRequest(url: url)
        if ignoringLocalCache { req.cachePolicy = .reloadIgnoringLocalCacheData }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            return resp.isOK ? data : nil
        } catch { return nil }
    }

    /// PUT JPEG bytes to a relative key (within the bearer's own scope). Returns the
    /// relative key on success, nil otherwise.
    @discardableResult
    static func upload(data: Data, relKey: String, bearer: String) async -> String? {
        guard !bearer.isEmpty,
              let url = URL(string: "\(API.filesBase.absoluteString)/upload/\(relKey.urlPathEncoded)")
        else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setBearer(bearer)
        req.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        // 原样直传：进这里的字节都已被来源路径正确处理（拍照=方图 ≤1080、相册
        // 导入=原比例长边 ≤1440）。以前这里会再裁一次 1:1，把导入保住的长宽比
        // 又剪掉——显示端 PhotoTile 本就按真实比例自适应，不需要方图。
        req.httpBody = data
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            return resp.isOK ? relKey : nil
        } catch { return nil }
    }
}
