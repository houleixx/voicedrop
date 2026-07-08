import Foundation
import Observation

/// Orchestrates a recording session with an ON-DEMAND AI interviewer overlay.
///
/// ARCHITECTURE (2026-07-08, "采访 = 录音的可叠加旁路"): recording and the interview
/// are decoupled. `start()` starts ONLY the `EngineRecorder` (two-engine, no VPIO —
/// VPIO gave 0 mic buffers on this device) — that's the sacred main path, writing the
/// m4a from the tap unconditionally. The AI interview is a SIDE-PATH the user toggles
/// on/off mid-recording via the 采访 button: `toggleInterview()` connects/disconnects
/// the relay WS. The tap's PCM tee feeds the relay only while the interview is active;
/// the file write never depends on any of this.
///
/// Turn-taking is SERVER/PROMPT-driven: the worker configures `semantic_vad` +
/// `create_response:true` + `interrupt_response:false`, and the interviewer
/// instructions tell the model to stay silent and only interject when the speaker
/// is stuck. No app-side timer here.
///
/// HALF-DUPLEX (no AEC): the AI's loudspeaker leaks into the mic, so while the AI is
/// speaking we PAUSE the uplink (mute) and resume only after response.done AND the
/// playback has drained + a short echo tail — otherwise the model hears its own tail
/// and loops. AI audio in the recording is acceptable (user-confirmed).
///
/// Each toggle-on → toggle-off is an independent relay session; the worker settles
/// billing on WS close.
@MainActor
@Observable
final class RealtimeInterviewer: RecordingBackend {
    let engine = EngineRecorder()
    let session = RealtimeSession()

    /// The interview side-path is currently on (relay connected or connecting).
    private(set) var interviewActive = false
    private(set) var connState: RealtimeSession.State = .idle

    // Half-duplex state — see class comment.
    private var aiSpeaking = false
    private var aiTurnEnded = false          // OpenAI finished GENERATING (response.done)
    private var resumeTask: Task<Void, Never>?
    private var muteWatchdog: Task<Void, Never>?

    var onInterrupted: ((AudioRecorder.Recording) -> Void)? {
        get { engine.onInterrupted }
        set {
            guard let handler = newValue else { engine.onInterrupted = nil; return }
            engine.onInterrupted = { [weak self] take in
                // 来电/Siri 中断走 engine 级 stop,这里补上采访侧的收尾:立刻断 relay
                // (worker 在 WS close 时结算这段计费),别让计费表跟着中断悬空地走。
                if let self, self.interviewActive { self.stopInterview() }
                handler(take)
            }
        }
    }

    /// Start RECORDING only (sacred). The interview is NOT connected here — the user
    /// toggles it with the 采访 button. Throws only if recording can't start.
    func start() throws {
        wireCallbacks()
        try engine.start()
    }

    /// 采访 button: toggle the AI side-path. Recording is never touched.
    func toggleInterview() {
        if interviewActive { stopInterview() } else { startInterview() }
    }

    private func startInterview() {
        guard engine.isRecording else { return }
        interviewActive = true
        aiSpeaking = false
        aiTurnEnded = false
        engine.teeEnabled = true  // Sink starts producing 24k PCM only from here on
        session.connect()       // best-effort; failure = degraded badge, recording continues
    }

    private func stopInterview() {
        interviewActive = false
        engine.teeEnabled = false // Sink stops the resample/tee — plain recording pays nothing
        resumeTask?.cancel(); resumeTask = nil
        muteWatchdog?.cancel(); muteWatchdog = nil
        aiSpeaking = false
        aiTurnEnded = false
        engine.stopAIPlayback()   // silence any in-flight AI speech immediately
        session.disconnect()      // worker settles this segment's billing on close
    }

    private func wireCallbacks() {
        session.onStateChange     = { [weak self] s in self?.connState = s }
        session.onResponseCreated = { [weak self] in self?.beginAiTurn() }             // AI about to speak
        session.onAudioDelta      = { [weak self] pcm in
            guard let self, self.interviewActive else { return }   // toggle-off: drop late audio
            self.beginAiTurn(); self.engine.playAI(pcm)
        }
        session.onResponseDone    = { [weak self] in self?.aiTurnEnded = true; self?.tryResume() }
        engine.onPlaybackDrained  = { [weak self] in self?.tryResume() }               // AI audio finished PLAYING
        engine.onPCM              = { [weak self] pcm in
            // The tee feeds the AI ONLY while interviewing and the AI isn't speaking
            // (half-duplex). The m4a write happened before this callback, always.
            guard let self, self.interviewActive, !self.aiSpeaking else { return }
            self.session.appendAudio(pcm)
        }
    }

    private func beginAiTurn() {
        guard interviewActive else { return }
        resumeTask?.cancel(); resumeTask = nil
        aiSpeaking = true
        aiTurnEnded = false
        // Safety: never stay muted forever if a done/drain signal is somehow missed.
        muteWatchdog?.cancel()
        muteWatchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled else { return }
            self?.aiSpeaking = false
        }
    }

    /// Resume the uplink ONLY after the AI has finished generating (response.done)
    /// AND its audio has finished playing (playback drained), plus a short echo tail.
    private func tryResume() {
        guard aiSpeaking, aiTurnEnded, engine.isPlaybackIdle else { return }
        resumeTask?.cancel()
        resumeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))   // room echo tail
            guard !Task.isCancelled else { return }
            self?.muteWatchdog?.cancel()
            self?.aiSpeaking = false
        }
    }

    @discardableResult
    func stop() -> AudioRecorder.Recording? {
        if interviewActive { stopInterview() }
        return engine.stop()
    }

    // Proxy the recording UI state to the engine.
    var isRecording: Bool { engine.isRecording }
    var elapsed: TimeInterval { engine.elapsed }
    var level: Double { engine.level }
    var startDate: Date? { engine.startDate }
}
