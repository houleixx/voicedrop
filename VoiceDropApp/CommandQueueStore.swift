import Foundation

/// One pending library-level command instruction, persisted so an app-kill can
/// resume it. Text-only, like `PersistedEdit`, but there's no single article in
/// view here — no `articleIndex` — and instead we keep the numbered `refs` list
/// (JSON-encoded) that was in effect when the user spoke, so a resumed command
/// still resolves "第二篇" to the same stem it meant originally.
struct PersistedCommand: Codable, Equatable {
    let id: String
    let text: String
    let refsJSON: String?
}

/// Disk mirror of the library-level command queue (UserDefaults, keyed by
/// scope). The server is the source of truth; this only survives the gap
/// between "user spoke" and "server acked", so a kill in that window still
/// resumes. Library commands aren't per-article, so callers without a natural
/// scope key can pass the shared `"default"` constant.
enum CommandQueueStore {
    private static func key(_ scope: String) -> String { "commandQueue.\(scope)" }

    static func load(scope: String) -> [PersistedCommand] {
        guard let data = UserDefaults.standard.data(forKey: key(scope)),
              let items = try? JSONDecoder().decode([PersistedCommand].self, from: data) else { return [] }
        return items
    }

    static func save(_ items: [PersistedCommand], scope: String) {
        if items.isEmpty { clear(scope: scope); return }
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: key(scope))
        }
    }

    static func clear(scope: String) {
        UserDefaults.standard.removeObject(forKey: key(scope))
    }
}
