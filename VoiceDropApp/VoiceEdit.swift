import SwiftUI
@preconcurrency import AVFoundation
import Observation

private enum ASRProxyConfig {
    static let endpoint = URL(string: "wss://jianshuo.dev/agent/asr")!
    static let userID = "voicedrop-edit"
    static let sampleRate = 16_000.0
}

private final class VolcAudioStreamer: @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let queue = DispatchQueue(label: "VoiceDrop.VolcASR.audio")
    private var sequence: Int32 = 1
    private var stopped = false

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    func send(_ pcm: Data) {
        guard !pcm.isEmpty else { return }
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.sequence += 1
            self.task.send(.data(VolcASRProtocol.buildAudioPayload(pcm, sequence: self.sequence, isLast: false))) { _ in }
        }
    }

    func finish() {
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.stopped = true
            self.sequence += 1
            self.task.send(.data(VolcASRProtocol.buildAudioPayload(Data(), sequence: self.sequence, isLast: true))) { _ in }
        }
    }

    func cancel() {
        queue.async { [weak self] in
            self?.stopped = true
        }
    }

    func makeTapBlock() -> @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void {
        { [weak self] buffer, _ in
            guard let pcm = Self.convertToMono16kPCM(buffer), !pcm.isEmpty else {
                return
            }
            self?.send(pcm)
        }
    }

    private static func convertToMono16kPCM(_ buffer: AVAudioPCMBuffer) -> Data? {
        let inputRate = buffer.format.sampleRate
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard inputRate > 0, frameCount > 0, channelCount > 0 else { return nil }

        let outputRate = ASRProxyConfig.sampleRate
        let outputFrames = max(1, Int(Double(frameCount) * outputRate / inputRate))
        var samples = [Int16]()
        samples.reserveCapacity(outputFrames)

        if let channels = buffer.floatChannelData {
            for outputIndex in 0..<outputFrames {
                let sourcePosition = Double(outputIndex) * inputRate / outputRate
                let sourceIndex = min(frameCount - 1, Int(sourcePosition))
                let nextIndex = min(frameCount - 1, sourceIndex + 1)
                let fraction = Float(sourcePosition - Double(sourceIndex))
                var mixed: Float = 0
                for channelIndex in 0..<channelCount {
                    let current = channels[channelIndex][sourceIndex]
                    let next = channels[channelIndex][nextIndex]
                    mixed += current + (next - current) * fraction
                }
                let mono = max(-1, min(1, mixed / Float(channelCount)))
                samples.append(Int16((mono * Float(Int16.max)).rounded()))
            }
        } else if let channels = buffer.int16ChannelData {
            for outputIndex in 0..<outputFrames {
                let sourcePosition = Double(outputIndex) * inputRate / outputRate
                let sourceIndex = min(frameCount - 1, Int(sourcePosition))
                let nextIndex = min(frameCount - 1, sourceIndex + 1)
                let fraction = Float(sourcePosition - Double(sourceIndex))
                var mixed: Float = 0
                for channelIndex in 0..<channelCount {
                    let current = Float(channels[channelIndex][sourceIndex])
                    let next = Float(channels[channelIndex][nextIndex])
                    mixed += current + (next - current) * fraction
                }
                samples.append(Int16(clamping: Int((mixed / Float(channelCount)).rounded())))
            }
        } else {
            return nil
        }

        return samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}

/// Speech dictation for edit instructions. The app sends microphone PCM to its
/// own agent WebSocket; the server owns the Volcengine credentials and proxies
/// the streaming ASR connection.
@MainActor
@Observable
final class SpeechDictation {
    var transcript = ""
    var isRecording = false
    var authorized: Bool? = nil      // nil = not asked yet
    var error: String?

    private let engine = AVAudioEngine()
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var audioStreamer: VolcAudioStreamer?
    private var sequence: Int32 = 1
    private var stopping = false
    private var tapInstalled = false

    func requestAuth() async {
        let mic = await AVAudioApplication.requestRecordPermission()
        authorized = mic
        if !mic {
            error = "需要在设置里允许麦克风权限。"
        } else {
            error = nil
        }
    }

    func start() {
        guard authorized == true, !isRecording else { return }
        guard !AuthStore.shared.bearer.isEmpty else {
            error = "未登录，无法连接语音识别服务。"
            return
        }
        transcript = ""
        error = nil
        stopping = false
        sequence = 1

        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

            openSocket()
            try startAudioEngine()
            isRecording = true
        } catch {
            self.error = error.localizedDescription
            stop()
        }
    }

    func stop() {
        stopAudioEngine()
        sendFinalPacket()
        closeSocket()
        isRecording = false
        stopping = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Stop recording and wait briefly for Volcengine to flush the tail result.
    func stopAndGetFinal() async -> String {
        guard isRecording else { return transcript }
        stopping = true
        stopAudioEngine()
        sendFinalPacket()
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)

        for _ in 0..<30 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            if !stopping { break }
        }
        closeSocket()
        stopping = false
        return transcript
    }

    private func openSocket() {
        var req = URLRequest(url: ASRProxyConfig.endpoint)
        req.setBearer(AuthStore.shared.bearer)

        let s = URLSession(configuration: .default)
        let ws = s.webSocketTask(with: req)
        session = s
        task = ws
        audioStreamer = VolcAudioStreamer(task: ws)
        ws.resume()
        receive()
        ws.send(.data(VolcASRProtocol.buildFullClientPayload(
            appUserID: ASRProxyConfig.userID,
            sampleRate: Int(ASRProxyConfig.sampleRate)
        ))) { [weak self] err in
            guard let err else { return }
            Task { @MainActor in self?.error = "语音识别初始化失败：\(err.localizedDescription)" }
        }
    }

    private func startAudioEngine() throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw NSError(
                domain: "VoiceDrop.VolcASR",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "麦克风输入不可用，请检查模拟器或系统麦克风权限。"]
            )
        }
        guard let audioStreamer else {
            throw NSError(domain: "VoiceDrop.VolcASR", code: 3, userInfo: [NSLocalizedDescriptionKey: "语音识别连接尚未初始化"])
        }

        if tapInstalled {
            input.removeTap(onBus: 0)
            tapInstalled = false
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: nil, block: audioStreamer.makeTapBlock())
        tapInstalled = true
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            tapInstalled = false
            throw error
        }
    }

    private func stopAudioEngine() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning {
            engine.stop()
        }
    }

    private func sendAudio(_ pcm: Data) {
        audioStreamer?.send(pcm)
    }

    private func sendFinalPacket() {
        audioStreamer?.finish()
    }

    private func receive() {
        task?.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .failure(let err):
                    if self.stopping {
                        self.stopping = false
                    } else {
                        self.error = "语音识别连接中断：\(err.localizedDescription)"
                    }
                case .success(let message):
                    self.handle(message)
                    self.receive()
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data?
        switch message {
        case .data(let d): data = d
        case .string(let s): data = Data(s.utf8)
        @unknown default: data = nil
        }
        guard let data else { return }
        do {
            let parsed = try VolcASRProtocol.parseServerMessage(data)
            if parsed.isError {
                error = "语音识别错误 \(parsed.errorCode.map(String.init) ?? "")：\(parsed.errorMessage ?? "未知错误")"
                stopping = false
                return
            }
            if !parsed.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                transcript = parsed.text
            }
            if parsed.isFinal { stopping = false }
        } catch {
            self.error = "语音识别响应解析失败：\(error.localizedDescription)"
        }
    }

    private func closeSocket() {
        audioStreamer?.cancel()
        audioStreamer = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }
}
