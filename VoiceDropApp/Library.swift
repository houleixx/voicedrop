import Foundation
import Observation
import AVFoundation

// MARK: - Models

/// One mined article (v2 schema: many per recording).
struct MinedArticle: Decodable, Identifiable {
    let title: String
    let body: String
    var style: Int?                 // 文风版本 per-article 字段（legacy 文章在 body 注释里，读回退）
    var wechatMediaId: String?      // present once a WeChat draft has been created
    var id: String { title + "\(body.count)" }
}

/// One entry in a version history list returned by GET /articles/<stem>/history.
struct ArticleVersionEntry: Decodable {
    let v: Int
    let savedAt: Double?
    let source: String?
    let articles: [MinedArticle]
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
    /// Article tags (doc-level; written by voice tag_article or the .tags sidecar).
    let tags: [String]?
    /// Relative R2 keys for photos taken during this recording session.
    /// e.g. ["photos/2026-06-24-131500/23-k7p.jpg"]  (23 = 第23秒, k7p = 防撞随机尾)
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

/// A piece of an article body: a run of markdown text, or an inline photo,
/// parsed from `[[photo:<token>]]` markers inserted at the spot the scene is
/// described. The token is either a relative R2 key (new format, e.g.
/// `photos/…/….jpg`) or a 1-based index into the doc's `photos` array (legacy).
enum ArticleSegment: Identifiable {
    case text(String)
    case photo(String)   // raw marker token — resolve via ArticleBody.resolvePhotoKey
    var id: String {
        switch self {
        case .text(let s): return "t:\(s.count):\(s.prefix(12))"
        case .photo(let tok): return "p:\(tok)"
        }
    }
}

enum ArticleBody {
    // Token = anything but `]` — matches both a relative key and a legacy digit index.
    private static let marker = try! NSRegularExpression(pattern: #"\[\[photo:([^\]]+)\]\]"#)

    /// Resolve a photo marker token to a relative R2 key. New format: the token
    /// IS the key. Legacy format: a 1-based index into the doc's `photos` array.
    static func resolvePhotoKey(_ token: String, photos: [String]) -> String? {
        if let n = Int(token) {                                // legacy numeric index
            let idx = n - 1
            return (idx >= 0 && idx < photos.count) ? photos[idx] : nil
        }
        return token                                           // new format: token is the key
    }

    /// Split a body into text + photo segments at `[[photo:<token>]]` markers.
    /// The leading origin comment (`<!--风格vN-->`) is stripped first — it's a label, not content.
    static func segments(_ body: String) -> [ArticleSegment] {
        let body = stripOriginComment(body)
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
            out.append(.photo(ns.substring(with: m.range(at: 1))))
            cursor = m.range.location + m.range.length
        }
        if cursor < ns.length {
            let text = ns.substring(from: cursor).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { out.append(.text(text)) }
        }
        return out
    }

