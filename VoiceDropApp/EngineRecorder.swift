import Foundation
@preconcurrency import AVFoundation
import Observation

/// AVAudioEngine recording backend, used ONLY in realtime (AI) mode. Produces a
/// valid AAC mono `recording-<ts>.m4a` (same staging name as `AudioRecorder`), so
/// promote/upload downstream is unchanged. Additionally:
///   • tees the mic PCM (resampled to 24 kHz Int16) to `onPCM` for the AI uplink,
///   • enables voice-processing AEC so the AI's loudspeaker audio is cancelled out
///     of the mic before it's written to the file,
///   • plays AI audio via an `AVAudioPlayerNode` routed through the engine mixer.
///
/// CRITICAL (fixed 2026-07-08): the mic tap MUST use the input node's NATIVE format
/// (read after enabling voice processing). Installing a tap with a mismatched format
/// (e.g. the 24 kHz file format while hardware is 48 kHz) silently delivers ZERO
/// buffers on iOS 26 — no crash, timer runs, but nothing is captured (no file, no
/// PCM to OpenAI, so the AI never hears anything and stays silent). We therefore
/// record the file at the native rate and hand-resample the 24 kHz tee separately.
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

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var sink: Sink?
    private var currentURL: URL?
    private var startInstant: Date?
    private var tickTask: Task<Void, Never>?

    init() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification, object: nil)
    }

    static func ensurePermission() async -> Bool { await AudioRecorder.ensurePermission() }

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.duckOthers, .defaultToSpeaker])
        try session.setActive(true)

        let input = engine.inputNode
        try? input.setVoiceProcessingEnabled(true)          // AEC/AGC/NS (best-effort)

        // AI playback path through the engine (gives voice-processing its reference signal).
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: EngineRecorder.aiFormat)

        let now = Date()
        let url = AudioRecorder.stagingURL(start: now)
        // Sink creates the AAC file LAZILY from the first buffer's own format, so the
        // file always matches what the tap delivers — no format guessing, no mismatch.
        let s = Sink(url: url, aiRate: EngineRecorder.aiRate)
        s.onTee = { [weak self] pcm, lvl in
            Task { @MainActor in self?.tapBuffers += 1; self?.level = lvl; self?.onPCM?(pcm) }
        }
        s.onError = { [weak self] msg in Task { @MainActor in self?.engineError = msg } }
        sink = s
        currentURL = url
        startInstant = now

        // format: nil → the input node's NATIVE format (guaranteed to deliver buffers).
        input.installTap(onBus: 0, bufferSize: 4096, format: nil, block: s.makeTapBlock())
        engine.prepare()
        try engine.start()
        player.play()

        startDate = now
        isRecording = true
        elapsed = 0
        tapBuffers = 0
        engineError = nil
        startTicking()
    }

    @discardableResult
    func stop() -> AudioRecorder.Recording? {
        guard isRecording, let url = currentURL, let start = startInstant else { return nil }
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        if engine.isRunning { engine.stop() }
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

    /// Play a chunk of AI speech (mono Int16 LE @ 24 kHz) through the engine mixer.
    func playAI(_ pcm16le24k: Data) {
        guard isRecording, let buffer = EngineRecorder.makeAIBuffer(pcm16le24k) else { return }
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

    // MARK: - Audio-thread sink (owns the file; @unchecked Sendable like VolcAudioStreamer)

    private final class Sink: @unchecked Sendable {
        private let url: URL
        private let aiRate: Double
        private var file: AVAudioFile?      // created lazily from the first buffer's format
        private var failed = false
        var onTee: (@Sendable (Data, Double) -> Void)?
        var onError: (@Sendable (String) -> Void)?
        init(url: URL, aiRate: Double) { self.url = url; self.aiRate = aiRate }

        func makeTapBlock() -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
            { [weak self] buffer, _ in
                guard let self else { return }
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
        for i in 0..<count { ch[0][i] = Float(samples[i]) / Float(Int16.max) }
        return buf
    }
}
