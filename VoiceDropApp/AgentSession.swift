import Foundation
import Observation

enum AgentState: Equatable { case idle, connecting, working, error }

/// A 320×320 thumbnail sent alongside a voice instruction so the model can see
/// the image and decide where to place it.
struct AgentImage: Equatable {
    let key: String
    let base64: String
}

/// A live WebSocket conversation with the article-editing Agent (Durable Object
/// behind wss://jianshuo.dev/agent/edit). The SERVER owns the durable queue; this
/// client submits instructions (each with a stable id), persists un-acked ones to
/// disk, and reconciles against the server's connect-time snapshot — so a dropped
/// socket, a backgrounding, or an app-kill never loses or double-applies an edit.
@MainActor
@Observable
final class ArticleAgentSession: VoiceAgentSession {
    struct EditRequest: Identifiable, Equatable {
        let id: String          // stable across reconnects/relaunches (sent on the wire)
        let text: String
        let images: [AgentImage]
        let articleIndex: Int   // which article (chip) was on screen — locator targeting
        init(id: String = UUID().uuidString, text: String, images: [AgentImage] = [], articleIndex: Int = 0) {
            self.id = id; self.text = text; self.images = images; self.articleIndex = articleIndex
        }
    }

    var state: AgentState = .idle
    var error: String?

    /// Outstanding edits the user has spoken but the server hasn't confirmed
    /// done. Drives the stacked queue UI. The server is the real authority.
    var queue: [EditRequest] = []

    var onUpdate: ((ArticleDoc?, [String]) -> Void)?
    var onReply: ((String, Bool) -> Void)?

    /// 实时预览（换风格/重写/语音整篇改写）：服务端边生成边推的纯文本增量。
    /// a = 文章下标，field = "title" | "body"。
    struct PreviewDelta: Equatable { let a: Int; let field: String; let text: String }
    var onPreview: (([PreviewDelta]) -> Void)?
    var onPreviewReset: (() -> Void)?
    var onPreviewDone: ((Bool) -> Void)?

    /// 行级语音编辑的打字机流：i = 本轮第几个操作，op = replace_line/insert_after/set_title，
    /// line = 目标行号（set_title 为 nil），text = 新文本增量。
    struct EditDelta: Equatable { let i: Int; let op: String; let line: Int?; let text: String }
    var onEditPreview: (([EditDelta]) -> Void)?

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var rec: Recording?
    private var closed = false

    private let base = API.agentWS + "/edit"
    private var token: String { AuthStore.shared.bearer }
    private var stem: String { rec?.stem ?? "" }

    func connect(_ rec: Recording) {
        self.rec = rec
        closed = false
        // Restore any edits persisted before a previous kill (text-only).
        queue = EditQueueStore.load(stem: rec.stem).map { EditRequest(id: $0.id, text: $0.text, articleIndex: $0.articleIndex ?? 0) }
        openSocket()
    }

    private func openSocket() {
        guard let rec, !token.isEmpty else { state = .error; error = "未登录"; return }
        state = queue.isEmpty ? .connecting : .working
        error = nil
        let stem = rec.stem.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? rec.stem
        guard let url = URL(string: "\(base)?stem=\(stem)") else { state = .error; return }
        var req = URLRequest(url: url)
        req.setBearer(token)
        let s = URLSession(configuration: .default)
        session = s
        let t = s.webSocketTask(with: req)
        task = t
        t.resume()
        receive()
        // Re-submit everything still outstanding. The server dedups by id, so a
        // resend of an already-done edit just replays its result (no double-apply).
        resubmitAll()
    }

    /// Queue a spoken instruction (optionally with photos). Persist it, then send.
    func enqueue(_ instruction: String, images: [AgentImage] = [], articleIndex: Int = 0) {
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let reqItem = EditRequest(text: text, images: images, articleIndex: articleIndex)
        queue.append(reqItem)
        persist()
        send(reqItem)
        state = .working
    }

    private func resubmitAll() {
        for item in queue { send(item) }
    }

