import Foundation
@preconcurrency import AVFoundation
import Observation
import os

/// AVAudioEngine recording backend — since 2026-07-08 the DEFAULT for every take
/// (with `Prefs.classicRecorder` as the AVAudioRecorder escape hatch). Produces a
/// valid AAC mono `recording-<ts>.m4a` at the user's 录音质量 setting (标准 16 kHz /
/// 32 kbps · 高 24 kHz / 64 kbps — same contract as `Prefs.recorderSettings`), so
/// promote/upload/ASR downstream is unchanged. Additionally:
///   • can tee the mic PCM (mono Int16 @ 24 kHz, via a persistent AVAudioConverter)
///     to `onPCM` for the AI 采访员 uplink — gated by `teeEnabled`, zero cost when off,
///   • plays AI audio via a separate playback engine's `AVAudioPlayerNode`.
///
/// FILE FORMAT IS FIXED FOR THE WHOLE TAKE: the AVAudioFile is created eagerly at
/// start() with the target format, and EVERY tap buffer is converted into it through
/// a persistent `AVAudioConverter` (recreated only when the input format changes).
/// A mid-take route change (AirPods in/out, Bluetooth switch) therefore changes the
/// converter's input side — never the file — so the recording keeps rolling across
/// sample-rate/channel changes. `handleConfigChange` rebuilds the tap + restarts the
/// engine on `AVAudioEngineConfigurationChange`.
///
/// NO acoustic echo cancellation (AEC): enabling `setVoiceProcessingEnabled` silently
/// killed the input tap on device (tap 0 buffers). Without AEC the AI's loudspeaker
/// leaks into the recording → USE EARPHONES for a clean take. (AEC to be revisited.)
///
/// TWO engines: a capture-only engine (tap identical to VoiceEdit — proven to deliver
/// buffers) + a separate playback-only engine. A single full-duplex engine left the
/// input un-pulled (tap 0). The mic tap uses the input node's NATIVE format (format: nil).
///
/// The tap runs on a realtime audio thread (NOT main actor): file write + conversion
/// live in a `@unchecked Sendable` `Sink`. The mic level crosses to the UI via a
/// lock + the existing 100 ms tick (no per-buffer main-actor hops).
@MainActor
@Observable
final class EngineRecorder: RecordingBackend {
    nonisolated static let log = Logger(subsystem: "dev.jianshuo.voicedrop", category: "realtime")
    /// One-liner trace helper so other views can log into the same subsystem/category.
    nonisolated static func trace(_ msg: String) { log.info("\(msg, privacy: .public)") }
    private(set) var isRecording = false
    private(set) var elapsed: TimeInterval = 0
    private(set) var level: Double = 0
    private(set) var startDate: Date?
    var onInterrupted: ((AudioRecorder.Recording) -> Void)?

    private(set) var engineError: String?  // any capture/file error (surfaced in RecordSession)

    /// Mic PCM teed for the AI uplink: mono Int16 little-endian @ 24 kHz. Only fires
    /// while `teeEnabled` — a plain recording pays nothing for the AI side-path.
    var onPCM: ((Data) -> Void)?
    /// The AI interview side-path switch. Flipped by RealtimeInterviewer on toggle;
    /// when false the Sink skips the resample/convert + Data alloc entirely.
    var teeEnabled = false { didSet { sink?.teeEnabled = teeEnabled } }

