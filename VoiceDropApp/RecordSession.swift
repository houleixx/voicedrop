import SwiftUI
import AVFoundation

/// Full-screen recording takeover (方案二): launched from the red record key on
/// the 我的录音 list. Starts recording on appear → big stopwatch + live waveform
/// → stop. On stop it promotes the take into the upload queue and closes
/// immediately — the *list* shows it as 正在上传 and does the upload.
///
/// BACKEND (2026-07-08): every recording uses the AVAudioEngine backend (via
/// `RealtimeInterviewer`) so the AI 采访员 can be toggled ON MID-RECORDING with the
/// 采访 key left of 停止 (mirroring 拍照 on the right). The m4a is written from the
/// tap unconditionally — the interview is a pure side-path and can never touch it.
/// Escape hatch: 设置 → 数据与备份 → 经典录音引擎 switches back to the battle-tested
/// AVAudioRecorder path (no 采访 key) in case the engine misbehaves on some device.
struct RecordSession: View {
    /// When launched from a tag tab: the article mined from this take should
    /// default-carry that tag. Written as a local sidecar at promote time and
    /// uploaded with the take (survives offline queueing / app restarts).
    var defaultTag: String? = nil
    /// Dismiss back to the list (after stop, or cancel).
    var onFinish: () -> Void

    enum Phase: Equatable { case starting, denied, recording, failed(String) }

    /// Escape hatch (Prefs.classicRecorder): true = old AVAudioRecorder path.
    /// @State (not a plain let) PINS the choice for the whole session: the View struct
    /// is re-initialized on every parent re-render, and a mid-take pref flip would
    /// otherwise route stop()/onDisappear to the backend that never started.
    @State private var classic = Prefs.shared.classicRecorder
    @State private var recorder = AudioRecorder()
    @State private var interviewer = RealtimeInterviewer()
    @State private var location = LocationTagger()
    @State private var phase: Phase = .starting

    // Photo capture (hidden feature)
    @State private var sessionStart: Date?
    @State private var showCamera = false

    // Live UI state from whichever backend is active this session.
    // Read the engine's observed props DIRECTLY (not through a computed passthrough)
    // so SwiftUI reliably tracks the nested @Observable and the stopwatch updates.
    private var activeElapsed: TimeInterval { classic ? recorder.elapsed : interviewer.engine.elapsed }
    private var activeLevel: Double { classic ? recorder.level : interviewer.engine.level }
    private var interviewStatusText: String {
        switch interviewer.connState {
        case .connecting: return "AI 连接中…"
        case .live: return "AI 采访中 · 再点一下结束"
        case .degraded: return "AI 已断开 · 录音继续"
        case .idle: return ""
        }
    }

    var body: some View {
        ZStack {
            Theme.appBG.ignoresSafeArea()
            switch phase {
            case .starting:
                ProgressView().tint(Theme.recordRed)
            case .denied:
                messageScreen(title: "需要麦克风权限", subtitle: "VoiceDrop 要用麦克风录音。", primary: "去设置") { openSettings() }
            case .recording:
                recordingScreen
            case .failed(let msg):
                messageScreen(title: "录音出错", subtitle: msg, primary: "好") { onFinish() }
            }
        }
        .task {
            let onInt: (AudioRecorder.Recording) -> Void = { take in Task { await promote(take); onFinish() } }
            if classic { recorder.onInterrupted = onInt } else { interviewer.onInterrupted = onInt }
            let granted = await AudioRecorder.ensurePermission()
            guard granted else { phase = .denied; return }
            // Pre-warm the audio route so the FIRST cold start isn't laggy (第一次卡顿):
            // session activation + settle happens behind the spinner.
            if !classic { await EngineRecorder.prewarm() }
            location.start()
            // Use the backend's OWN start instant as the session id, so the photo
            // folder key matches the audio filename to the second (don't take a
            // separate Date() — it drifts across a second boundary).
            do {
                if classic { try recorder.start(); sessionStart = recorder.startDate }
                else { try interviewer.start(); sessionStart = interviewer.startDate }
                phase = .recording
            }
            catch { phase = .failed("无法开始录音：\(error.localizedDescription)") }
        }
        .onDisappear {
            // Safety net: any teardown path that didn't run stop() (a future dismissal
            // route, cover replacement) must still promote the take — recording is
            // sacred. The normal stop() already consumed it, so this is nil then.
            if let take = classic ? recorder.stop() : interviewer.stop() {
                Task { await promote(take) }
            }
        }
        .fullScreenCover(isPresented: $showCamera) {
            // The camera stays open for continuous shooting; shots collect in a
            // filmstrip (deletable) and are all uploaded when the user taps 完成.
            // Read sessionStart once here (on main) so the upload closure captures
            // a plain Date?, not the actor-isolated view property.
            let scope = sessionStart
            PhotoCaptureView(recordingStart: scope) { captured in
                showCamera = false
                for photo in captured {
                    Task { await Self.uploadPhoto(date: photo.date, data: photo.data, sessionStart: scope) }
                }
            }
            .ignoresSafeArea()
        }
    }