    private func send(_ item: EditRequest) {
        guard let task else { return }
        var payload: [String: Any] = ["type": "instruct", "id": item.id, "text": item.text, "articleIndex": item.articleIndex]
        if !item.images.isEmpty {
            payload["images"] = item.images.map { ["key": $0.key, "data": $0.base64, "mediaType": "image/jpeg"] }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let str = String(data: data, encoding: .utf8) else { return }
        task.send(.string(str)) { [weak self] err in
            guard err != nil else { return }
            // Send failed (socket mid-drop). Leave the item in the queue; the
            // reconnect path resubmits it. Surface nothing — not a user error.
            Task { @MainActor in self?.state = .working }
        }
    }

    /// Drop a finished edit (by id) from the local queue + disk.
    private func resolve(_ id: String) {
        queue.removeAll { $0.id == id }
        persist()
        state = queue.isEmpty ? .idle : .working
    }

    private func persist() {
        EditQueueStore.save(queue.map { PersistedEdit(id: $0.id, text: $0.text, articleIndex: $0.articleIndex) }, stem: stem)
    }

    private func receive() {
        task?.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .failure:
                    if !self.closed { self.reconnect() }
                case .success(let message):
                    switch message {
                    case .string(let str): self.handle(str)
                    case .data(let d): if let str = String(data: d, encoding: .utf8) { self.handle(str) }
                    @unknown default: break
                    }
                    self.receive()
                }
            }
        }
    }

    private func decodeDoc(_ any: Any?) -> ArticleDoc? {
        // A JSON-null `article` arrives as NSNull (non-nil but not a valid top-level
        // JSON object); `data(withJSONObject:)` would throw an ObjC exception `try?`
        // can't catch → abort(). Gate on isValidJSONObject first. (See the same fix
        // in LibraryCommandSession.decodeDoc — the library path hits null far more.)
        guard let any, JSONSerialization.isValidJSONObject(any),
              let d = try? JSONSerialization.data(withJSONObject: any) else { return nil }
        return try? JSONDecoder().decode(ArticleDoc.self, from: d)
    }

    private func handle(_ str: String) {
        guard let data = str.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
        let id = obj["id"] as? String
        switch type {
        case "status":
            if (obj["state"] as? String) == "working" { state = .working }
        case "updated":
            if let doc = decodeDoc(obj["article"]) { onUpdate?(doc, (obj["stems"] as? [String]) ?? []) }
            if let id { resolve(id) } else if !queue.isEmpty { resolve(queue[0].id) } // old-server fallback
        case "reply":
            if let text = obj["text"] as? String, !text.isEmpty {
                onReply?(text, obj["ok"] as? Bool ?? true)
            }
        case "error":
            let msg = (obj["message"] as? String) ?? "出错了"
            error = msg
            onReply?(msg, false)
            if let id { resolve(id) } else if !queue.isEmpty { resolve(queue[0].id) }
            if queue.isEmpty { state = .error }
        case "snapshot":
            reconcile(obj)
        case "preview-delta":
            let deltas = ((obj["items"] as? [[String: Any]]) ?? []).compactMap { it -> PreviewDelta? in
                guard let a = it["a"] as? Int, let f = it["field"] as? String, let t = it["text"] as? String else { return nil }
                return PreviewDelta(a: a, field: f, text: t)
            }
            if !deltas.isEmpty { onPreview?(deltas) }
        case "preview-reset":
            onPreviewReset?()
        case "preview-done":
            onPreviewDone?(obj["ok"] as? Bool ?? true)
        case "edit-preview":
            let deltas = ((obj["items"] as? [[String: Any]]) ?? []).compactMap { it -> EditDelta? in
                guard let i = it["i"] as? Int, let op = it["op"] as? String, let t = it["text"] as? String else { return nil }
                return EditDelta(i: i, op: op, line: it["line"] as? Int, text: t)
            }
            if !deltas.isEmpty { onEditPreview?(deltas) }
        default:
            break
        }
    }

    /// Reconcile the local queue against the server's authoritative snapshot.
    /// done → drop locally (apply the doc); pending/running → keep showing;
    /// anything the server doesn't know about → resend (we were killed before
    /// it landed). Always apply the snapshot's current article.
    private func reconcile(_ obj: [String: Any]) {
        if let doc = decodeDoc(obj["article"]) { onUpdate?(doc, (obj["stems"] as? [String]) ?? []) }
        let serverItems = (obj["queue"] as? [[String: Any]]) ?? []
        var serverStatus: [String: String] = [:]
        for it in serverItems { if let sid = it["id"] as? String, let st = it["status"] as? String { serverStatus[sid] = st } }
        for item in queue {
            switch serverStatus[item.id] {
            case "done": resolve(item.id)
            case "pending", "running": break          // in flight on the server; keep it shown
            case "error": resolve(item.id)
            default: send(item)                        // server never saw it → resend
            }
        }
        state = queue.isEmpty ? .idle : .working
    }

    private func reconnect() {
        guard !closed else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if !self.closed { self.openSocket() }
        }
    }

    /// Close the socket but KEEP the queue (persisted). Called on a transient
    /// disappear (navigation away / backgrounding). The next connect resumes.
    func disconnect() {
        closed = true
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        state = queue.isEmpty ? .idle : .working
        // queue + disk intentionally preserved.
    }
}
