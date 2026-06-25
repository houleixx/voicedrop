import Foundation
import Observation
import AVFoundation

// MARK: - Models

/// One mined article (v2 schema: many per recording).
struct MinedArticle: Decodable, Identifiable {
    let title: String
    let body: String
    var wechatMediaId: String?      // present once a WeChat draft has been created
    var id: String { title + "\(body.count)" }
}

/// The `articles/<stem>.json` document the server miner writes. Handles both the
/// v2 schema (`articles: [...]`) and the v1 schema (a single `title`/`body`).
struct ArticleDoc: Decodable {
    let id: String?
    let sourceAudio: String?
    let createdAt: String?
    let transcript: String?
    let srt: String?
    let articles: [MinedArticle]?
    /// Relative R2 keys for photos taken during this recording session.
    /// e.g. ["photos/2026-06-24-131500/2026-06-24-131523.jpg"]
    let photos: [String]?
    // v1 fallback fields
    let title: String?
    let body: String?

    var resolvedArticles: [MinedArticle] {
        if let a = articles, !a.isEmpty { return a }
        if let b = body, !b.isEmpty { return [MinedArticle(title: title ?? "(无题)", body: b)] }
        return []
    }

    /// True once any article has a WeChat draft (the menu shows 更新 instead of 发布).
    var hasWechatDraft: Bool { (articles ?? []).contains { $0.wechatMediaId != nil } }
}

/// A piece of an article body: a run of markdown text, or an inline photo
/// (1-based index into the doc's `photos` array), parsed from `[[photo:N]]`
/// markers the miner inserts at the spot the scene is described.
enum ArticleSegment: Identifiable {
    case text(String)
    case photo(Int)
    var id: String {
        switch self {
        case .text(let s): return "t:\(s.count):\(s.prefix(12))"
        case .photo(let n): return "p:\(n)"
        }
    }
}

