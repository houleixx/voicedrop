import Foundation
import AVFoundation
import Observation

/// Wraps AVAudioRecorder. Records mono AAC into Documents/recording-<timestamp>.m4a,
/// exposes a live elapsed time, and handles audio-session interruptions
/// (e.g. an incoming call) by finalizing the current recording.
///
/// While recording, the file lives under a staging name (`recording-<ts>.m4a`)
/// that the upload queue does NOT match. At stop, ContentView promotes it to the
/// enriched `VoiceDrop-*.m4a` name (duration + weekday + place), and only then is
/// it eligible for upload. This prevents a concurrent drain from ever picking up
/// a half-written take (the cause of the moov-less / 0-byte corrupt uploads).
@MainActor
@Observable
final class AudioRecorder {

    /// A finished take, handed to ContentView for enrichment + upload.
    struct Recording: Sendable {
        let url: URL
        let start: Date
        let duration: TimeInterval
    }

    enum RecorderError: LocalizedError {
        case couldNotStart
        var errorDescription: String? { "无法开始录音" }
    }

    private(set) var isRecording = false
    private(set) var elapsed: TimeInterval = 0
    private(set) var level: Double = 0       // 0…1 live input level (for the waveform)

    private var recorder: AVAudioRecorder?
    private var currentURL: URL?
    /// The recording's start instant — the SINGLE source of truth for this
    /// session's timestamp. Both the audio filename (via `take.start`) and the
    /// photo folder key derive from this exact value, so they always match to the
    /// second. (Reading `Date()` separately for the photos drifted across a second
    /// boundary and broke the audio↔photo correlation.)
    private(set) var startDate: Date?
    private var tickTask: Task<Void, Never>?

    /// Called when a recording is finalized by an external interruption.
    var onInterrupted: ((Recording) -> Void)?

    init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: nil
        )
    }

    // MARK: - Permission

    static func ensurePermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        case .undetermined: return await AVAudioApplication.requestRecordPermission()
        @unknown default: return false
        }
    }

    static var isDenied: Bool {
        AVAudioApplication.shared.recordPermission == .denied
    }

    // MARK: - Recording

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.duckOthers])
        try session.setActive(true)

        let now = Date()
        let url = Self.stagingURL(start: now)
        // Encoder settings follow the user's 录音质量 pref (标准 64k / 高 96k).
        let rec = try AVAudioRecorder(url: url, settings: Prefs.shared.recorderSettings)
        rec.isMeteringEnabled = true
        guard rec.record() else { throw RecorderError.couldNotStart }

        recorder = rec
        currentURL = url
        startDate = now
        isRecording = true
        elapsed = 0
        startTicking()
    }

    /// Stops recording and returns the finished take (nil if not recording).
    @discardableResult
    func stop() -> Recording? {
        guard isRecording, let url = currentURL, let start = startDate else { return nil }
        recorder?.stop()
        recorder = nil
        stopTicking()
        isRecording = false
        level = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        let take = Recording(url: url, start: start, duration: elapsed)
        currentURL = nil
        startDate = nil
        return take
    }

    // MARK: - Interruption

    @objc private nonisolated func handleInterruption(_ note: Notification) {
        guard
            let info = note.userInfo,
            let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
            AVAudioSession.InterruptionType(rawValue: raw) == .began
        else { return }
        Task { @MainActor in
            if let take = self.stop() {
                self.onInterrupted?(take)
            }
        }
    }

    // MARK: - Ticking

    private func startTicking() {
        let start = startDate ?? Date()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self else { return }
                self.elapsed = Date().timeIntervalSince(start)
                if let r = self.recorder {
                    r.updateMeters()
                    let db = r.averagePower(forChannel: 0)        // ~ -60…0 dBFS
                    self.level = Double(max(0, min(1, (db + 50) / 50)))
                }
            }
        }
    }

    private func stopTicking() {
        tickTask?.cancel()
        tickTask = nil
    }

    // MARK: - File naming

    /// Staging name = recording-<start timestamp>.m4a. Deliberately NOT a
    /// `VoiceDrop-*` name, so the upload queue ignores it while it's being
    /// written. `ContentView.finalize` promotes it to the enriched VoiceDrop
    /// name once the recorder has closed the file.
    static let stagingPrefix = "recording-"

    static func stagingURL(start: Date) -> URL {
        let name = "\(stagingPrefix)\(RecordingName.timestamp(start)).m4a"
        return documentsDir.appending(path: name)
    }

    /// Discard any staging file left behind by an app kill mid-recording. Such a
    /// file was never finalized (no moov atom → unplayable), so it's safe to drop
    /// rather than promote it into the upload queue.
    static func cleanupStaleStaging() {
        let dir = documentsDir
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.lastPathComponent.hasPrefix(stagingPrefix) {
            try? FileManager.default.removeItem(at: f)
        }
    }

    static var documentsDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
}
