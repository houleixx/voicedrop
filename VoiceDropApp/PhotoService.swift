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
        let body = Self.squareJPEG(data) ?? data
        req.httpBody = body
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            return resp.isOK ? relKey : nil
        } catch { return nil }
    }

    /// Center-crop image data to a 1:1 square, re-encoded as JPEG. Returns nil on failure
    /// (caller falls back to the original bytes). Photos are square everywhere in the app
    /// (article tiles are 1:1) and AI edits follow the input aspect ratio, so squaring at
    /// upload keeps both the stored photo and its edited version 1:1.
    static func squareJPEG(_ data: Data, quality: CGFloat = 0.9) -> Data? {
        guard let img = UIImage(data: data) else { return nil }
        let side = min(img.size.width, img.size.height)
        if side <= 0 { return nil }
        let x = (img.size.width - side) / 2
        let y = (img.size.height - side) / 2
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = img.scale
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        let out = renderer.image { _ in
            // draw the upright image shifted so the centered square lands at (0,0)
            img.draw(in: CGRect(x: -x, y: -y, width: img.size.width, height: img.size.height))
        }
        return out.jpegData(compressionQuality: quality)
    }
}
