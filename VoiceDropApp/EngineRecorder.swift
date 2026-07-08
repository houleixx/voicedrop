import Foundation
@preconcurrency import AVFoundation
import Observation
import os

/// ⚠️ AEC DIAGNOSTIC BUILD (temporary). This variant intentionally enables
/// voice-processing (VPIO/AEC) on a SINGLE full-duplex engine to capture WHY the
/// mic tap delivers 0 buffers on-device. It logs every step via os.Logger
/// (subsystem "dev.jianshuo.voicedrop", category "aec") AND surfaces a multi-line
/// report on screen (see `debugReport`). Capture is EXPECTED to fail here — we're
/// gathering the reason. After the log session, restore the working two-engine
/// half-duplex build.
///
/// Console.app: connect iPhone → filter "voicedrop" → reproduce → copy logs.
@MainActor
@Observable
final class EngineRecorder: RecordingBackend {
    nonisolated static let log = Logger(subsystem: "dev.jianshuo.voicedrop", category: "aec")

    private(set) var isRecording = false
    private(set) var elapsed: TimeInterval = 0
    private(set) var level: Double = 0
    private(set) var startDate: Date?
    var onInterrupted: ((AudioRecorder.Recording) -> Void)?

    // Diagnostics surfaced on screen.
    private(set) var tapBuffers = 0
    private(set) var engineError: String?
    private(set) var vpioLine = "VPIO: (未开始)"      // enable result
    private(set) var fmtLine = "fmt: (未知)"           // input format pre/post VPIO
    private(set) var tapTimeline = "tap@t: -"          // tap count sampled over time

    var onPCM: ((Data) -> Void)?

