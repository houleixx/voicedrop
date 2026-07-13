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

    // ── 磁盘缓存（Caches/photo-cache/）───────────────────────────────────────────
    // 内存缓存活不过冷启动——列表两百多个封面图标每次启动全量重下，国内直连
    // Cloudflare 的窄带宽一张 140KB 原图就要 1s+，这是「图标特别慢」的主凶。
    // key 不可变（同上），下载成功的 JPEG 字节落盘即可信一辈子；放 Caches/ 系统
    // 存储紧张时可整体回收，自己再加一道 512MB 的粗剪。
    nonisolated(unsafe) private static let diskDir: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "photo-cache", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        trimIfOversized(dir)
        return dir
    }()

    private static func diskURL(_ fullKey: String) -> URL {
        diskDir.appending(path: fullKey.replacingOccurrences(of: "/", with: "_"))
    }

    /// 启动时一次性粗剪：超过 512MB 就按修改时间删最旧的一半。O(文件数)，几百个
    /// 文件毫秒级；不追求精确 LRU——这是缓存，删错了顶多重下一次。
    private static func trimIfOversized(_ dir: URL) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }
        var entries: [(url: URL, size: Int, mtime: Date)] = files.compactMap {
            guard let v = try? $0.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
            return ($0, v.fileSize ?? 0, v.contentModificationDate ?? .distantPast)
        }
        guard entries.reduce(0, { $0 + $1.size }) > 512 << 20 else { return }
        entries.sort { $0.mtime < $1.mtime }
        for e in entries.prefix(entries.count / 2) { try? fm.removeItem(at: e.url) }
    }

    // ── 缩略图变体 ────────────────────────────────────────────────────────────────
    // 列表 42pt 图标、社区瀑布流卡片不需要 1200px 原图。上传时旁挂一张长边 512px、
    // q0.6 的 `<name>.thumb.jpg`（~15-40KB，小 4-10 倍），展示面 preferThumb 先取
    // 它；老照片没有缩略图 → 404 记进 missing 集（免得每次滚动重试探测）→ 回退原图。
    nonisolated(unsafe) private static var thumbMissing = Set<String>()
    private static let thumbLock = NSLock()
    // 同步小包装：NSLock 的 lock()/unlock() 在 async 上下文不可用（Swift 6），
    // withLock 的同步函数可以。
    private static func thumbMissed(_ tk: String) -> Bool { thumbLock.withLock { thumbMissing.contains(tk) } }
    private static func markThumbMissed(_ tk: String) { thumbLock.withLock { _ = thumbMissing.insert(tk) } }

    /// photos/<ts>/<n>-<rand>.jpg → photos/<ts>/<n>-<rand>.thumb.jpg（非 .jpg 键返 nil）
    static func thumbKey(_ fullKey: String) -> String? {
        guard fullKey.hasSuffix(".jpg"), !fullKey.hasSuffix(".thumb.jpg") else { return nil }
        return String(fullKey.dropLast(4)) + ".thumb.jpg"
    }

    /// Fetch + decode a photo, front-loaded by the in-process image cache: a repeat
    /// visit to an article renders its photos instantly instead of re-downloading.
    /// `ignoringLocalCache` skips the cache READ (a retry must probe the network) but
    /// a successful fetch is always written back.
    /// `preferThumb`: 展示尺寸小（列表图标/卡片）时先取 .thumb.jpg 变体，缺了回退原图。
    static func image(fullKey: String, ignoringLocalCache: Bool = false, preferThumb: Bool = false) async -> UIImage? {
        if preferThumb, let tk = thumbKey(fullKey), !thumbMissed(tk) {
            if let thumb = await image(fullKey: tk, ignoringLocalCache: ignoringLocalCache) { return thumb }
            markThumbMissed(tk)
        }
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
    /// bypass the local cache or a cached failure can never self-heal. It also skips
    /// the disk-cache READ; a successful fetch is always written back.
    static func data(fullKey: String, ignoringLocalCache: Bool = false) async -> Data? {
        guard !fullKey.isEmpty else { return nil }
        let file = diskURL(fullKey)
        if !ignoringLocalCache, let d = try? Data(contentsOf: file), !d.isEmpty { return d }
        guard let url = URL(string: "\(API.filesBase.absoluteString)/photo/\(fullKey.urlPathEncoded)")
        else { return nil }
        var req = URLRequest(url: url)
        if ignoringLocalCache { req.cachePolicy = .reloadIgnoringLocalCacheData }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard resp.isOK, !data.isEmpty else { return nil }
            try? data.write(to: file, options: .atomic)   // 只缓存成功响应——失败绝不落盘
            return data
        } catch { return nil }
    }

    /// PUT JPEG bytes to a relative key (within the bearer's own scope). Returns the
    /// relative key on success, nil otherwise. 成功后顺手旁挂缩略图（best-effort，
    /// 失败不影响主图——展示面会回退原图）。
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
            guard resp.isOK else { return nil }
            await uploadThumb(original: data, relKey: relKey, bearer: bearer)
            return relKey
        } catch { return nil }
    }

    /// 生成并上传 512px/q0.6 的缩略图变体。解码/缩放放后台线程；任何一步失败都
    /// 静默放弃（缺缩略图只是慢，不是错）。
    private static func uploadThumb(original: Data, relKey: String, bearer: String) async {
        guard let tk = thumbKey(relKey) else { return }
        let thumbData: Data? = await Task.detached(priority: .utility) {
            guard let ui = UIImage(data: original) else { return nil }
            let longEdge = max(ui.size.width, ui.size.height)
            guard longEdge > 0 else { return nil }
            let scale = min(1, 512 / longEdge)
            let size = CGSize(width: ui.size.width * scale, height: ui.size.height * scale)
            let fmt = UIGraphicsImageRendererFormat()
            fmt.scale = 1
            let small = UIGraphicsImageRenderer(size: size, format: fmt).image { _ in
                ui.draw(in: CGRect(origin: .zero, size: size))
            }
            return small.jpegData(compressionQuality: 0.6)
        }.value
        guard let thumbData,
              let url = URL(string: "\(API.filesBase.absoluteString)/upload/\(tk.urlPathEncoded)")
        else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setBearer(bearer)
        req.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        req.httpBody = thumbData
        _ = try? await URLSession.shared.data(for: req)
    }
}
