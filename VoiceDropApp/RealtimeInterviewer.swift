import Foundation
import Observation

/// Orchestrates a realtime AI-interviewer recording session: owns the
/// `EngineRecorder` (single-capture tee) and the `RealtimeSession` (relay WS),
/// wires mic PCM → relay and AI audio → speaker, and runs the app-side turn logic
/// (only ask a follow-up after ≥5 s of silence, rate-limited — the AI is otherwise
/// a silent listener, since the worker configured `create_response:false`).
///
/// Recording is sacred: `engine.start()` runs first; the relay is best-effort and
/// any failure just degrades (recording continues). Billing is server-side.
@MainActor
@Observable
final class RealtimeInterviewer {
    let engine = EngineRecorder()
    let session = RealtimeSession()

    private(set) var connState: RealtimeSession.State = .idle

    /// One-line diagnostics for the on-screen overlay (realtime mode).
    var debugLine: String {
        "tap \(engine.tapBuffers) · WS \(connState.rawValue) · 语音 \(session.speechEvents) · AI音 \(session.audioDeltas)"
            + (engine.engineError.map { " · ⚠️\($0)" } ?? "")
    }

    // Turn logic (constants device-tunable).
    private let silenceThreshold: TimeInterval = 5   // ask only after ≥5 s pause
    private let minGap: TimeInterval = 20            // rate-limit between follow-ups
    private var lastAskAt: Date = .distantPast
    private var hadNewSpeechSinceAsk = false
    private var aiSpeaking = false
    private var silenceTask: Task<Void, Never>?

    var onInterrupted: ((AudioRecorder.Recording) -> Void)? {
        get { engine.onInterrupted }
        set { engine.onInterrupted = newValue }
    }

    /// Start recording (sacred) + connect the relay. Throws only if RECORDING can't
    /// start — the relay never throws here (failure = degraded, recording continues).
    func start() throws {
        session.onStateChange   = { [weak self] s in self?.connState = s }
        session.onAudioDelta    = { [weak self] pcm in self?.aiSpeaking = true; self?.engine.playAI(pcm) }
        session.onResponseDone  = { [weak self] in self?.aiSpeaking = false }
        session.onSpeechStarted = { [weak self] in self?.handleSpeechStarted() }
        session.onSpeechStopped = { [weak self] in self?.handleSpeechStopped() }
        engine.onPCM            = { [weak self] pcm in self?.session.appendAudio(pcm) }

        try engine.start()      // if this throws, nothing else has run — no AI, no relay
        session.connect()       // best-effort
    }

    @discardableResult
    func stop() -> AudioRecorder.Recording? {
        silenceTask?.cancel(); silenceTask = nil
        session.disconnect()    // worker settles billing on close
        return engine.stop()
    }

    // Proxy the recording UI state to the active engine.
    var isRecording: Bool { engine.isRecording }
    var elapsed: TimeInterval { engine.elapsed }
    var level: Double { engine.level }

    // MARK: - Turn logic

    private func handleSpeechStarted() {
        silenceTask?.cancel(); silenceTask = nil
        hadNewSpeechSinceAsk = true
        if aiSpeaking { session.cancelResponse(); aiSpeaking = false }   // barge-in: don't talk over the speaker
    }

    private func handleSpeechStopped() {
        silenceTask?.cancel()
        silenceTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(self.silenceThreshold))
            guard !Task.isCancelled else { return }
            let now = Date()
            guard self.hadNewSpeechSinceAsk, now.timeIntervalSince(self.lastAskAt) >= self.minGap else { return }
            self.session.createResponse(maxTokens: 120)   // concise (<5 s) follow-up; worker instructions cap it
            self.lastAskAt = now
            self.hadNewSpeechSinceAsk = false
        }
    }
}
