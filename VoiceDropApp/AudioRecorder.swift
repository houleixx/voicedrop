import Foundation
import AVFoundation
import Observation

/// Wraps AVAudioRecorder. Records mono AAC into Documents/VoiceDrop-<timestamp>.m4a,
/// exposes a live elapsed time, and handles audio-session interruptions
/// (e.g. an incoming call) by finalizing the current recording.
@MainActor
@Observable
final class AudioRecorder {

    enum RecorderError: LocalizedError {
        case couldNotStart
        var errorDescription: String? { "无法开始录音" }
    }

    private(set) var isRecording = false
    private(set) var elapsed: TimeInterval = 0

    private var recorder: AVAudioRecorder?
    private var currentURL: URL?
    private var tickTask: Task<Void, Never>?
    private var startDate: Date?

    /// Called when a recording is finalized by an external interruption.
    /// ContentView sets this so it can kick off the upload.
    var onInterrupted: ((URL) -> Void)?

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

        let url = Self.makeFileURL()
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            AVEncoderBitRateKey: 64_000,
        ]
        let rec = try AVAudioRecorder(url: url, settings: settings)
        guard rec.record() else { throw RecorderError.couldNotStart }

        recorder = rec
        currentURL = url
        isRecording = true
        startDate = Date()
        elapsed = 0
        startTicking()
    }

    /// Stops recording and returns the finished file URL (nil if not recording).
    @discardableResult
    func stop() -> URL? {
        guard isRecording else { return nil }
        recorder?.stop()
        recorder = nil
        stopTicking()
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        let url = currentURL
        currentURL = nil
        startDate = nil
        return url
    }

    // MARK: - Interruption

    @objc private nonisolated func handleInterruption(_ note: Notification) {
        guard
            let info = note.userInfo,
            let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
            AVAudioSession.InterruptionType(rawValue: raw) == .began
        else { return }
        Task { @MainActor in
            if let url = self.stop() {
                self.onInterrupted?(url)
            }
        }
    }

    // MARK: - Ticking

    private func startTicking() {
        let start = startDate ?? Date()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                self?.elapsed = Date().timeIntervalSince(start)
            }
        }
    }

    private func stopTicking() {
        tickTask?.cancel()
        tickTask = nil
    }

    // MARK: - File naming

    static func makeFileURL() -> URL {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd-HHmmss"
        let name = "VoiceDrop-\(fmt.string(from: Date())).m4a"
        return documentsDir.appending(path: name)
    }

    static var documentsDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
}
