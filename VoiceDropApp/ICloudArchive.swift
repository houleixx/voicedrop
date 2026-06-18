import Foundation

/// Mirrors a finished recording into the app's iCloud container Documents
/// folder, so every take syncs to iCloud Drive and shows up under "VoiceDrop"
/// in the Files app — a durable personal copy independent of the upload.
///
/// Best-effort: if iCloud is unavailable (not signed in, no entitlement, e.g.
/// the Simulator), it silently no-ops. Runs off the main thread because the
/// first ubiquity-container lookup can block.
enum ICloudArchive {

    static func save(_ url: URL) {
        let fm = FileManager.default
        guard let container = fm.url(forUbiquityContainerIdentifier: nil) else { return }
        let docs = container.appendingPathComponent("Documents", isDirectory: true)
        do {
            try fm.createDirectory(at: docs, withIntermediateDirectories: true)
            let dest = docs.appendingPathComponent(url.lastPathComponent)
            if fm.fileExists(atPath: dest.path) {
                try? fm.removeItem(at: dest)
            }
            try fm.copyItem(at: url, to: dest)
        } catch {
            // best-effort — ignore failures
        }
    }
}