    nonisolated static let aiRate: Double = 24_000
    /// Fixed format for AI playback buffers; the engine mixer resamples to hardware.
    nonisolated static let aiFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                    sampleRate: 24_000, channels: 1, interleaved: false)!

    // TWO separate engines — see class comment.
    private let captureEngine = AVAudioEngine()
    private let playbackEngine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var playbackStarted = false     // playback engine starts LAZILY on first AI audio
    // Half-duplex needs to know when the AI's audio has finished PLAYING (not just when
    // OpenAI finished generating), so the uplink resumes only after the loudspeaker is
    // quiet. `playbackGen` guards the counter against STALE completions: player.stop()
    // fires the completion of every still-queued buffer, and without a generation those
    // late decrements would poison the NEXT interview segment's accounting (reopening
    // the mic while AI audio still plays → the self-hear loop half-duplex exists to stop).
    private var pendingPlayback = 0
    private var playbackGen = 0
    var isPlaybackIdle: Bool { pendingPlayback == 0 }
    var onPlaybackDrained: (() -> Void)?
    private var sink: Sink?
    private var currentURL: URL?
    private var startInstant: Date?
    private var tickTask: Task<Void, Never>?

    init() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification, object: nil)
        // The engine backend records EVERY take, so it must survive route changes
        // (AirPods in/out, Bluetooth switch) the way AVAudioRecorder did natively.
        // On AVAudioEngineConfigurationChange we rebuild the tap at the NEW native
        // format and restart capture; the Sink's persistent converter bridges the new
        // input format into the unchanged file, so the take keeps rolling.
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleConfigChange(_:)),
            name: .AVAudioEngineConfigurationChange, object: captureEngine)
    }

    static func ensurePermission() async -> Bool { await AudioRecorder.ensurePermission() }

    /// Warm the audio route ONCE PER LAUNCH before the first capture start, so the
    /// cold-start lag happens behind the spinner instead of freezing the recording UI.
    /// Subsequent recordings skip it (start() re-activates the session itself).
    private static var warmed = false
    static func prewarm() async {
        guard !warmed else { return }
        warmed = true
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playAndRecord, mode: .default, options: [.duckOthers, .defaultToSpeaker])
        try? s.setActive(true)
        try? await Task.sleep(for: .milliseconds(150))
    }

    func start() throws {
        engineError = nil

        var tapInstalled = false
        var captureStarted = false
        let tStart = Date()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default, options: [.duckOthers, .defaultToSpeaker])
            try session.setActive(true)

            let now = Date()
            let url = AudioRecorder.stagingURL(start: now)
            // Fixed file format from the 录音质量 pref — created EAGERLY so a file
            // failure aborts start() loudly instead of surfacing mid-take.
            let high = UserDefaults.standard.object(forKey: "pref.highQuality") as? Bool ?? false
            let s = try Sink(url: url,
                             fileSampleRate: high ? 24_000 : 16_000,
                             fileBitRate: high ? 64_000 : 32_000)
            s.teeEnabled = teeEnabled
            s.onTee = { [weak self] pcm in Task { @MainActor in self?.onPCM?(pcm) } }
            s.onError = { [weak self] msg in Task { @MainActor in self?.engineError = msg } }
            sink = s
            currentURL = url
            startInstant = now

            // CAPTURE engine — tap only, identical to VoiceEdit (proven to deliver
            // buffers). format: nil = the input node's native format. Remove any stale
            // tap first so a retry after a failed start can't crash on double-install.
            let input = captureEngine.inputNode
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 4096, format: nil, block: s.makeTapBlock())
            tapInstalled = true
            captureEngine.prepare()
            try captureEngine.start()
            captureStarted = true

            // PLAYBACK engine — started LAZILY on the first AI audio (see playAI).
            playbackStarted = false

            startDate = now
            isRecording = true
            elapsed = 0
            startTicking()
        } catch {
            EngineRecorder.log.error("start: THREW +\(Date().timeIntervalSince(tStart), format: .fixed(precision: 3))s: \(error.localizedDescription, privacy: .public)")
            // Transactional rollback so the graph/session is clean for the next attempt.
            if tapInstalled { captureEngine.inputNode.removeTap(onBus: 0) }
            if captureStarted && captureEngine.isRunning { captureEngine.stop() }
            tearDownPlayback()
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
        tearDownPlayback()
        sink = nil                    // release/close the file (finalizes the m4a)
        stopTicking()
        isRecording = false
        level = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        let take = AudioRecorder.Recording(url: url, start: start, duration: elapsed)
        currentURL = nil
        startInstant = nil
        startDate = nil
        // NEVER promote a ghost: if the file was never created / vanished, returning a
        // take would let it silently disappear downstream (promote's move throws and
        // nothing surfaces). Return nil + engineError so the UI can show a real failure.
        guard FileManager.default.fileExists(atPath: url.path) else {
            engineError = engineError ?? "录音文件未生成"
            EngineRecorder.trace("stop: file missing (\(url.lastPathComponent)) — refusing to promote a ghost take")
            return nil
        }
        return take
    }

    /// Play a chunk of AI speech (mono Int16 LE @ 24 kHz). Starts the playback engine
    /// lazily on the first chunk — and RE-starts it if a route change stopped it
    /// (playAI is the recovery point; a stopped engine + play() would NSException).
    func playAI(_ pcm16le24k: Data) {
        guard isRecording, let buffer = EngineRecorder.makeAIBuffer(pcm16le24k) else { return }
        if !playbackStarted || !playbackEngine.isRunning {
            do {
                if player.engine == nil { playbackEngine.attach(player) }
                playbackEngine.connect(player, to: playbackEngine.mainMixerNode, format: EngineRecorder.aiFormat)
                playbackEngine.prepare()
                try playbackEngine.start()
                player.play()
                playbackStarted = true
            } catch { engineError = "播放引擎启动失败: \(error.localizedDescription)"; return }
        }
        pendingPlayback += 1
        let gen = playbackGen
        // .dataPlayedBack fires when the buffer has actually been PLAYED — or when the
        // player is STOPPED (stale fire); the generation check drops the stale ones.
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, gen == self.playbackGen else { return }
                self.pendingPlayback -= 1
                if self.pendingPlayback <= 0 { self.pendingPlayback = 0; self.onPlaybackDrained?() }
            }
        }
        if !player.isPlaying { player.play() }
    }

    /// Stop AI playback immediately (toggle-off mid-speech): bumps the generation so
    /// the stopped buffers' stale completions are ignored, clears the drain counter,
    /// and signals drained so the half-duplex gate can reopen. Capture is untouched.
    func stopAIPlayback() {
        tearDownPlayback()
        onPlaybackDrained?()
    }

    /// Single teardown for the playback side (used by stop(), stopAIPlayback(),
    /// start-rollback and config-change recovery) so generation/counter/lazy-start
    /// bookkeeping can never diverge between paths.
    private func tearDownPlayback() {
        playbackGen += 1
        player.stop()
        if playbackEngine.isRunning { playbackEngine.stop() }
        playbackStarted = false
        pendingPlayback = 0
    }

    // MARK: - Interruption / config change / ticking

    @objc private nonisolated func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
        Task { @MainActor in if let take = self.stop() { self.onInterrupted?(take) } }
    }

    /// Route/config changed mid-recording (headphones plugged, Bluetooth switch…).
    /// The engine graph is NOT guaranteed healthy afterwards even if it reports
    /// running: rebuild the tap at the input node's CURRENT native format and restart.
    /// The Sink keeps the same file; its persistent converter bridges the new format.
    @objc private nonisolated func handleConfigChange(_ note: Notification) {
        Task { @MainActor in self.rebuildAfterConfigChange() }
    }

    private func rebuildAfterConfigChange() {
        guard isRecording, let s = sink else { return }
        EngineRecorder.trace("configChange: rebuilding capture (was running=\(captureEngine.isRunning))")
        let input = captureEngine.inputNode
        input.removeTap(onBus: 0)
        if captureEngine.isRunning { captureEngine.stop() }
        input.installTap(onBus: 0, bufferSize: 4096, format: nil, block: s.makeTapBlock())
        captureEngine.prepare()
        do {
            try captureEngine.start()
            EngineRecorder.trace("configChange: capture restarted OK (input \(input.inputFormat(forBus: 0).sampleRate) Hz)")
        } catch {
            engineError = "路由切换后录音引擎重启失败: \(error.localizedDescription)"
            EngineRecorder.trace("configChange: restart FAILED \(error.localizedDescription)")
        }
        // Playback side stops on config change too; reset so the next AI chunk lazily
        // restarts it (and stale completions from the dead engine are generation-dropped),
        // then release the half-duplex gate.
        tearDownPlayback()
        onPlaybackDrained?()
    }

    private func startTicking() {
        let start = startInstant ?? Date()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self else { return }
                self.elapsed = Date().timeIntervalSince(start)
                // Level is produced on the audio thread and published here —
                // one read per 100 ms instead of a main-actor hop per buffer.
                if let s = self.sink { self.level = s.latestLevel }
            }
        }
    }
    private func stopTicking() { tickTask?.cancel(); tickTask = nil }

    // MARK: - Audio-thread sink (owns the file; @unchecked Sendable like VolcAudioStreamer)

    /// Owns the AVAudioFile (FIXED format for the whole take) and the two persistent
    /// AVAudioConverters (file bridge + AI tee). Everything here runs on the realtime
    /// audio thread except the lock-guarded flags read/written from the main actor.
    private final class Sink: @unchecked Sendable {
        private let file: AVAudioFile
        private var fileConverter: AVAudioConverter?
        private var teeConverter: AVAudioConverter?
        private let teeFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                              sampleRate: EngineRecorder.aiRate, channels: 1, interleaved: true)!
        private var reportedWriteError = false
        var onTee: (@Sendable (Data) -> Void)?
        var onError: (@Sendable (String) -> Void)?

        // Cross-thread flags/meters (audio thread writes, main actor reads via tick).
        private let lock = NSLock()
        private var _teeEnabled = false
        private var _level: Double = 0
        var teeEnabled: Bool {
            get { lock.lock(); defer { lock.unlock() }; return _teeEnabled }
            set { lock.lock(); _teeEnabled = newValue; lock.unlock() }
        }
        var latestLevel: Double {
            lock.lock(); defer { lock.unlock() }
            return _level
        }

        /// Creates the AAC file EAGERLY at the target speech-tuned format
        /// (same contract as Prefs.recorderSettings) — throws loudly at start().
        init(url: URL, fileSampleRate: Double, fileBitRate: Int) throws {
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: fileSampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
                AVEncoderBitRateKey: fileBitRate,
            ]
            file = try AVAudioFile(forWriting: url, settings: settings)
        }

        func makeTapBlock() -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
            { [weak self] buffer, _ in
                guard let self else { return }
                let teeOn: Bool
                self.lock.lock()
                self._level = EngineRecorder.rms(buffer)
                teeOn = self._teeEnabled
                self.lock.unlock()
                self.write(buffer)                                   // SACRED: file first
                if teeOn, let pcm = self.teeInt16(buffer), !pcm.isEmpty {
                    self.onTee?(pcm)                                 // best-effort AI tee
                }
            }
        }

        /// Convert the tap buffer into the file's fixed processing format (persistent
        /// converter → fractional resample phase carries across buffers) and append.
        /// The converter is recreated only when the INPUT format changes (route switch).
        private func write(_ buffer: AVAudioPCMBuffer) {
            if fileConverter == nil || fileConverter!.inputFormat != buffer.format {
                fileConverter = AVAudioConverter(from: buffer.format, to: file.processingFormat)
            }
            guard let conv = fileConverter, let out = Sink.convert(buffer, with: conv) else {
                reportOnce("音频格式转换失败（路由切换后）"); return
            }
            guard out.frameLength > 0 else { return }               // converter priming
            do { try file.write(from: out) }
            catch { reportOnce("写文件失败: \(error.localizedDescription)") }
        }

        /// Persistent-converter AI tee: mono Int16 LE @ 24 kHz regardless of route.
        private func teeInt16(_ buffer: AVAudioPCMBuffer) -> Data? {
            if teeConverter == nil || teeConverter!.inputFormat != buffer.format {
                teeConverter = AVAudioConverter(from: buffer.format, to: teeFormat)
            }
            guard let conv = teeConverter, let out = Sink.convert(buffer, with: conv),
                  out.frameLength > 0, let ch = out.int16ChannelData else { return nil }
            return Data(bytes: ch[0], count: Int(out.frameLength) * MemoryLayout<Int16>.size)
        }

        private func reportOnce(_ msg: String) {
            guard !reportedWriteError else { return }
            reportedWriteError = true
            onError?(msg)
        }

        /// One-shot buffer conversion that PRESERVES converter state across calls
        /// (.noDataNow keeps fractional phase for the next buffer).
        private static func convert(_ buffer: AVAudioPCMBuffer, with conv: AVAudioConverter) -> AVAudioPCMBuffer? {
            let ratio = conv.outputFormat.sampleRate / conv.inputFormat.sampleRate
            let cap = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
            guard let out = AVAudioPCMBuffer(pcmFormat: conv.outputFormat, frameCapacity: max(cap, 64)) else { return nil }
            var fed = false
            var err: NSError?
            let status = conv.convert(to: out, error: &err) { _, inputStatus in
                if fed { inputStatus.pointee = .noDataNow; return nil }
                fed = true
                inputStatus.pointee = .haveData
                return buffer
            }
            return status == .error ? nil : out
        }
    }

    // MARK: - DSP helpers

    /// RMS level in 0…1 — handles BOTH float32 and int16 tap formats (some routes
    /// deliver int16; without this branch the waveform would sit at 0 all take).
    nonisolated static func rms(_ buffer: AVAudioPCMBuffer) -> Double {
        let n = Int(buffer.frameLength)
        guard n > 0 else { return 0 }
        var sum: Float = 0
        if let ch = buffer.floatChannelData {
            for i in 0..<n { let s = ch[0][i]; sum += s * s }
        } else if let ch = buffer.int16ChannelData {
            for i in 0..<n { let s = Float(ch[0][i]) / 32768.0; sum += s * s }
        } else { return 0 }
        let rms = (sum / Float(n)).squareRoot()
        let db = 20 * log10(max(rms, 1e-7))
        return Double(max(0, min(1, (db + 50) / 50)))
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
