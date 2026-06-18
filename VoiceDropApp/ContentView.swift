import SwiftUI
import AuthenticationServices

/// The whole app: one screen, one state machine.
/// needsSignIn -> requesting -> recording -> uploading -> done | failed
struct ContentView: View {

    enum Phase: Equatable {
        case needsSignIn         // not signed in with Apple yet
        case requesting          // asking for mic permission
        case denied              // permission refused
        case recording
        case uploading
        case done                // uploaded, ready for next take
        case failed(String)      // recording stays in the queue
    }

    @State private var recorder = AudioRecorder()
    @State private var uploader = Uploader()
    @State private var location = LocationTagger()
    @State private var authStore = AuthStore.shared
    @State private var phase: Phase = .requesting
    @State private var idCopied = false

    // Interim: zero-login via an anonymous iCloud-Keychain token. Flip to true
    // once Sign in with Apple's App ID capability has propagated on Apple's
    // servers (the SiwA code below stays wired up and ready).
    private let requireAppleSignIn = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            content
            pendingBadge
            myIdBadge
        }
        .task { await begin() }
        .onChange(of: scenePhase) { _, newValue in
            // Coming back to the foreground: drain anything left in the queue.
            guard newValue == .active, phase != .recording, phase != .uploading else { return }
            Task { await drainQueue() }
        }
        .onAppear { recorder.onInterrupted = { take in Task { await self.finalize(take) } } }
    }

    // MARK: - Screens

    @ViewBuilder private var content: some View {
        switch phase {
        case .needsSignIn:
            signInScreen

        case .requesting:
            ProgressView().tint(.white)

        case .denied:
            messageScreen(
                title: "需要麦克风权限",
                subtitle: "VoiceDrop 要用麦克风录音。",
                actionTitle: "去设置",
                action: openSettings
            )

        case .recording:
            recordingScreen

        case .uploading:
            VStack(spacing: 20) {
                ProgressView().tint(.white).scaleEffect(1.4)
                Text("上传中…").foregroundStyle(.white.opacity(0.6)).font(.callout)
            }

        case .done:
            readyScreen(checkmark: true)

        case .failed(let msg):
            VStack(spacing: 28) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 44)).foregroundStyle(.orange)
                Text(msg).foregroundStyle(.white.opacity(0.8))
                    .font(.callout).multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                Text("录音已存好，会自动重传。").foregroundStyle(.white.opacity(0.4)).font(.footnote)
                startButton(title: "再录一条")
            }
        }
    }

    private var signInScreen: some View {
        VStack(spacing: 24) {
            Image(systemName: "waveform")
                .font(.system(size: 56)).foregroundStyle(.white.opacity(0.85))
            Text("VoiceDrop").foregroundStyle(.white).font(.largeTitle.bold())
            Text("用 Apple 登录。你的录音只存在你自己的空间，别人看不到。")
                .foregroundStyle(.white.opacity(0.55)).font(.callout)
                .multilineTextAlignment(.center).padding(.horizontal, 44)
            SignInWithAppleButton(.signIn) { request in
                request.requestedScopes = [.fullName, .email]
            } onCompletion: { result in
                handleSignIn(result)
            }
            .signInWithAppleButtonStyle(.white)
            .frame(height: 50).padding(.horizontal, 44).padding(.top, 8)
            if let err = authStore.lastError {
                Text(err).foregroundStyle(.orange).font(.footnote)
                    .multilineTextAlignment(.center).padding(.horizontal, 44)
            }
        }
    }

    private var recordingScreen: some View {
        VStack {
            Spacer()
            Text(timeString(recorder.elapsed))
                .font(.system(size: 64, weight: .light, design: .monospaced))
                .foregroundStyle(.white)
                .contentTransition(.numericText())
            Spacer()
            Button(action: { Task { await stopAndUpload() } }) {
                ZStack {
                    Circle().fill(.red).frame(width: 88, height: 88)
                    RoundedRectangle(cornerRadius: 6).fill(.white).frame(width: 30, height: 30)
                }
            }
            .accessibilityLabel("停止并上传")
            Text("停止").foregroundStyle(.white.opacity(0.5)).font(.footnote).padding(.top, 8)
            Spacer().frame(height: 60)
        }
    }

    private func readyScreen(checkmark: Bool) -> some View {
        VStack(spacing: 28) {
            if checkmark {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48)).foregroundStyle(.green)
                Text("已上传").foregroundStyle(.white.opacity(0.7)).font(.title3)
            }
            startButton(title: "开始录音")
        }
    }

    private func startButton(title: String) -> some View {
        Button(action: { startRecording() }) {
            ZStack {
                Circle().strokeBorder(.white.opacity(0.6), lineWidth: 3).frame(width: 88, height: 88)
                Circle().fill(.red).frame(width: 64, height: 64)
            }
        }
        .accessibilityLabel(title)
        .overlay(alignment: .bottom) {
            Text(title).foregroundStyle(.white.opacity(0.5)).font(.footnote).offset(y: 30)
        }
    }

    private func messageScreen(title: String, subtitle: String,
                               actionTitle: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 16) {
            Text(title).foregroundStyle(.white).font(.title2.bold())
            Text(subtitle).foregroundStyle(.white.opacity(0.6)).font(.callout)
                .multilineTextAlignment(.center).padding(.horizontal, 40)
            Button(actionTitle, action: action)
                .buttonStyle(.borderedProminent).tint(.white).foregroundStyle(.black)
                .padding(.top, 8)
        }
    }

    // Unobtrusive footer: tap to copy "my id" (the server storage prefix), so
    // 王建硕 can pin which users/anon-<hash>/ folder is his. Hidden while recording.
    @ViewBuilder private var myIdBadge: some View {
        if phase != .recording {
            VStack {
                Spacer()
                Button {
                    UIPasteboard.general.string = authStore.anonId
                    idCopied = true
                } label: {
                    Text(idCopied ? "已复制 ✓" : authStore.anonId)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.white.opacity(0.3))
                }
                .padding(.bottom, 8)
            }
        }
    }

    @ViewBuilder private var pendingBadge: some View {
        if uploader.pendingCount > 0 {
            VStack {
                HStack {
                    Spacer()
                    Label("\(uploader.pendingCount)", systemImage: "arrow.up.circle")
                        .font(.footnote).foregroundStyle(.white.opacity(0.6))
                        .padding(8).background(.white.opacity(0.08), in: Capsule())
                        .padding(.trailing, 16)
                }
                Spacer()
            }
            .padding(.top, 8)
        }
    }

    // MARK: - Flow

    private func begin() async {
        if requireAppleSignIn && !authStore.isAuthenticated { phase = .needsSignIn; return }
        let granted = await AudioRecorder.ensurePermission()
        guard granted else { phase = .denied; return }
        location.start()                // best-effort, never blocks recording
        startRecording()                // start immediately — timer moves at once
        Task { await drainQueue() }     // push up any backlog in the background
    }

    private func startRecording() {
        do {
            try recorder.start()
            phase = .recording
        } catch {
            phase = .failed("无法开始录音：\(error.localizedDescription)")
        }
    }

    private func stopAndUpload() async {
        guard let take = recorder.stop() else { phase = .done; return }
        await finalize(take)
    }

    /// Enrich the provisional filename with duration + weekday/period + place,
    /// rename the file, then upload. Place geocoding is best-effort (3s cap);
    /// if it's unavailable the name simply omits it.
    private func finalize(_ take: AudioRecorder.Recording) async {
        phase = .uploading
        let place = await location.placeTag()
        let finalName = RecordingName.make(start: take.start, duration: take.duration, place: place)
        var toUpload = take.url
        if finalName != take.url.lastPathComponent {
            let finalURL = AudioRecorder.documentsDir.appending(path: finalName)
            do {
                try FileManager.default.moveItem(at: take.url, to: finalURL)
                toUpload = finalURL
            } catch {
                // keep the provisional file — still a valid VoiceDrop-*.m4a upload
            }
        }
        // Mirror to iCloud Drive before upload (upload deletes the local file on
        // success). Off the main thread; best-effort.
        let toArchive = toUpload
        await Task.detached { ICloudArchive.save(toArchive) }.value

        let ok = await uploader.upload(toUpload)
        phase = ok ? .done : .failed(uploader.lastError ?? "上传失败")
    }

    private func drainQueue() async {
        guard !authStore.bearer.isEmpty, uploader.pendingCount > 0 else { return }
        _ = await uploader.drainPending()
    }

    private func handleSignIn(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let auth):
            guard
                let cred = auth.credential as? ASAuthorizationAppleIDCredential,
                let tokenData = cred.identityToken,
                let token = String(data: tokenData, encoding: .utf8)
            else {
                authStore.lastError = "无法获取 Apple 凭证"
                return
            }
            phase = .requesting
            Task {
                await authStore.exchange(identityToken: token)
                if authStore.isAuthenticated { await begin() }
                else { phase = .needsSignIn }
            }
        case .failure(let error):
            let ns = error as NSError
            var parts = ["\(ns.domain) \(ns.code)", ns.localizedDescription]
            if let reason = ns.localizedFailureReason { parts.append(reason) }
            if let under = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
                parts.append("↳ \(under.domain) \(under.code): \(under.localizedDescription)")
            }
            authStore.lastError = parts.joined(separator: "\n")
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    // MARK: - Helpers

    private func timeString(_ t: TimeInterval) -> String {
        let total = Int(t)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

#Preview {
    ContentView().preferredColorScheme(.dark)
}
