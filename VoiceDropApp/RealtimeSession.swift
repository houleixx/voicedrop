import Foundation

/// WebSocket client for the Realtime AI 采访员 — connects to OUR Cloudflare relay
/// (`/agent/realtime/relay`), which forwards to OpenAI server-side. The phone never
/// touches OpenAI: users in China can't reach api.openai.com, and OPENAI_API_KEY
/// stays in the worker. Auth is the same `req.setBearer(AuthStore.bearer)` as
/// StatusSession/VoiceEdit. The worker injects the interviewer `session.update`,
/// so this client only streams audio + drives responses. Billing is server-side
/// (the relay meters `response.done.usage`) — nothing to report from here.
///
/// Event names verified live 2026-07-08 against the deployed relay:
///   receive: input_audio_buffer.speech_started / .speech_stopped,
///            response.output_audio.delta (AI voice, base64 PCM16 24k)
///   send:    input_audio_buffer.append / response.create / response.cancel
@MainActor
final class RealtimeSession {
    enum State: String { case idle, connecting, live, degraded }

    // Callbacks injected by RealtimeInterviewer.
    var onAudioDelta: ((Data) -> Void)?      // decoded PCM16 24k mono bytes of AI speech
    var onSpeechStarted: (() -> Void)?
    var onSpeechStopped: (() -> Void)?
    var onResponseDone: (() -> Void)?        // AI finished a turn (used to clear "AI speaking")
    var onStateChange: ((State) -> Void)?

    private(set) var state: State = .idle { didSet { if state != oldValue { onStateChange?(state) } } }
    private(set) var speechEvents = 0    // diagnostics: speech_started/stopped received
    private(set) var audioDeltas = 0     // diagnostics: AI audio chunks received

    private var task: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var closed = false

    func connect() {
        guard task == nil else { return }
        closed = false
        state = .connecting
        let token = AuthStore.shared.bearer
        guard !token.isEmpty, let url = URL(string: "\(API.agentWS)/realtime/relay") else { state = .degraded; return }
        var req = URLRequest(url: url)
        req.setBearer(token)                                  // handshake header, same as StatusSession
        let s = URLSession(configuration: .default)
        urlSession = s
        let t = s.webSocketTask(with: req)
        task = t
        t.resume()
        receive()
        state = .live
    }

    private func receive() {
        task?.receive { [weak self] result in
            Task { @MainActor in
                guard let self, !self.closed else { return }
                switch result {
                case .failure:
                    self.state = .degraded            // relay/network dropped — recording continues (caller guarantees)
                case .success(let message):
                    switch message {
                    case .string(let str): self.handle(str)
                    case .data(let d): if let str = String(data: d, encoding: .utf8) { self.handle(str) }
                    @unknown default: break
                    }
                    self.receive()
                }
            }
        }
    }

    private func handle(_ str: String) {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(str.utf8))) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "input_audio_buffer.speech_started": speechEvents += 1; onSpeechStarted?()
        case "input_audio_buffer.speech_stopped": speechEvents += 1; onSpeechStopped?()
        case "response.output_audio.delta":
            audioDeltas += 1
            if let b64 = obj["delta"] as? String, let d = Data(base64Encoded: b64) { onAudioDelta?(d) }
        case "response.done":
            onResponseDone?()
        default:
            // First-connect: log unhandled types to confirm names against the live relay.
            break
        }
    }

    // MARK: - Send

    func appendAudio(_ pcm16le24k: Data) {
        guard !pcm16le24k.isEmpty else { return }
        send(["type": "input_audio_buffer.append", "audio": pcm16le24k.base64EncodedString()])
    }

    func createResponse(maxTokens: Int = 120) {
        send(["type": "response.create", "response": ["max_output_tokens": maxTokens]])
    }

    func cancelResponse() {
        send(["type": "response.cancel"])
    }

    private func send(_ obj: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: d, encoding: .utf8) else { return }
        task?.send(.string(s)) { _ in }
    }

    func disconnect() {
        closed = true
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        state = .idle
    }
}
