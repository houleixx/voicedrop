import Foundation
import Observation

/// Uploads recordings to jianshuo.dev/files via the R2-backed PUT API.
/// The Documents directory IS the pending queue: a `VoiceDrop-*.m4a` file that
/// still exists has not been uploaded. On success the file is deleted.
@MainActor
@Observable
final class Uploader {

    private(set) var pendingCount: Int = 0
    private(set) var lastError: String?

    /// Base URL is public (not a secret), so it's hardcoded.
    private let baseURL = URL(string: "https://jianshuo.dev/files/api")!

    /// Token is injected via Secrets.xcconfig -> Info.plist -> here.
    private var token: String {
        (Bundle.main.object(forInfoDictionaryKey: "FILES_TOKEN") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    var hasValidToken: Bool { !token.isEmpty && token != "REPLACE_ME" }

    init() { refreshPending() }

    // MARK: - Queue

    func pendingFiles() -> [URL] {
        let dir = AudioRecorder.documentsDir
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.lastPathComponent.hasPrefix("VoiceDrop-") && $0.pathExtension == "m4a" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func refreshPending() { pendingCount = pendingFiles().count }

    // MARK: - Upload

    /// Uploads one file. Returns true and deletes the file on success.
    @discardableResult
    func upload(_ url: URL) async -> Bool {
        guard hasValidToken else {
            lastError = "缺少 FILES_TOKEN（请填 Secrets.xcconfig）"
            return false
        }
        let endpoint = baseURL
            .appending(path: "upload")
            .appending(path: url.lastPathComponent)
        var req = URLRequest(url: endpoint)
        req.httpMethod = "PUT"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("audio/mp4", forHTTPHeaderField: "Content-Type")

        do {
            let (_, resp) = try await URLSession.shared.upload(for: req, fromFile: url)
            guard let http = resp as? HTTPURLResponse else {
                lastError = "无响应"
                return false
            }
            guard (200..<300).contains(http.statusCode) else {
                lastError = http.statusCode == 401 || http.statusCode == 403
                    ? "token 失效（HTTP \(http.statusCode)）"
                    : "上传失败 HTTP \(http.statusCode)"
                return false
            }
            try? FileManager.default.removeItem(at: url)
            lastError = nil
            refreshPending()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Uploads every pending file in order. Returns true if the queue is empty
    /// afterwards (everything uploaded).
    @discardableResult
    func drainPending() async -> Bool {
        for file in pendingFiles() {
            if await upload(file) == false { break }
        }
        refreshPending()
        return pendingCount == 0
    }
}
