import Foundation
@preconcurrency import AVFoundation
import Observation

/// AVAudioEngine recording backend, used ONLY in realtime (AI) mode. Produces a
/// valid AAC mono `recording-<ts>.m4a` (same staging name as `AudioRecorder`), so
/// promote/upload downstream is unchanged. Additionally:
///   • tees the mic PCM (resampled to 24 kHz Int16) to `onPCM` for the AI uplink,
///   • plays AI audio via a separate playback engine's `AVAudioPlayerNode`.
///
/// NO acoustic echo cancellation (AEC): enabling `setVoiceProcessingEnabled` silently
/// killed the input tap on device (tap 0 buffers). Without AEC the AI's loudspeaker
/// leaks into the recording → USE EARPHONES for a clean take. (AEC to be revisited.)
///
/// TWO engines: a capture-only engine (tap identical to VoiceEdit — proven to deliver
/// buffers) + a separate playback-only engine. A single full-duplex engine left the
/// input un-pulled (tap 0). The mic tap uses the input node's NATIVE format (format: nil).
///
/// KNOWN LIMITATIONS (deferred, tracked): the hand-rolled resampler resets phase per
/// buffer — exact for the 48 kHz built-in mic (2:1 → 24 kHz) but imprecise for 44.1 kHz
/// / Bluetooth routes; switch to a persistent `AVAudioConverter` when supporting those.
/// The tap does file-write + resample synchronously on the audio thread and hops to the
/// main actor per buffer — fine for built-in mic; move to a serial audio queue if it
/// causes jitter. Only `interruptionNotification` is handled (no route-change / media-
/// services-reset recovery yet).
///
/// The tap runs on a realtime audio thread (NOT main actor): the file write + resample
/// live in a `@unchecked Sendable` `Sink` (mirrors `VoiceEdit`'s `VolcAudioStreamer`).
@MainActor
@Observable
final class EngineRecorder: RecordingBackend {
    private(set) var isRecording = false
    private(set) var elapsed: TimeInterval = 0
    private(set) var level: Double = 0
    private(set) var startDate: Date?
    var onInterrupted: ((AudioRecorder.Recording) -> Void)?

    // On-screen diagnostics (shown in realtime mode) — turns "doesn't work" into data.
    private(set) var tapBuffers = 0        // mic buffers that reached the tap (0 = tap dead)
    private(set) var engineError: String?  // any capture/file error

    /// Mic PCM teed for the AI uplink: mono Int16 little-endian @ 24 kHz.
    var onPCM: ((Data) -> Void)?