    static let aiRate: Double = 24_000
    nonisolated static let aiFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                    sampleRate: 24_000, channels: 1, interleaved: false)!

    // SINGLE engine (VPIO requires input+output coupled).
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    // Muted mixer that routes the mic into the render graph so the graph actively PULLS
    // the input node → the tap fires. Without this, VPIO's input side is never pulled
    // (the AI player is silent), so tap delivers 0 buffers. outputVolume 0 = no feedback.
    private let micSink = AVAudioMixerNode()
    private var sink: Sink?
    private var currentURL: URL?
    private var startInstant: Date?
    private var tickTask: Task<Void, Never>?
    private var sampleTask: Task<Void, Never>?

    init() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification, object: nil)
    }

    static func ensurePermission() async -> Bool { await AudioRecorder.ensurePermission() }

    func start() throws {
        tapBuffers = 0; engineError = nil
        let log = EngineRecorder.log

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.duckOthers, .defaultToSpeaker])
        try session.setActive(true)
        log.info("session: category=\(session.category.rawValue) mode=\(session.mode.rawValue) sr=\(session.sampleRate) inCh=\(session.inputNumberOfChannels)")

        let input = engine.inputNode
        let pre = input.outputFormat(forBus: 0)
        let hwPre = input.inputFormat(forBus: 0)
        log.info("inputNode BEFORE vpio: out=\(pre.sampleRate)/\(pre.channelCount)ch hw=\(hwPre.sampleRate)/\(hwPre.channelCount)ch")

        var vpioOK = false
        do { try input.setVoiceProcessingEnabled(true); vpioOK = true }
        catch { vpioOK = false; vpioLine = "VPIO: 报错 \(error.localizedDescription)"; log.error("setVoiceProcessingEnabled THREW: \(error.localizedDescription, privacy: .public)") }
        let isVP = input.isVoiceProcessingEnabled
        if vpioOK { vpioLine = "VPIO: enabled=\(isVP)" }
        let post = input.outputFormat(forBus: 0)
        log.info("inputNode AFTER vpio: enabled=\(isVP) out=\(post.sampleRate)/\(post.channelCount)ch")
        fmtLine = "fmt pre \(Int(pre.sampleRate))/\(pre.channelCount) → post \(Int(post.sampleRate))/\(post.channelCount)"

        let now = Date()
        let url = AudioRecorder.stagingURL(start: now)
        let s = Sink(url: url, aiRate: EngineRecorder.aiRate)
        s.onRawTap = { [weak self] in Task { @MainActor in self?.tapBuffers += 1 } }
        s.onTee = { [weak self] pcm, lvl in Task { @MainActor in self?.level = lvl; self?.onPCM?(pcm) } }
        s.onError = { [weak self] msg in Task { @MainActor in self?.engineError = msg }; EngineRecorder.log.error("sink: \(msg, privacy: .public)") }
        sink = s; currentURL = url; startInstant = now

        // AI playback path.
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: EngineRecorder.aiFormat)
        // Mic PULL path: input → micSink(vol 0) → mainMixer. This makes the render graph
        // actively pull the input node so the tap fires (the fix for tap 0 under VPIO).
        engine.attach(micSink)
        engine.connect(input, to: micSink, format: post)
        micSink.outputVolume = 0
        engine.connect(micSink, to: engine.mainMixerNode, format: post)
        log.info("micSink wired (input→micSink[0]→mainMixer)")

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: nil, block: s.makeTapBlock())
        log.info("tap installed (format:nil)")

        engine.prepare()
        do { try engine.start(); log.info("engine.start() OK isRunning=\(self.engine.isRunning)") }
        catch { engineError = "engine.start 报错: \(error.localizedDescription)"; log.error("engine.start THREW: \(error.localizedDescription, privacy: .public)"); throw error }
        player.play()

        startDate = now; isRecording = true; elapsed = 0
        startTicking()
        startSampling()   // log tap count at 200/500/1000/2000/4000ms
    }

    @discardableResult
    func stop() -> AudioRecorder.Recording? {
        guard isRecording, let url = currentURL, let start = startInstant else { return nil }
        EngineRecorder.log.info("stop: final tapBuffers=\(self.tapBuffers)")
        engine.inputNode.removeTap(onBus: 0)
        player.stop()
        if engine.isRunning { engine.stop() }
        sink = nil; stopTicking(); sampleTask?.cancel(); sampleTask = nil
        isRecording = false; level = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        let take = AudioRecorder.Recording(url: url, start: start, duration: elapsed)
        currentURL = nil; startInstant = nil; startDate = nil
        return take
    }

    func playAI(_ pcm16le24k: Data) {
        guard isRecording, let buffer = EngineRecorder.makeAIBuffer(pcm16le24k) else { return }
        player.scheduleBuffer(buffer, completionHandler: nil)
        if !player.isPlaying { player.play() }
    }

    private func startSampling() {
        sampleTask?.cancel()
        sampleTask = Task { [weak self] in
            // (absolute-ms label, delta-to-sleep)
            let steps: [(Int, Int)] = [(200, 200), (500, 300), (1000, 500), (2000, 1000), (4000, 2000)]
            var line = ""
            for (label, delta) in steps {
                try? await Task.sleep(for: .milliseconds(delta))
                guard let self, self.isRecording else { return }
                line += "\(label):\(self.tapBuffers) "
                self.tapTimeline = "tap " + line
                EngineRecorder.log.info("tap @\(label)ms = \(self.tapBuffers)")
            }
        }
    }

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

    // MARK: - Audio-thread sink

    private final class Sink: @unchecked Sendable {
        private let url: URL
        private let aiRate: Double
        private var file: AVAudioFile?
        private var failed = false
        var onRawTap: (@Sendable () -> Void)?
        var onTee: (@Sendable (Data, Double) -> Void)?
        var onError: (@Sendable (String) -> Void)?
        init(url: URL, aiRate: Double) { self.url = url; self.aiRate = aiRate }

        func makeTapBlock() -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
            { [weak self] buffer, _ in
                guard let self else { return }
                self.onRawTap?()
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
                    do { try file.write(from: buffer) } catch { self.onError?("写文件失败: \(error.localizedDescription)") }
                }
                if let pcm = EngineRecorder.resampleToInt16(buffer, outRate: self.aiRate), !pcm.isEmpty {
                    self.onTee?(pcm, EngineRecorder.rms(buffer))
                }
            }
        }
    }

    // MARK: - DSP

    nonisolated static func rms(_ buffer: AVAudioPCMBuffer) -> Double {
        guard let ch = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let n = Int(buffer.frameLength); var sum: Float = 0
        for i in 0..<n { let s = ch[0][i]; sum += s * s }
        let db = 20 * log10(max((sum / Float(n)).squareRoot(), 1e-7))
        return Double(max(0, min(1, (db + 50) / 50)))
    }

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

    nonisolated static func makeAIBuffer(_ data: Data) -> AVAudioPCMBuffer? {
        let count = data.count / MemoryLayout<Int16>.size
        guard count > 0,
              let buf = AVAudioPCMBuffer(pcmFormat: aiFormat, frameCapacity: AVAudioFrameCount(count)),
              let ch = buf.floatChannelData else { return nil }
        let samples = data.withUnsafeBytes { raw in Array(raw.bindMemory(to: Int16.self)) }
        buf.frameLength = AVAudioFrameCount(count)
        for i in 0..<count { ch[0][i] = Float(samples[i]) / 32768.0 }
        return buf
    }
}