    // MARK: Recording (frame ②)

    private var recordingScreen: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Circle().fill(Theme.recordRed).frame(width: 9, height: 9)
                    Text(interviewer.interviewActive ? "AI 采访中" : "正在录音")
                        .font(.system(size: 14)).tracking(2).foregroundStyle(Theme.secondary)
                }
                if interviewer.interviewActive {
                    Text(interviewStatusText).font(.system(size: 11)).tracking(1).foregroundStyle(Theme.faint)
                }
                // Engine faults must be visible in EVERY take, not only while interviewing —
                // the engine backend records all plain memos now, and a silent capture
                // failure with a happily ticking stopwatch is unrecoverable data loss.
                if !classic, !interviewer.interviewActive, let err = interviewer.engine.engineError {
                    Text("⚠️ \(err)")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.recordRed)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32).padding(.top, 2)
                }
            }
            .padding(.top, 64)

            Spacer()
            VStack(spacing: 34) {
                Text(timeString(activeElapsed))
                    .font(.system(size: 78, weight: .ultraLight).monospacedDigit())
                    .foregroundStyle(Theme.ink)
                    .contentTransition(.numericText())
                waveform
            }
            Spacer()

            VStack(spacing: 7) {
                Button { Task { await stop() } } label: {
                    Circle().fill(Theme.card).frame(width: 66, height: 66)
                        .overlay(Circle().stroke(Color(hex: "E8DECF"), lineWidth: 1))
                        .overlay(RoundedRectangle(cornerRadius: 6).fill(Theme.recordRed).frame(width: 26, height: 26))
                        .shadow(color: .black.opacity(0.06), radius: 7, x: 0, y: 4)
                }
                .buttonStyle(.plain).accessibilityLabel("停止")
                // Faint 拍照 trigger: a very subtle camera icon in the blank area to the
                // right of the 停止 key (≈75% of screen width). Overlaid on the 停止 circle
                // so the 停止 key stays整屏居中. Camera uses AVCaptureSession (video-only)
                // so recording is not interrupted.
                .overlay(alignment: .center) {
                    Image(systemName: "camera")
                        .font(.system(size: 24, weight: .light))
                        .foregroundStyle(Color(hex: "A89E8E"))
                        .opacity(0.45)
                        .frame(width: 42, height: 42)
                        .contentShape(Rectangle())
                        .onTapGesture { Task { await openCamera() } }
                        .overlay(alignment: .top) {
                            Text("拍照")
                                .font(.system(size: 11)).tracking(2)
                                .foregroundStyle(Color(hex: "C2B8A8"))
                                .fixedSize()
                                .offset(y: 42)
                        }
                        .accessibilityLabel("拍照")
                        .accessibilityAddTraits(.isButton)
                        .offset(x: 98)   // 右侧空白区水平中点 ≈ 屏宽 75%（中线右移 25%）
                }
                // 采访 toggle — mirrors 拍照 on the LEFT of the 停止 key. Tap to connect the
                // AI interviewer mid-recording; tap again to end it. Recording is a pure
                // main-path and is never interrupted by any of this. Hidden on the classic
                // (escape-hatch) backend, which can't tee PCM.
                .overlay(alignment: .center) {
                    if !classic {
                        Image(systemName: "waveform.and.mic")
                            .font(.system(size: 24, weight: .light))
                            .foregroundStyle(interviewer.interviewActive ? Theme.accent : Color(hex: "A89E8E"))
                            .opacity(interviewer.interviewActive ? 1.0 : 0.45)
                            .frame(width: 42, height: 42)
                            .contentShape(Rectangle())
                            .onTapGesture { interviewer.toggleInterview() }
                            .overlay(alignment: .top) {
                                Text("采访")
                                    .font(.system(size: 11)).tracking(2)
                                    .foregroundStyle(interviewer.interviewActive ? Theme.accent : Color(hex: "C2B8A8"))
                                    .fixedSize()
                                    .offset(y: 42)
                            }
                            .accessibilityLabel(interviewer.interviewActive ? "结束采访" : "开始采访")
                            .accessibilityAddTraits(.isButton)
                            .offset(x: -98)   // 左侧空白区水平中点，与右侧拍照对称
                    }
                }
                Text("点击停止").font(.system(size: 12)).tracking(1).foregroundStyle(Theme.secondary)
            }
            .padding(.bottom, 26)
        }
    }

    private var waveform: some View {
        let pattern: [Double] = [0.30, 0.56, 0.82, 0.48, 0.95, 0.65, 0.38, 0.74, 0.52, 0.86, 0.34, 0.62, 0.44]
        return HStack(alignment: .bottom, spacing: 3) {
            ForEach(pattern.indices, id: \.self) { i in
                let frac = pattern[i] * (0.22 + activeLevel * 0.95)
                RoundedRectangle(cornerRadius: 2)
                    .fill(barColor(frac))
                    .frame(width: 3, height: max(6, 46 * frac))
            }
        }
        .frame(height: 46)
        .animation(.easeOut(duration: 0.1), value: activeLevel)
    }

    private func barColor(_ frac: Double) -> Color {
        if frac > 0.6 { return Theme.recordRed }
        if frac > 0.3 { return Color(hex: "EBA89F") }
        return Color(hex: "E5C8C3")
    }

    private func messageScreen(title: String, subtitle: String, primary: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 16) {
            Text(title).font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.ink)
            Text(subtitle).font(.system(size: 16)).foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 40)
            Button(action: action) {
                Text(primary).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    .padding(.vertical, 13).padding(.horizontal, 24)
                    .background(Theme.recordRed, in: RoundedRectangle(cornerRadius: Theme.R.primary))
            }
            .buttonStyle(.plain).padding(.top, 4)
            Button("取消") { onFinish() }.tint(Theme.secondary)
        }
    }

    // MARK: Flow

    private func stop() async {
        let take = classic ? recorder.stop() : interviewer.stop()
        guard let take else {
            // Engine refused to hand over a take (e.g. the m4a was never created).
            // Show a REAL failure instead of silently closing as if nothing happened.
            if !classic, let err = interviewer.engine.engineError {
                phase = .failed("录音失败：\(err)")
            } else { onFinish() }
            return
        }
        await promote(take)
        onFinish()                    // close — the list shows 正在上传 and uploads
    }

    /// Promote the staging take into the upload queue (enriched name + iCloud
    /// mirror). No upload here — the list drains the queue. Place geocoding is
    /// best-effort and usually instant (location already resolved during the take).
    private func promote(_ take: AudioRecorder.Recording) async {
        let url = await RecordingPromoter.promote(take, place: await location.placeTag())
        if let tag = defaultTag { Uploader.writeTagsSidecar(for: url, tags: [tag]) }
    }

    // MARK: Photo capture (hidden)

    private func openCamera() async {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        if status == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .video)
        }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
        showCamera = true
    }

    /// Upload a captured/picked photo to R2 at photos/<sessionStartTs>/<captureTs>.jpg.
    /// The folder is the recording's start timestamp (same source as the audio
    /// filename) so the miner correlates photos with the right recording. Static +
    /// @MainActor: called from the camera VC's @Sendable callback, capturing only
    /// the Sendable sessionStart (not the non-Sendable RecordSession view).
    @MainActor
    private static func uploadPhoto(date: Date, data: Data, sessionStart: Date?) async {
        guard let start = sessionStart else { return }
        let offset = Int(date.timeIntervalSince(start))   // 录音开始后第几秒拍的
        let key = RecordingName.photoKey(sessionTs: RecordingName.timestamp(start), offset: offset)
        await PhotoService.upload(data: data, relKey: key, bearer: AuthStore.shared.bearer)
    }

    private func openSettings() {
        if let u = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(u) }
    }

    private func timeString(_ t: TimeInterval) -> String { t.clockString }
}