    /// Body with all `[[photo:N]]` markers AND the origin comment removed — for places
    /// that can't render the session photos (WeChat, the cross-user community, share excerpts).
    static func stripMarkers(_ body: String) -> String {
        let ns = stripOriginComment(body) as NSString
        let stripped = marker.stringByReplacingMatches(
            in: ns as String, range: NSRange(location: 0, length: ns.length), withTemplate: "")
        return stripped.replacingOccurrences(of: "\n\n\n", with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // LEGACY body comment protocol: `<!-- key: value -->`. The 文风版本 moved to the
    // per-article `style` FIELD (2026-07-03) — a hidden comment line desynced the 第N行
    // numbering between app and agent. Server-side migration stripped stored bodies;
    // these parsers remain as read fallback for stragglers, and stripOriginComment
    // stays so a comment can never reach any rendered surface.
    private static let metaComment = try! NSRegularExpression(pattern: #"<!--\s*([A-Za-z][\w-]*)\s*:\s*(.*?)\s*-->"#)
    private static let anyComment  = try! NSRegularExpression(pattern: #"<!--.*?-->"#, options: [.dotMatchesLineSeparators])

    /// Parse `<!-- key: value -->` comments into a dict (last value wins per key).
    static func meta(_ body: String) -> [String: String] {
        let ns = body as NSString
        var out: [String: String] = [:]
        for m in metaComment.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
            let k = ns.substring(with: m.range(at: 1))
            let v = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !v.isEmpty { out[k] = v }
        }
        return out
    }

    /// The `style` comment value (e.g. "风格 v8"), or nil. Legacy fallback only —
    /// the chip label itself is built by StyleNaming.chipLabel from the version number.
    static func styleLabel(_ body: String) -> String? { meta(body)["style"] }
    /// The 文风 version number tagged on a body's `style` comment (e.g. "风格 v8" → 8), or nil.
    static func styleVersion(_ body: String) -> Int? {
        guard let s = styleLabel(body), let r = s.range(of: #"\d+"#, options: .regularExpression) else { return nil }
        return Int(s[r])
    }

    /// Body with ALL `<!--…-->` comments removed (metadata, never shown).
    static func stripOriginComment(_ body: String) -> String {
        let ns = body as NSString
        return anyComment.stringByReplacingMatches(
            in: body, range: NSRange(location: 0, length: ns.length), withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Relative R2 key of the FIRST photo referenced in `body` (legacy numeric markers
    /// resolved via `photos`), or nil. Callers join their own scope/owner prefix and fetch.
    /// One place that knows "the first photo of an article" (was inlined in the own-article
    /// and community share paths).
    static func firstPhotoKey(in body: String, photos: [String]) -> String? {
        for seg in segments(body) {
            if case .photo(let token) = seg, let relKey = resolvePhotoKey(token, photos: photos) { return relKey }
        }
        return nil
    }

    /// Plain-text share body for one or more sections: markers stripped, multi-section
    /// titles bracketed, sections joined by a divider. The ONE share-text format every
    /// surface uses (own-article + community).
    static func shareText(_ articles: [MinedArticle]) -> String {
        let multi = articles.count > 1
        return articles.map { multi ? "【\($0.title)】\n\n\(stripMarkers($0.body))" : "\($0.title)\n\n\(stripMarkers($0.body))" }
            .joined(separator: "\n\n---\n\n")
    }
}

/// Which phase of mining a recording is in (pushed live by the Worker miner over
/// the status WebSocket). Drives the in-flight badge label.
enum MiningPhase: String { case asr, mining
    var badge: String { self == .asr ? "听录音" : "挖文章" }
}

/// Why the miner couldn't process a recording (the `.blocked` marker's reason). The
/// ONE place the wire strings + their badge labels live (was split between the default
/// in LibraryStore.fetchBlockReason and the label mapping in LibraryView).
enum BlockReason: String { case noCredit = "no-credit", tooLong = "too-long"
    var label: String { self == .tooLong ? "录音过长" : "余额不足" }
}

/// A recording as seen in the user's R2 space: the audio key plus whether the
/// miner has produced an article JSON for it yet.
struct Recording: Identifiable, Hashable {
    let audioName: String        // relative key, e.g. "VoiceDrop-….m4a"
    let uploaded: String
    let hasArticles: Bool
    let isEmpty: Bool            // a `articles/<stem>.empty` marker exists (no usable speech)
    var articleTitle: String?    // first mined article's title; fills the place slot once 已成文
    var tags: [String]?          // article tags (语音 tag_article 归类) — shown as small text under the meta line
    var coverPhotoKey: String?   // rel R2 key of the article's FIRST photo; shown as the row's left icon (nil → waveform)
    var uploading: Bool = false  // a local take still in the upload queue (not yet on the server)
    var phase: MiningPhase? = nil // server is actively mining this right now (WebSocket push); nil = not in-flight
    var blockReason: String? = nil   // "no-credit" | "too-long"; nil = not blocked

    var processing: Bool { phase != nil }

    var id: String { audioName }
    var stem: String { String(audioName.dropLast(4)) }          // strip .m4a
    var articleKey: String { Recording.articleKey(forStem: stem) }
    var emptyKey: String { Recording.emptyKey(forStem: stem) }
    var srtKey: String { Recording.srtKey(forStem: stem) }
    var blockedKey: String { Recording.blockedKey(forStem: stem) }

    // The article-sidecar key layout, defined ONCE. LibraryStore.load checks these
    // before a Recording exists, so they're static; the instance vars above delegate here.
    static func articleKey(forStem s: String) -> String { "articles/\(s).json" }
    static func emptyKey(forStem s: String)   -> String { "articles/\(s).empty" }
    static func srtKey(forStem s: String)     -> String { "articles/\(s).srt" }
    static func blockedKey(forStem s: String) -> String { "articles/\(s).blocked" }
    static func tagsKey(forStem s: String)    -> String { "articles/\(s).tags" }

    /// "6月18日 14:30 · Xuhui" style label — kept for detail views and export.
    var displayTitle: String {
        let dt = dateTimeLabel.map { $0 + " · " } ?? ""
        return dt + rowTitle
    }

    /// First line of a list row: article title when 已成文, place name otherwise, stem as fallback.
    var rowTitle: String {
        if let t = articleTitle, !t.isEmpty { return t }
        return RecordingName.parse(stem)?.place ?? stem
    }

    /// Second line of a list row: "6月18日 14:30" from the R2 upload time, shown in
    /// the device's LOCAL timezone (uploaded is ISO-8601 UTC). The filename's embedded
    /// timestamp isn't a reliable clock, so prefer `uploaded`; fall back to the name
    /// only when `uploaded` is missing/unparseable.
    var dateTimeLabel: String? {
        guard let d = Recording.uploadedDate(uploaded) else { return nameDateTimeLabel }
        // no timeZone → device local (UTC+8 for the user)
        return DateFormatter.zh("M月d日 HH:mm").string(from: d)
    }

    /// Legacy fallback: "6月18日 14:30" from the VoiceDrop-<ts>… filename (via RecordingName.parse).
    private var nameDateTimeLabel: String? {
        guard let p = RecordingName.parse(stem) else { return nil }
        var bits: [String] = []
        if let mo = p.month, let da = p.day { bits.append("\(mo)月\(da)日") }
        if let hhmm = p.hhmm { bits.append(hhmm) }
        return bits.isEmpty ? nil : bits.joined(separator: " ")
    }

    /// Parse R2's ISO-8601 `uploaded` (with or without fractional seconds) into a Date.
    /// Formatters are built per call, NOT static: ISO8601DateFormatter isn't Sendable, and a
    /// `static let` on this non-isolated struct fails Swift 6 strict-concurrency checks. This
    /// matches the codebase's other date parsing (RecordingName / Community build formatters locally).
    static func uploadedDate(_ s: String) -> Date? {
        guard !s.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: s)
    }

    /// THE single source of truth for recording list order: newest first.
    /// In-flight rows (uploading / just-uploaded — `uploaded` still "") are the newest
    /// and sort to the very top; everything else by R2 `uploaded` time descending (the
    /// filename is not a reliable clock), filename as a stable tiebreak.
    /// Sort in ONE place only (`LibraryStore.load`); never re-sort downstream.
    static func newestFirst(_ a: Recording, _ b: Recording) -> Bool {
        if a.uploaded.isEmpty != b.uploaded.isEmpty { return a.uploaded.isEmpty }
        return (a.uploaded, a.audioName) > (b.uploaded, b.audioName)
    }

    /// "0m33s"-style duration field if present.
    var durationLabel: String? { RecordingName.parse(stem)?.duration }
}

// MARK: - Store

@MainActor
@Observable
final class LibraryStore {
    var recordings: [Recording] = []
    var loading = false
    var error: String?
    var reminingStems: Set<String> = []   // stem 正在"重写"（复用已有 ASR、按原逻辑重挖）

    private let base = API.filesBase
    private var token: String { AuthStore.shared.bearer }
    private var titleCache: [String: String] = [:]   // articleKey -> first article title
    private var coverCache: [String: String] = [:]   // articleKey -> first-photo rel key ("" = article has none)
    private var tagsCache: [String: [String]] = [:]  // articleKey -> doc tags ([] = article has none)
    private var processingPhase: [String: MiningPhase] = [:]   // stem -> current mining phase (WebSocket)

    private struct ListResponse: Decodable {
        struct Item: Decodable { let name: String; let uploaded: String? }
        let files: [Item]
    }

    /// Called by StatusSession when the Worker miner signals a stem advanced to a phase (asr / mining).
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

    // Coalesced re-entrancy: load() has many triggers (foreground, pull, WS done,
    // voice-command update, upload drain) — two interleaved loads used to repaint
    // the list with un-enriched rows mid-flight. Now a load already running just
    // queues ONE follow-up pass.
    private var loadInFlight = false
    private var loadQueued = false

    func load() async {
        if loadInFlight { loadQueued = true; return }
        loadInFlight = true
        defer { loadInFlight = false }
        repeat {
            loadQueued = false
            await loadOnce()
        } while loadQueued
    }

    private func loadOnce() async {
        guard !token.isEmpty else { error = "请先登录"; return }
        loading = true; error = nil
        defer { loading = false }
        var req = URLRequest(url: base.appending(path: "list"))
        req.setBearer(token)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard resp.isOK else {
                error = "加载失败"; return
            }
            let list = try JSONDecoder().decode(ListResponse.self, from: data)
            let names = Set(list.files.map(\.name))
            let audios = list.files.filter {
                RecordingName.isRecordingFile($0.name.components(separatedBy: "/").last ?? $0.name)
            }
            var next = audios.map {
                let stem = String($0.name.dropLast(4))
                return Recording(audioName: $0.name,
                                 uploaded: $0.uploaded ?? "",
                                 hasArticles: names.contains(Recording.articleKey(forStem: stem)),
                                 isEmpty: names.contains(Recording.emptyKey(forStem: stem)))
            }
            // The ONE place recordings get ordered — newest first. Every consumer
            // (LibraryView, ExportSheet) reads this order; nobody re-sorts. See Recording.newestFirst.
            .sorted(by: Recording.newestFirst)

            // Re-apply in-flight processing state from WebSocket, and prune stems
            // that are now done (article or empty marker already landed in R2).
            for i in next.indices {
                let stem = next[i].stem
                if let ph = processingPhase[stem] {
                    if next[i].hasArticles || next[i].isEmpty {
                        processingPhase[stem] = nil   // done — clear the in-flight marker
                    } else {
                        next[i].phase = ph
                    }
                }
            }

            // Apply EVERY cached enrichment (title / cover / tags) BEFORE publishing
            // the new array. The tag tabs derive from recordings' tags — publishing
            // un-enriched rows made allTags transiently empty on every reload, which
            // bounced the user off the tag page they were on.
            for i in next.indices where next[i].hasArticles {
                next[i].articleTitle = titleCache[next[i].articleKey]
                next[i].coverPhotoKey = coverCache[next[i].articleKey].flatMap { $0.isEmpty ? nil : $0 }
                next[i].tags = tagsCache[next[i].articleKey].flatMap { $0.isEmpty ? nil : $0 }
            }
            recordings = next

            // ── Async late enrichment (in place, after publish) ──────────────────

            // Fetch block reasons (.blocked marker) for recordings the worker couldn't mine.
            // .json / .empty take precedence — only fetch when neither is present.
            for i in recordings.indices {
                guard !recordings[i].hasArticles, !recordings[i].isEmpty,
                      names.contains(recordings[i].blockedKey) else { continue }
                recordings[i].blockReason = await fetchBlockReason(recordings[i].stem)
            }

            // A recording still mining may carry a pending .tags sidecar (recorded
            // on a tag page) — read it so the row stays on that tag's page through
            // 待处理→挖矿中, not only after 成文. Sidecars are rare (≤ the takes
            // currently in flight), so the extra fetches are ~zero on most loads.
            for i in recordings.indices {
                let tagsKey = Recording.tagsKey(forStem: recordings[i].stem)
                guard !recordings[i].hasArticles, names.contains(tagsKey) else { continue }
                if let data = try? await get(tagsKey),
                   let tags = try? JSONDecoder().decode([String].self, from: data), !tags.isEmpty {
                    recordings[i].tags = tags
                }
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
        // One doc fetch fills BOTH the title and the first-photo cover icon.
        // cover "" = the article has no photo (cache it so we don't refetch).
        let found = await withTaskGroup(of: (String, String, String, [String]).self) { group -> [(String, String, String, [String])] in
            for rec in pending {
                group.addTask {
                    guard let doc = await self.fetchDoc(rec), let art = doc.resolvedArticles.first else { return (rec.id, "", "", []) }
                    let cover = ArticleBody.firstPhotoKey(in: art.body, photos: doc.photos ?? []) ?? ""
                    return (rec.id, art.title, cover, doc.tags ?? [])
                }
            }
            var out: [(String, String, String, [String])] = []
            for await t in group where !t.1.isEmpty { out.append(t) }
            return out
        }
        for (id, title, cover, tags) in found {
            if let idx = recordings.firstIndex(where: { $0.id == id }) {
                recordings[idx].articleTitle = title
                titleCache[recordings[idx].articleKey] = title
                recordings[idx].coverPhotoKey = cover.isEmpty ? nil : cover
                coverCache[recordings[idx].articleKey] = cover
                recordings[idx].tags = tags.isEmpty ? nil : tags
                tagsCache[recordings[idx].articleKey] = tags
            }
        }
    }

    /// Voice-command completion: the server's `updated` push names exactly which
    /// stems the command touched — drop those rows' caches so the next load
    /// refetches their docs (title, cover and tags move together).
    func invalidateArticleCaches(stems: [String]) {
        for stem in stems {
            let key = Recording.articleKey(forStem: stem)
            titleCache[key] = nil; coverCache[key] = nil; tagsCache[key] = nil
        }
    }

    private func downloadURL(_ relName: String) -> URL {
        let enc = relName.urlPathEncoded
        return URL(string: "\(base.absoluteString)/download/\(enc)")!
    }

    private func get(_ relName: String) async throws -> Data {
        var req = URLRequest(url: downloadURL(relName))
        req.setBearer(token)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard resp.isOK else {
            throw NSError(domain: "library", code: 1, userInfo: [NSLocalizedDescriptionKey: "下载失败"])
        }
        return data
    }

    /// Fetch the mined article document for a recording (nil if not mined yet).
    /// Uses the articles API (not raw download) so schema-3 docs get their current
    /// head version's articles reconstructed at the top level.
    func fetchDoc(_ rec: Recording) async -> ArticleDoc? {
        guard rec.hasArticles, !token.isEmpty else { return nil }
        let enc = rec.stem.urlPathEncoded
        guard let url = URL(string: "\(base.absoluteString)/articles/\(enc)") else { return nil }
        var req = URLRequest(url: url)
        req.setBearer(token)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard resp.isOK else { return nil }
            return try JSONDecoder().decode(ArticleDoc.self, from: data)
        } catch { return nil }
    }

    /// Fetch the human-readable reason from a `.empty` marker (silent / corrupt /
    /// no-speech). Returns nil if the marker is missing or unreadable.
    func fetchEmptyReason(_ rec: Recording) async -> String? {
        guard rec.isEmpty else { return nil }
        struct EmptyMarker: Decodable { let reason: String? }
        do { return try JSONDecoder().decode(EmptyMarker.self, from: await get(rec.emptyKey)).reason }
        catch { return nil }
    }

    /// Fetch the reason from a `.blocked` marker (no-credit / too-long). Defaults to
    /// "no-credit" on any fetch or parse failure so callers always get a non-nil String.
    private func fetchBlockReason(_ stem: String) async -> String {
        guard let data = try? await get(Recording.blockedKey(forStem: stem)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return BlockReason.noCredit.rawValue }
        return obj["reason"] as? String ?? BlockReason.noCredit.rawValue
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
    /// the audio, then kick the miner so it re-mines this recording right away
    /// (the marker is gone → the miner treats it as unprocessed). The row flips back
    /// to 待处理 → 听录音 → 挖文章 → 已成文 with fresh content. Reloads to reflect state.
    @discardableResult
    func deleteArticle(_ rec: Recording) async -> Bool {
        guard !token.isEmpty else { error = "请先登录"; return false }
        _ = await del(rec.articleKey)
        _ = await del(rec.srtKey)
        _ = await del(rec.emptyKey)
        titleCache[rec.articleKey] = nil   // re-mined article may have a new title
        coverCache[rec.articleKey] = nil   // …and a different (or no) first photo
        tagsCache[rec.articleKey] = nil    // …and tags travel with the doc
        await dispatchMine()               // trigger a fresh mine cycle now
        await load()
        return true
    }

    /// Kick the server article miner (POST /mine → dispatches the mine.yml
    /// workflow). Best-effort — the recording is already back to unprocessed, so
    /// even if this fails the next upload-triggered cycle will pick it up.
    private func dispatchMine() async {
        guard let url = URL(string: "\(base.absoluteString)/mine") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setBearer(token)
        _ = try? await URLSession.shared.data(for: req)
    }

    /// DELETE one key. Treats 2xx and 404 as success (idempotent).
    private func del(_ relName: String) async -> Bool {
        let enc = relName.urlPathEncoded
        guard let url = URL(string: "\(base.absoluteString)/file/\(enc)") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setBearer(token)
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let code = resp.httpStatusCode
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
        req.setBearer(token)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard resp.isOK else { return nil }
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
        req.setBearer(token)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = resp.httpStatusCode
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

    /// Re-mine this article with 文风 version `styleV` (POST /agent/restyle). Server writes
    /// a new tagged article version and moves head; returns the new head, nil on failure.
    /// Caller only invokes this when that variant isn't already in versions[] (else patchHead).
    func restyle(_ rec: Recording, styleV: Int) async -> Int? {
        guard !token.isEmpty, let url = URL(string: "\(API.agentBase.absoluteString)/restyle") else { return nil }
        struct Req: Encodable { let stem: String; let styleV: Int }
        struct Resp: Decodable { let ok: Bool; let head: Int? }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setBearer(token)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(Req(stem: rec.stem, styleV: styleV))
        req.timeoutInterval = 120   // a mine LLM call can take a while
        guard let (data, resp) = try? await URLSession.shared.data(for: req), resp.isOK,
              let r = try? JSONDecoder().decode(Resp.self, from: data), r.ok else { return nil }
        return r.head
    }

    /// 小红书内容包：把这篇文章转成小红书笔记文案 + 配图 key 列表（POST /agent/xhs-pack）。
    /// 发布动作在客户端完成：文案进剪贴板、配图走 ShareSheet，用户在小红书里粘贴发布。
    struct XHSPack: Decodable {
        let title: String
        let body: String
        let tags: [String]
        let photoKeys: [String]
        /// 剪贴板全文：标题 + 正文 + #标签行。
        var clipboardText: String {
            let tagLine = tags.isEmpty ? "" : "\n\n" + tags.map { "#\($0)" }.joined(separator: " ")
            return title + "\n\n" + body + tagLine
        }
    }
    func xhsPack(_ rec: Recording) async -> XHSPack? {
        guard !token.isEmpty, rec.hasArticles,
              let url = URL(string: "\(API.agentBase.absoluteString)/xhs-pack") else { return nil }
        struct Req: Encodable { let stem: String }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setBearer(token)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(Req(stem: rec.stem))
        req.timeoutInterval = 120   // one LLM rewrite call
        guard let (data, resp) = try? await URLSession.shared.data(for: req), resp.isOK else { return nil }
        return try? JSONDecoder().decode(XHSPack.self, from: data)
    }

    /// 重写：复用已有 ASR，按原挖矿逻辑用当前文风重挖（POST /agent/restyle {stem}，不带 styleV →
    /// 服务端用文风 head，可重新拆多篇）。写文章新版本、转写不动。期间标记 reminingStems，成功后刷新。
    func remine(_ rec: Recording) async {
        guard !token.isEmpty, rec.hasArticles,
              let url = URL(string: "\(API.agentBase.absoluteString)/restyle") else { return }
        struct Req: Encodable { let stem: String }
        struct Resp: Decodable { let ok: Bool; let head: Int? }
        reminingStems.insert(rec.stem)
        defer { reminingStems.remove(rec.stem) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setBearer(token)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONEncoder().encode(Req(stem: rec.stem))
        req.timeoutInterval = 120   // opus 重挖可能要几十秒
        guard let (data, resp) = try? await URLSession.shared.data(for: req), resp.isOK,
              let r = try? JSONDecoder().decode(Resp.self, from: data), r.ok else {
            error = "重写失败"
            return
        }
        titleCache[rec.articleKey] = nil   // 标题可能变
        coverCache[rec.articleKey] = nil   // 首图也可能变
        tagsCache[rec.articleKey] = nil    // 标签随 doc 走，一起重拉
        await load()
    }

    /// Upload a square JPEG to the user's photo folder and return the relative key.
    func uploadPhoto(data: Data, sessionTs: String, offset: Int) async -> String? {
        await PhotoService.upload(data: data,
                                  relKey: RecordingName.photoKey(sessionTs: sessionTs, offset: offset),
                                  bearer: token)
    }

    struct VersionHistory {
        let versions: [ArticleVersionEntry]   // oldest-first
        let head: Int
    }

    /// Fetch the full version history for an article (schema-3: {head, versions}).
    func fetchVersionHistory(_ rec: Recording) async -> VersionHistory {
        guard !token.isEmpty, rec.hasArticles else { return VersionHistory(versions: [], head: 0) }
        struct Resp: Decodable { let head: Int; let versions: [ArticleVersionEntry] }
        let enc = rec.stem.urlPathEncoded
        guard let url = URL(string: "\(base.absoluteString)/articles/\(enc)/history") else { return VersionHistory(versions: [], head: 0) }
        var req = URLRequest(url: url)
        req.setBearer(token)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard resp.isOK else { return VersionHistory(versions: [], head: 0) }
            guard let r = try? JSONDecoder().decode(Resp.self, from: data) else { return VersionHistory(versions: [], head: 0) }
            return VersionHistory(versions: r.versions, head: r.head)
        } catch { return VersionHistory(versions: [], head: 0) }
    }

    /// Move the head pointer on the server (undo/redo sync). Fire-and-forget: returns
    /// immediately after sending so the caller can update UI without waiting.
    func patchHead(_ rec: Recording, head: Int) async {
        guard !token.isEmpty, rec.hasArticles else { return }
        let enc = rec.stem.urlPathEncoded
        guard let url = URL(string: "\(base.absoluteString)/articles/\(enc)/head"),
              let body = try? JSONEncoder().encode(["head": head]) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "PATCH"
        req.setBearer(token)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        _ = try? await URLSession.shared.data(for: req)
    }

    /// Download raw data for any relative key (used by ExportManager).
    func downloadData(_ relName: String) async throws -> Data { try await get(relName) }

    private var cachedScope: String?

    /// The caller's data scope ("users/<sub>/"), fetched once via `/whoami` and cached.
    /// Lets the app build a full R2 key (scope + relKey) for its own photos so they load
    /// from the same public `/photo/<key>` endpoint the community + share pages use.
    func ownerScope() async -> String? {
        if let cachedScope { return cachedScope }
        guard !token.isEmpty, let url = URL(string: "\(base.absoluteString)/whoami") else { return nil }
        var req = URLRequest(url: url)
        req.setBearer(token)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard resp.isOK else { return nil }
            struct R: Decodable { let scope: String? }
            let s = (try? JSONDecoder().decode(R.self, from: data))?.scope
            if let s, !s.isEmpty { cachedScope = s }
            return cachedScope
        } catch { return nil }
    }

    /// Download a photo by its full R2 key via the public `/photo/<key>` endpoint
    /// (no auth — the one photo URL shared by the community + web pages).
    func photoData(fullKey: String) async -> Data? { await PhotoService.data(fullKey: fullKey) }

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
