import Foundation
import Observation

/// A live WebSocket conversation with the library-level command Agent (Durable
/// Object behind wss://jianshuo.dev/agent/command). Unlike `ArticleAgentSession`
/// there's no single article/stem in view — instructions carry an explicit
/// numbered `refs` list (the on-screen article chips) so a spoken command like
/// "把第二篇和第三篇合并" tells the server which recordings it means. The SERVER
/// owns the durable queue; this client submits instructions (each with a stable
/// id), persists un-acked ones to disk, and reconciles against the server's
/// connect-time snapshot — so a dropped socket, a backgrounding, or an app-kill
/// never loses or double-applies a command.
@MainActor
@Observable
final class LibraryCommandSession: VoiceAgentSession {
    /// One entry in the numbered reference list shown alongside the mic (e.g.
    /// "1. 今天的会议记录  2. 周报草稿") so a spoken command can say "把第二篇…".
    struct CommandRef: Codable, Equatable {
        let n: Int
        let stem: String
        let title: String
    }

    var state: AgentState = .idle
    var error: String?

    /// Outstanding commands the user has spoken but the server hasn't confirmed
    /// done. Drives the stacked queue UI. The server is the real authority.
    /// Reuses `ArticleAgentSession.EditRequest` for the stacked-UI shape — these
    /// items are text-only; `articleIndex` is unused (always 0).
    var queue: [ArticleAgentSession.EditRequest] = []

    var onUpdate: ((ArticleDoc?) -> Void)?
    var onReply: ((String, Bool) -> Void)?
    /// Server wants the user to confirm a risky/ambiguous action before running
    /// it (e.g. deleting an article). UI should show a confirm card; respond
    /// with `confirm(id)` or `cancel(id)`.
    var onConfirm: ((_ id: String, _ summary: String) -> Void)?

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var closed = false
    private var refs: [CommandRef] = []

    private let base = API.agentWS + "/command"
    private var token: String { AuthStore.shared.bearer }
    /// Library commands aren't per-article; a single constant scope is enough
    /// until there's a real reason to split (e.g. per-account).
    private let scopeKey = "default"

    func connect() {
        closed = false
        // Restore any commands persisted before a previous kill (text-only).
        queue = CommandQueueStore.load(scope: scopeKey).map { ArticleAgentSession.EditRequest(id: $0.id, text: $0.text) }
        openSocket()
    }

    /// Set the current numbered reference list (the on-screen article chips) so
    /// the next `enqueue`/resend can tell the server which recordings a spoken
    /// command means.
    func setRefs(_ refs: [CommandRef]) {
        self.refs = refs
    }

    private func openSocket() {
        guard !token.isEmpty else { state = .error; error = "未登录"; return }
        state = queue.isEmpty ? .connecting : .working
        error = nil
        guard let url = URL(string: base) else { state = .error; return }
        var req = URLRequest(url: url)
        req.setBearer(token)
        let s = URLSession(configuration: .default)
        session = s
        let t = s.webSocketTask(with: req)
        task = t
        t.resume()
        receive()
        // Re-submit everything still outstanding. The server dedups by id, so a
        // resend of an already-done command just replays its result (no double-apply).
        resubmitAll()
    }

    /// Queue a spoken command (images/articleIndex are meaningless at library
    /// scope and ignored). Persist it, then send with the current refs.
    func enqueue(_ instruction: String, images: [AgentImage] = [], articleIndex: Int = 0) {
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let reqItem = ArticleAgentSession.EditRequest(text: text)
        queue.append(reqItem)
        persist()
        send(reqItem)
        state = .working
    }

    private func resubmitAll() {
        for item in queue { send(item) }
    }

    private func send(_ item: ArticleAgentSession.EditRequest) {
        let payload: [String: Any] = [
            "type": "instruct",
            "id": item.id,
            "text": item.text,
            "refs": refs.map { ["n": $0.n, "stem": $0.stem, "title": $0.title] }
        ]
        sendRaw(payload)
    }

    /// Approve a pending server-side confirmation (e.g. "yes, delete it").
    func confirm(_ id: String) {
        sendRaw(["type": "confirm", "id": id])
    }

    /// Reject a pending server-side confirmation.
    func cancel(_ id: String) {
        sendRaw(["type": "cancel", "id": id])
    }

    private func sendRaw(_ payload: [String: Any]) {
        guard let task else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let str = String(data: data, encoding: .utf8) else { return }
        task.send(.string(str)) { [weak self] err in
            guard err != nil else { return }
            // Send failed (socket mid-drop). Leave the item in the queue; the
            // reconnect path resubmits it. Surface nothing — not a user error.
            Task { @MainActor in self?.state = .working }
        }
    }

    /// Drop a finished command (by id) from the local queue + disk.
    private func resolve(_ id: String) {
        queue.removeAll { $0.id == id }
        persist()
        state = queue.isEmpty ? .idle : .working
    }

    private func persist() {
        let refsData = try? JSONEncoder().encode(refs)
        let refsJSON = refsData.flatMap { String(data: $0, encoding: .utf8) }
        CommandQueueStore.save(queue.map { PersistedCommand(id: $0.id, text: $0.text, refsJSON: refsJSON) }, scope: scopeKey)
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
        guard let any, let d = try? JSONSerialization.data(withJSONObject: any) else { return nil }
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
            // article may be null (e.g. after a library-wide refresh where
            // there's no single article to report back) — the UI just refreshes.
            onUpdate?(decodeDoc(obj["article"]))
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
        case "confirm":
            if let id, let summary = obj["summary"] as? String {
                onConfirm?(id, summary)
            }
        case "snapshot":
            reconcile(obj)
        default:
            break
        }
    }

    /// Reconcile the local queue against the server's authoritative snapshot.
    /// done → drop locally (apply the doc); pending/running → keep showing;
    /// anything the server doesn't know about → resend (we were killed before
    /// it landed). Always apply the snapshot's current article, if any.
    private func reconcile(_ obj: [String: Any]) {
        if let doc = decodeDoc(obj["article"]) { onUpdate?(doc) }
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