enum ArticleBody {
    private static let marker = try! NSRegularExpression(pattern: #"\[\[photo:(\d+)\]\]"#)

    /// Split a body into text + photo segments at `[[photo:N]]` markers.
    static func segments(_ body: String) -> [ArticleSegment] {
        let ns = body as NSString
        let matches = marker.matches(in: body, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return [.text(body)] }
        var out: [ArticleSegment] = []
        var cursor = 0
        for m in matches {
            if m.range.location > cursor {
                let text = ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { out.append(.text(trimmed)) }
            }
            if let n = Int(ns.substring(with: m.range(at: 1))) { out.append(.photo(n)) }
            cursor = m.range.location + m.range.length
        }
        if cursor < ns.length {
            let text = ns.substring(from: cursor).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { out.append(.text(text)) }
        }
        return out
    }

    /// Body with all `[[photo:N]]` markers removed — for places that can't render
    /// the session photos (WeChat, the cross-user community, share excerpts).
    static func stripMarkers(_ body: String) -> String {
        let ns = body as NSString
        let stripped = marker.stringByReplacingMatches(
            in: body, range: NSRange(location: 0, length: ns.length), withTemplate: "")
        return stripped.replacingOccurrences(of: "\n\n\n", with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Which phase of mining a recording is in (pushed live by mine.py over the
/// status WebSocket). Drives the in-flight badge label.
enum MiningPhase: String { case asr, mining
    var badge: String { self == .asr ? "听录音" : "挖文章" }
}

/// A recording as seen in the user's R2 space: the audio key plus whether the
/// miner has produced an article JSON for it yet.
struct Recording: Identifiable, Hashable {
    let audioName: String        // relative key, e.g. "VoiceDrop-….m4a"
    let uploaded: String
    let hasArticles: Bool
    let isEmpty: Bool            // a `articles/<stem>.empty` marker exists (no usable speech)
    var articleTitle: String?    // first mined article's title; fills the place slot once 已成文
    var uploading: Bool = false  // a local take still in the upload queue (not yet on the server)
    var phase: MiningPhase? = nil // server is actively mining this right now (WebSocket push); nil = not in-flight

    var processing: Bool { phase != nil }

    var id: String { audioName }
    var stem: String { String(audioName.dropLast(4)) }          // strip .m4a
    var articleKey: String { "articles/\(stem).json" }
    var emptyKey: String { "articles/\(stem).empty" }
    var srtKey: String { "articles/\(stem).srt" }

    /// "6月18日 14:30 · Xuhui" style label — kept for detail views and export.
    var displayTitle: String {
        let dt = dateTimeLabel.map { $0 + " · " } ?? ""
        return dt + rowTitle
    }

    /// First line of a list row: article title when 已成文, place name otherwise, stem as fallback.
    var rowTitle: String {
        if let t = articleTitle, !t.isEmpty { return t }
        let p = stem.components(separatedBy: "-")
        guard p.count >= 5, p[0] == "VoiceDrop", p[1].count == 4 else { return stem }
        let place = p.count >= 10 ? p[9] : (p.count >= 9 ? p[8] : "")
        return place.isEmpty ? stem : place
    }

    /// Second line of a list row: "6月18日 14:30" parsed from the filename.
    var dateTimeLabel: String? {
        let p = stem.components(separatedBy: "-")
        guard p.count >= 5, p[0] == "VoiceDrop", p[1].count == 4 else { return nil }
        var bits: [String] = []
        if let mo = Int(p[2]), let da = Int(p[3]) { bits.append("\(mo)月\(da)日") }
        if p[4].count == 6 {
            let t = p[4]
            bits.append("\(t.prefix(2)):\(t.dropFirst(2).prefix(2))")
        }
        return bits.isEmpty ? nil : bits.joined(separator: " ")
    }

    /// "0m33s"-style duration field if present.
    var durationLabel: String? {
        stem.components(separatedBy: "-").first { $0.range(of: #"^\d+m\d+s$"#, options: .regularExpression) != nil }
    }
}

// MARK: - Store

@MainActor
@Observable
final class LibraryStore {
    var recordings: [Recording] = []
    var loading = false
    var error: String?

    private let base = URL(string: "https://jianshuo.dev/files/api")!
    private var token: String { AuthStore.shared.bearer }
    private var titleCache: [String: String] = [:]   // articleKey -> first article title
    private var processingPhase: [String: MiningPhase] = [:]   // stem -> current mining phase (WebSocket)

    private struct ListResponse: Decodable {
        struct Item: Decodable { let name: String; let uploaded: String? }
        let files: [Item]
    }

    /// Called by StatusSession when mine.py signals a stem advanced to a phase (asr / mining).
    func markPhase(stem: String, phase rawPhase: String) {
        guard let phase = MiningPhase(rawValue: rawPhase) else { return }
        processingPhase[stem] = phase
        if let idx = recordings.firstIndex(where: { $0.stem == stem }), !recordings[idx].hasArticles {
            recordings[idx].phase = phase
        }
    }

    /// Called by StatusSession when a stem is done (ready or empty). Refreshes the list.
    func markDone(stem: String) {
        processingPhase[stem] = nil
        Task { await load() }
    }

    func load() async {
        guard !token.isEmpty else { error = "请先登录"; return }
        loading = true; error = nil
        defer { loading = false }
        var req = URLRequest(url: base.appending(path: "list"))
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true else {
                error = "加载失败"; return
            }
            let list = try JSONDecoder().decode(ListResponse.self, from: data)
            let names = Set(list.files.map(\.name))
            let audios = list.files.filter {
                let leaf = $0.name.components(separatedBy: "/").last ?? $0.name
                return leaf.hasPrefix("VoiceDrop-") && leaf.hasSuffix(".m4a")
            }
            recordings = audios.map {
                let stem = String($0.name.dropLast(4))
                return Recording(audioName: $0.name,
                                 uploaded: $0.uploaded ?? "",
                                 hasArticles: names.contains("articles/\(stem).json"),
                                 isEmpty: names.contains("articles/\(stem).empty"))
            }
            .sorted { $0.audioName > $1.audioName }   // newest first (timestamped names)

            // Re-apply in-flight processing state from WebSocket, and prune stems
            // that are now done (article or empty marker already landed in R2).
            for i in recordings.indices {
                let stem = recordings[i].stem
                if let ph = processingPhase[stem] {
                    if recordings[i].hasArticles || recordings[i].isEmpty {
                        processingPhase[stem] = nil   // done — clear the in-flight marker
                    } else {
                        recordings[i].phase = ph
                    }
                }
            }

            // Apply cached titles immediately, then fetch any missing ones so the
            // 已成文 rows show the article title instead of the place.
            for i in recordings.indices where recordings[i].hasArticles {
                recordings[i].articleTitle = titleCache[recordings[i].articleKey]
            }
            await fetchMissingTitles()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// For every 已成文 recording without a cached title, fetch its doc and grab
    /// the first article's title (concurrently). Matched back by id so a delete
    /// mid-fetch can't mis-assign.
    private func fetchMissingTitles() async {
        let pending = recordings.filter { $0.hasArticles && $0.articleTitle == nil }
        guard !pending.isEmpty else { return }
        let found = await withTaskGroup(of: (String, String).self) { group -> [(String, String)] in
            for rec in pending {
                group.addTask {
                    let title = await self.fetchDoc(rec)?.resolvedArticles.first?.title ?? ""
                    return (rec.id, title)
                }
            }
            var out: [(String, String)] = []
            for await pair in group where !pair.1.isEmpty { out.append(pair) }
            return out
        }
        for (id, title) in found {
            if let idx = recordings.firstIndex(where: { $0.id == id }) {
                recordings[idx].articleTitle = title
                titleCache[recordings[idx].articleKey] = title
            }
        }
    }

    private func downloadURL(_ relName: String) -> URL {
        let enc = relName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? relName
        return URL(string: "\(base.absoluteString)/download/\(enc)")!
    }

    private func get(_ relName: String) async throws -> Data {
        var req = URLRequest(url: downloadURL(relName))
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true else {
            throw NSError(domain: "library", code: 1, userInfo: [NSLocalizedDescriptionKey: "下载失败"])
        }
        return data
    }

    /// Fetch the mined article document for a recording (nil if not mined yet).
    func fetchDoc(_ rec: Recording) async -> ArticleDoc? {
        guard rec.hasArticles else { return nil }
        do { return try JSONDecoder().decode(ArticleDoc.self, from: await get(rec.articleKey)) }
        catch { return nil }
    }

    /// Fetch the human-readable reason from a `.empty` marker (silent / corrupt /
    /// no-speech). Returns nil if the marker is missing or unreadable.
    func fetchEmptyReason(_ rec: Recording) async -> String? {
        guard rec.isEmpty else { return nil }
        struct EmptyMarker: Decodable { let reason: String? }
        do { return try JSONDecoder().decode(EmptyMarker.self, from: await get(rec.emptyKey)).reason }
        catch { return nil }
    }

    /// Delete a whole recording from R2: the audio plus every sidecar marker
    /// (article JSON, SRT, empty marker). The row is removed from the list
    /// **immediately** (optimistic), then the server deletes run. If the audio
    /// delete fails it's rolled back (it would reappear on the next load anyway);
    /// the sidecars are best-effort.
    @discardableResult
    func delete(_ rec: Recording) async -> Bool {
        guard !token.isEmpty else { error = "请先登录"; return false }
        let idx = recordings.firstIndex { $0.id == rec.id }
        recordings.removeAll { $0.id == rec.id }   // disappear now
        guard await del(rec.audioName) else {
            error = "删除失败"
            if let idx, !recordings.contains(where: { $0.id == rec.id }) {
                recordings.insert(rec, at: min(idx, recordings.count))   // rollback
            }
            return false
        }
        _ = await del(rec.articleKey)
        _ = await del(rec.srtKey)
        _ = await del(rec.emptyKey)
        return true
    }

    /// Delete only the generated article + every marker (json/srt/empty), keeping
    /// the audio. The recording drops back to 待处理 and the server re-mines it on
    /// the next cycle, regenerating the article. Reloads to reflect the new state.
    @discardableResult
    func deleteArticle(_ rec: Recording) async -> Bool {
        guard !token.isEmpty else { error = "请先登录"; return false }
        _ = await del(rec.articleKey)
        _ = await del(rec.srtKey)
        _ = await del(rec.emptyKey)
        titleCache[rec.articleKey] = nil   // re-mined article may have a new title
        await load()
        return true
    }

    /// DELETE one key. Treats 2xx and 404 as success (idempotent).
    private func del(_ relName: String) async -> Bool {
        let enc = relName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? relName
        guard let url = URL(string: "\(base.absoluteString)/file/\(enc)") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            return (200..<300).contains(code) || code == 404
        } catch { return false }
    }

    /// Mint a public share link for this recording's article(s). The server signs
    /// the article key and returns a `jianshuo.dev/voicedrop/<token>` URL anyone
    /// can open. `section` is the index of the currently-selected article; it's
    /// appended as `?s=<section>` so the public page leads with (and previews) that
    /// section instead of always the first. Returns nil if not mined yet or the
    /// request fails.
    func shareURL(_ rec: Recording, section: Int = 0) async -> URL? {
        guard !token.isEmpty, rec.hasArticles else { return nil }
        struct Resp: Decodable { let url: String }
        var req = URLRequest(url: base.appending(path: "share").appending(path: rec.articleKey))
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true else { return nil }
            let urlStr = try JSONDecoder().decode(Resp.self, from: data).url
            guard var comps = URLComponents(string: urlStr) else { return URL(string: urlStr) }
            comps.queryItems = [URLQueryItem(name: "s", value: String(section))]
            return comps.url ?? URL(string: urlStr)
        } catch { return nil }
    }

    enum PublishResult {
        case ok(created: Int, updated: Int)
        case notConfigured
        case failed(String?)            // human message (from the real WeChat error when present)
    }

    /// Push this recording's article(s) to the WeChat 公众号 draft box and wait for
    /// the REAL result. The server reads the article + creds, calls the Tokyo VPS
    /// relay (the whitelisted IP) synchronously, writes the wechatMediaId(s) back,
    /// and returns {created, updated} — or the actual WeChat errcode/errmsg. A 409
    /// means WeChat isn't configured (→ `.notConfigured`, so the UI opens config).
    /// Existing drafts are updated in place (no duplicate).
    func publishWechat(_ rec: Recording) async -> PublishResult {
        guard !token.isEmpty, rec.hasArticles else { return .failed(nil) }
        var req = URLRequest(url: base.appending(path: "wechat").appending(path: rec.articleKey))
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 409 { return .notConfigured }
            if (200..<300).contains(code) {
                struct R: Decodable { let created: Int?; let updated: Int? }
                let r = try? JSONDecoder().decode(R.self, from: data)
                return .ok(created: r?.created ?? 0, updated: r?.updated ?? 0)
            }
            struct E: Decodable { let errcode: Int?; let errmsg: String? }
            let e = try? JSONDecoder().decode(E.self, from: data)
            return .failed(Self.wechatMessage(e?.errcode, e?.errmsg))
        } catch { return .failed(nil) }
    }

    /// Map a WeChat errcode/errmsg to a friendly Chinese line. nil → use a generic toast.
    static func wechatMessage(_ errcode: Int?, _ errmsg: String?) -> String? {
        switch errcode {
        case 45004?:                     return "摘要太短，正文写长一点再发"
        case 40007?:                     return "草稿已失效，已重建一份"
        case 45009?, 45011?, 45110?:     return "今天发布次数到上限了，明天再试"
        case 40164?, 40125?, 40013?:     return "公众号配置有误，检查 AppID/Secret 或 IP 白名单"
        default:
            if errcode == nil && errmsg == nil { return nil }
            return errmsg.map { "发布失败：\($0)" } ?? "发布失败"
        }
    }

    /// Download raw data for any relative key (used by ExportManager).
    func downloadData(_ relName: String) async throws -> Data { try await get(relName) }

    /// Download the audio to a temp file for local playback.
    func downloadAudio(_ rec: Recording) async -> URL? {
        do {
            let data = try await get(rec.audioName)
            let url = FileManager.default.temporaryDirectory
                .appending(path: rec.audioName.components(separatedBy: "/").last ?? "audio.m4a")
            try data.write(to: url)
            return url
        } catch { return nil }
    }
}

// MARK: - Audio playback

@MainActor
@Observable
final class AudioPlayer: NSObject, AVAudioPlayerDelegate {
    var isPlaying = false
    var progress: Double = 0       // 0...1
    var duration: TimeInterval = 0

    private var player: AVAudioPlayer?
    private var timer: Timer?

    func load(_ url: URL) {
        stop()
        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)
        player = try? AVAudioPlayer(contentsOf: url)
        player?.delegate = self
        duration = player?.duration ?? 0
    }

    func toggle() {
        guard let player else { return }
        if player.isPlaying { player.pause(); isPlaying = false; timer?.invalidate() }
        else { player.play(); isPlaying = true; startTimer() }
    }

    func seek(to fraction: Double) {
        guard let player else { return }
        player.currentTime = fraction * player.duration
        progress = fraction
    }

    func stop() {
        player?.stop(); player = nil
        isPlaying = false; progress = 0; timer?.invalidate()
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let p = self.player, p.duration > 0 else { return }
                self.progress = p.currentTime / p.duration
            }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.isPlaying = false; self.progress = 0; self.timer?.invalidate() }
    }
}
