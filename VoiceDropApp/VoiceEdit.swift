import SwiftUI
import Speech
import AVFoundation
import Observation

/// Apple on-device speech recognition wrapped for SwiftUI. Streams mic audio into
/// SFSpeechRecognizer and publishes a live partial transcript. zh-CN locale.
@MainActor
@Observable
final class SpeechDictation {
    var transcript = ""
    var isRecording = false
    var authorized: Bool? = nil      // nil = not asked yet
    var error: String?

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    /// Ask for speech + mic permission. Sets `authorized`.
    func requestAuth() async {
        let speech = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }
        let mic = await AVAudioApplication.requestRecordPermission()
        let ok = speech == .authorized && mic
        authorized = ok
        if !ok { error = "需要在设置里允许语音识别和麦克风权限。" }
    }

    func start() {
        guard authorized == true, !isRecording else { return }
        guard let recognizer, recognizer.isAvailable else { error = "语音识别暂不可用。"; return }
        transcript = ""; error = nil
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            request = req

            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
                self?.request?.append(buf)
            }
            engine.prepare()
            try engine.start()
            isRecording = true

            task = recognizer.recognitionTask(with: req) { [weak self] result, err in
                Task { @MainActor in
                    guard let self else { return }
                    if let result { self.transcript = result.bestTranscription.formattedString }
                    if err != nil || (result?.isFinal ?? false) { self.stop() }
                }
            }
        } catch {
            self.error = error.localizedDescription
            stop()
        }
    }

    func stop() {
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        task?.cancel()
        request = nil; task = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

/// A voice box: tap the mic to dictate a revision request for this article,
/// see it transcribed live, then 发送 to save it as the article's PROMPT.md.
struct VoiceEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var dictation = SpeechDictation()
    let onSubmit: (String) async -> Bool

    @State private var sending = false
    @State private var sendFailed = false

    private var canSend: Bool {
        !sending && !dictation.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Text("说出你想怎么改这篇文章，松手后会转成文字发给服务器。")
                    .font(.callout).foregroundStyle(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 24).padding(.top, 8)

                ScrollView {
                    Text(dictation.transcript.isEmpty ? "（还没有内容）" : dictation.transcript)
                        .font(.title3)
                        .foregroundStyle(dictation.transcript.isEmpty ? .white.opacity(0.3) : .white)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(18)
                }
                .frame(maxHeight: .infinity)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 20)

                if let e = dictation.error {
                    Text(e).font(.caption).foregroundStyle(.orange).padding(.horizontal, 20)
                } else if sendFailed {
                    Text("发送失败，请重试。").font(.caption).foregroundStyle(.orange)
                }

                // Big mic toggle.
                Button {
                    if dictation.isRecording { dictation.stop() } else { dictation.start() }
                } label: {
                    Image(systemName: dictation.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                        .font(.system(size: 76))
                        .foregroundStyle(dictation.isRecording ? .red : .white)
                        .symbolEffect(.pulse, isActive: dictation.isRecording)
                }
                .disabled(dictation.authorized != true)
                .padding(.bottom, 12)

                Text(dictation.isRecording ? "正在听…再点一下停止" : "点麦克风开始说")
                    .font(.caption).foregroundStyle(.white.opacity(0.4))
                    .padding(.bottom, 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("语音编辑")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dictation.stop(); dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task {
                            dictation.stop()
                            sending = true; sendFailed = false
                            let text = dictation.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                            let ok = await onSubmit(text)
                            sending = false
                            if ok { dismiss() } else { sendFailed = true }
                        }
                    } label: {
                        if sending { ProgressView().tint(.white) } else { Text("发送").bold() }
                    }
                    .disabled(!canSend)
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { await dictation.requestAuth() }
        .onDisappear { dictation.stop() }
    }
}