    static let aiRate: Double = 24_000
    /// Fixed format for AI playback buffers; the engine mixer resamples to hardware.
    nonisolated static let aiFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                    sampleRate: 24_000, channels: 1, interleaved: false)!

    // TWO separate engines. A single full-duplex engine (input tap + output player)
    // left the input side un-pulled → tap 0 buffers on device. Splitting into a
    // capture-only engine (identical to VoiceEdit's proven pattern) + a playback-only
    // engine makes each single-purpose and reliable. They share one AVAudioSession.
    private let captureEngine = AVAudioEngine()
    private let playbackEngine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var playbackStarted = false     // playback engine starts LAZILY on first AI audio
    private var sink: Sink?
    private var currentURL: URL?
    private var startInstant: Date?
    private var tickTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?   // recovers the cold-start "first entry" miss

    init() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification, object: nil)
    }

    static func ensurePermission() async -> Bool { await AudioRecorder.ensurePermission() }

    func start() throws {
        // Reset diagnostics FIRST so a playback-start failure below stays visible
        // (previously a trailing `engineError = nil` wiped it — real bug).
        tapBuffers = 0
        engineError = nil

        var tapInstalled = false
        var captureStarted = false
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.duckOthers, .defaultToSpeaker])
            try session.setActive(true)

            let now = Date()
            let url = AudioRecorder.stagingURL(start: now)
            // Sink creates the AAC file LAZILY from the first buffer's own format.
            let s = Sink(url: url, aiRate: EngineRecorder.aiRate)
            s.onRawTap = { [weak self] in Task { @MainActor in self?.tapBuffers += 1 } }   // EVERY tap callback
            s.onTee = { [weak self] pcm, lvl in
                Task { @MainActor in self?.level = lvl; self?.onPCM?(pcm) }
            }
            s.onError = { [weak self] msg in Task { @MainActor in self?.engineError = msg } }
            sink = s
            currentURL = url
            startInstant = now

            // 1) CAPTURE engine — tap only, identical to VoiceEdit (proven to deliver buffers).
            //    format: nil = the input node's native format. Remove any stale tap first
            //    so a retry after a failed start can't crash with a double-installTap.
            let input = captureEngine.inputNode
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 4096, format: nil, block: s.makeTapBlock())
            tapInstalled = true
            captureEngine.prepare()
            try captureEngine.start()
            captureStarted = true

            // 2) PLAYBACK engine — started LAZILY on the first AI audio (see playAI). Starting
            //    both engines eagerly on a cold session was the likely cause of the "first entry
            //    stuck" report; deferring playback makes record-start = capture-only (the proven
            //    VoiceEdit path that works first time).
            playbackStarted = false

            startDate = now
            isRecording = true
            elapsed = 0
            startTicking()
            startCaptureWatchdog()   // fix "first entry stuck": recover a cold-start with no buffers
        } catch {
            // Transactional rollback so the graph/session is clean for the next attempt.
            if tapInstalled { captureEngine.inputNode.removeTap(onBus: 0) }
            if captureStarted && captureEngine.isRunning { captureEngine.stop() }
            player.stop()
            if playbackEngine.isRunning { playbackEngine.stop() }
            sink = nil
            currentURL = nil
            startInstant = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
    }

    @discardableResult
    func stop() -> AudioRecorder.Recording? {
        guard isRecording, let url = currentURL, let start = startInstant else { return nil }
        captureEngine.inputNode.removeTap(onBus: 0)
        if captureEngine.isRunning { captureEngine.stop() }
        player.stop()
        if playbackEngine.isRunning { playbackEngine.stop() }
        playbackStarted = false
        watchdogTask?.cancel(); watchdogTask = nil
        sink = nil                    // release/close the file
        stopTicking()
        isRecording = false
        level = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        let take = AudioRecorder.Recording(url: url, start: start, duration: elapsed)
        currentURL = nil
        startInstant = nil
        startDate = nil
        return take
    }

    /// Play a chunk of AI speech (mono Int16 LE @ 24 kHz). Starts the playback engine
    /// lazily on the first chunk (keeps record-start capture-only for reliability).
    func playAI(_ pcm16le24k: Data) {
        guard isRecording, let buffer = EngineRecorder.makeAIBuffer(pcm16le24k) else { return }
        if !playbackStarted {
            do {
                if player.engine == nil { playbackEngine.attach(player) }
                playbackEngine.connect(player, to: playbackEngine.mainMixerNode, format: EngineRecorder.aiFormat)
                playbackEngine.prepare()
                try playbackEngine.start()
                player.play()
                playbackStarted = true
            } catch { engineError = "播放引擎启动失败: \(error.localizedDescription)"; return }
        }
        player.scheduleBuffer(buffer, completionHandler: nil)
        if !player.isPlaying { player.play() }
    }

    // MARK: - Interruption / ticking (mirror AudioRecorder)

    @objc private nonisolated func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
        Task { @MainActor in if let take = self.stop() { self.onInterrupted?(take) } }
    }

    private func startTicking() {
        let start = startInstant ?? Date()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self else { return }
                self.elapsed = Date().timeIntervalSince(start)
            }
        }
    }
    private func stopTicking() { tickTask?.cancel(); tickTask = nil }

    // The very first cold start after launch sometimes brings up the input route too late,
    // so the capture engine delivers ZERO buffers ("first entry stuck"). If no buffer has
    // arrived shortly after start, re-tap and restart the capture engine once — by then the
    // session/route has settled. No buffers yet ⇒ the lazy file isn't open, so this is clean.
    private func startCaptureWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard let self, self.isRecording, self.tapBuffers == 0, let s = self.sink else { return }
            let input = self.captureEngine.inputNode
            input.removeTap(onBus: 0)
            if self.captureEngine.isRunning { self.captureEngine.stop() }
            input.installTap(onBus: 0, bufferSize: 4096, format: nil, block: s.makeTapBlock())
            self.captureEngine.prepare()
            try? self.captureEngine.start()
        }
    }

    // MARK: - Audio-thread sink (owns the file; @unchecked Sendable like VolcAudioStreamer)

    private final class Sink: @unchecked Sendable {
        private let url: URL
        private let aiRate: Double
        private var file: AVAudioFile?      // created lazily from the first buffer's format
        private var failed = false
        var onRawTap: (@Sendable () -> Void)?
        var onTee: (@Sendable (Data, Double) -> Void)?
        var onError: (@Sendable (String) -> Void)?
        init(url: URL, aiRate: Double) { self.url = url; self.aiRate = aiRate }

        func makeTapBlock() -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
            { [weak self] buffer, _ in
                guard let self else { return }
                self.onRawTap?()                                         // count the raw callback
                // Lazily open the AAC file using the buffer's ACTUAL format → processingFormat
                // always matches, so write(from:) never fails on a format mismatch.
                if self.file == nil && !self.failed {
                    let f = buffer.format
                    let settings: [String: Any] = [
                        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                        AVSampleRateKey: f.sampleRate,
                        AVNumberOfChannelsKey: Int(f.channelCount),
                        AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
                    ]
                    do { self.file = try AVAudioFile(forWriting: self.url, settings: settings) }
                    catch { self.failed = true; self.onError?("建文件失败: \(error.localizedDescription)") }
                }
                if let file = self.file {
                    do { try file.write(from: buffer) }                  // SACRED: file first
                    catch { self.onError?("写文件失败: \(error.localizedDescription)") }
                }
                if let pcm = EngineRecorder.resampleToInt16(buffer, outRate: self.aiRate), !pcm.isEmpty {
                    self.onTee?(pcm, EngineRecorder.rms(buffer))         // best-effort tee
                }
            }
        }
    }

    // MARK: - DSP (hand-rolled linear interpolation, mirrors VoiceEdit; no AVAudioConverter)

    nonisolated static func rms(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let ch = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<n { let s = ch[0][i]; sum += s * s }
        let rms = (sum / Float(n)).squareRoot()
        let db = 20 * log10(max(rms, 1e-7))
        return Double(max(0, min(1, (db + 50) / 50)))
    }

    /// Mono Int16 LE @ outRate from any input buffer (float or int16, any rate/channels).
    nonisolated static func resampleToInt16(_ buffer: AVAudioPCMBuffer, outRate: Double) -> Data? {
        let inRate = buffer.format.sampleRate
        let frames = Int(buffer.frameLength)
        let chans = Int(buffer.format.channelCount)
        guard inRate > 0, frames > 0, chans > 0 else { return nil }
        let outFrames = max(1, Int(Double(frames) * outRate / inRate))
        var out = [Int16](); out.reserveCapacity(outFrames)
        if let ch = buffer.floatChannelData {
            for i in 0..<outFrames {
                let pos = Double(i) * inRate / outRate
                let a = min(frames - 1, Int(pos)), b = min(frames - 1, Int(pos) + 1)
                let frac = Float(pos - Double(a))
                var mixed: Float = 0
                for c in 0..<chans { let cur = ch[c][a]; mixed += cur + (ch[c][b] - cur) * frac }
                let mono = max(-1, min(1, mixed / Float(chans)))
                out.append(Int16((mono * Float(Int16.max)).rounded()))
            }
        } else if let ch = buffer.int16ChannelData {
            for i in 0..<outFrames {
                let pos = Double(i) * inRate / outRate
                let a = min(frames - 1, Int(pos)), b = min(frames - 1, Int(pos) + 1)
                let frac = Float(pos - Double(a))
                var mixed: Float = 0
                for c in 0..<chans { mixed += Float(ch[c][a]) + (Float(ch[c][b]) - Float(ch[c][a])) * frac }
                out.append(Int16(clamping: Int((mixed / Float(chans)).rounded())))
            }
        } else { return nil }
        return out.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Build a 24 kHz mono float buffer (aiFormat) from AI Int16 PCM; mixer upsamples.
    nonisolated static func makeAIBuffer(_ data: Data) -> AVAudioPCMBuffer? {
        let count = data.count / MemoryLayout<Int16>.size
        guard count > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: aiFormat, frameCapacity: AVAudioFrameCount(count)),
              let ch = buf.floatChannelData else { return nil }
        let samples = data.withUnsafeBytes { raw in Array(raw.bindMemory(to: Int16.self)) }
        buf.frameLength = AVAudioFrameCount(count)
        for i in 0..<count { ch[0][i] = Float(samples[i]) / 32768.0 }   // /32768 so -32768 → -1.0 exactly
        return buf
    }
}
