import SwiftUI
import UIKit

/// 成文阅读：听录音 + 读挖出的文章 + 文末一键发布。暖灰阅读底（#F0EDE7）。
struct RecordingDetailView: View {
    let store: LibraryStore
    let recording: Recording

    @Environment(\.dismiss) private var dismiss

    @State private var player = AudioPlayer()
    @State private var doc: ArticleDoc?
    @State private var emptyReason: String?
    @State private var loadingDoc = true
    @State private var loadingAudio = false
    @State private var articleIndex = 0

    @State private var settings = SettingsStore()
    @State private var publishing = false
    @State private var showingWechatSettings = false
    @State private var publishAfterSetup = false
    @State private var toast: String?
    @State private var sharePayload: SharePayload?

    // Live voice editing (in-place, hold-to-talk → agent rewrites the article).
    @State private var editing = false
    @State private var agent = ArticleAgentSession()
    @State private var dictation = SpeechDictation()

    private var articles: [MinedArticle] { doc?.resolvedArticles ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            navBar
            if loadingDoc {
                Spacer(); ProgressView().tint(Theme.accent); Spacer()
            } else if recording.isEmpty {
                Spacer(); emptyState; Spacer()
            } else if articles.isEmpty {
                Spacer(); pending; Spacer()
            } else {
                articlePane
            }
        }
        .background(Theme.readBG.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task {
            if recording.isEmpty {
                emptyReason = await store.fetchEmptyReason(recording)
            } else {
                doc = await store.fetchDoc(recording)
            }
            loadingDoc = false
            await settings.loadWechat()
        }
        .onDisappear { player.stop(); if editing { endEditing() } }
        .sheet(isPresented: $showingWechatSettings, onDismiss: {
            if publishAfterSetup {
                publishAfterSetup = false
                if settings.wechatConfigured { Task { await sendWechat() } }
            }
        }) { WechatSettingsSheet(store: settings) }
        .sheet(item: $sharePayload) { ShareSheet(items: [$0.text]) }
        .overlay(alignment: .bottom) { if editing { editBar } }
        .overlay(alignment: .bottom) { toastView }
    }

    // MARK: Nav bar

    private var navBar: some View {
        HStack {
            NavSquare(systemName: "chevron.left", stroke: Theme.inkRead, border: Theme.borderRead) { dismiss() }
                .accessibilityLabel("返回")
            Spacer()
            if !articles.isEmpty {
                NavSquare(systemName: "square.and.arrow.up", border: Theme.borderRead) { Task { await share() } }
                    .accessibilityLabel("分享")
            }
        }
        .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 8)
    }

    private func share() async {
        if let u = await store.shareURL(recording) { sharePayload = SharePayload(text: u.absoluteString) }
        else { showToast("生成分享链接失败") }
    }

    // MARK: Article pane

    private var articlePane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                playerCard
                    .padding(.top, 6)

                if let a = articles[safe: articleIndex] {
                    Text(a.title)
                        .font(.system(size: 23, weight: .semibold)).foregroundStyle(Theme.inkRead)
                        .lineSpacing(5).fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 26)
                    Text(recording.displayTitle)
                        .font(.system(size: 13)).foregroundStyle(Theme.metaRead)
                        .padding(.top, 8)

                    if articles.count > 1 { chipRow.padding(.top, 16) }

                    Text(bodyAttributed(a))
                        .font(.system(size: 16)).foregroundStyle(Theme.bodyRead)
                        .lineSpacing(9)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, articles.count > 1 ? 16 : 20)

                    publishCard.padding(.top, 26)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, editing ? 160 : 40)
        }
    }

    private var chipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(articles.enumerated()), id: \.offset) { i, a in
                    Button { articleIndex = i } label: {
                        Text(a.title).lineLimit(1)
                            .font(.system(size: 13, weight: i == articleIndex ? .semibold : .regular))
                            .padding(.horizontal, 14).padding(.vertical, 6)
                            .background(i == articleIndex ? Theme.accentSoft : Theme.card,
                                        in: RoundedRectangle(cornerRadius: Theme.R.chip))
                            .overlay(RoundedRectangle(cornerRadius: Theme.R.chip)
                                .stroke(i == articleIndex ? .clear : Theme.borderRead, lineWidth: 1))
                            .foregroundStyle(i == articleIndex ? Theme.accent : Theme.metaRead)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func bodyAttributed(_ a: MinedArticle) -> AttributedString {
        (try? AttributedString(markdown: a.body, options: .init(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible))) ?? AttributedString(a.body)
    }

    // MARK: Publish CTA (end of article)

    private var publishCard: some View {
        VStack(spacing: 12) {
            Text("这篇可以发布了").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.inkRead)
            Text("推送到微信公众号草稿箱，约 1 分钟到达")
                .font(.system(size: 13)).foregroundStyle(Theme.metaRead)
                .multilineTextAlignment(.center)

            Button { Task { await publishWechatTapped() } } label: {
                HStack(spacing: 7) {
                    if publishing { ProgressView().tint(.white) }
                    else { Image(systemName: "paperplane.fill").font(.system(size: 14)) }
                    Text("发布公众号").font(.system(size: 15, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.vertical, 13).padding(.horizontal, 22)
                .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.R.primary))
                .accentButtonShadow()
            }
            .buttonStyle(.plain)
            .disabled(publishing || editing)

            HStack(spacing: 0) {
                Text("想改改？").font(.system(size: 14)).foregroundStyle(Theme.metaRead)
                Button { startEditing() } label: {
                    Text("用语音修改").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain).disabled(editing)
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.R.primary))
        .overlay(RoundedRectangle(cornerRadius: Theme.R.primary).stroke(Theme.borderRead, lineWidth: 1))
    }

    // MARK: Player card

    private var playerCard: some View {
        HStack(spacing: 14) {
            Button {
                if player.duration == 0 { Task { await loadAndPlay() } } else { player.toggle() }
            } label: {
                RoundedRectangle(cornerRadius: Theme.R.tile)
                    .fill(Theme.accent)
                    .frame(width: 48, height: 48)
                    .overlay(
                        Image(systemName: loadingAudio ? "arrow.down" : (player.isPlaying ? "pause.fill" : "play.fill"))
                            .font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                            .symbolEffect(.pulse, isActive: loadingAudio)
                    )
            }
            .buttonStyle(.plain).disabled(loadingAudio)

            VStack(spacing: 7) {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color(hex: "E7E0D5")).frame(height: 4)
                        Capsule().fill(Theme.accent).frame(width: max(0, g.size.width * player.progress), height: 4)
                    }
                }
                .frame(height: 4)
                HStack {
                    Text(currentTime).font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.metaRead)
                    Spacer()
                    Text(totalTime).font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.metaRead)
                }
            }
        }
        .padding(.vertical, 14).padding(.horizontal, 16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.R.player))
        .overlay(RoundedRectangle(cornerRadius: Theme.R.player).stroke(Theme.borderRead, lineWidth: 1))
        .cardReadShadow()
    }

    private var currentTime: String { fmt(player.duration > 0 ? player.progress * player.duration : 0) }
    private var totalTime: String { player.duration > 0 ? fmt(player.duration) : (recording.durationLabel ?? "--:--") }
    private func fmt(_ s: TimeInterval) -> String { let t = Int(s); return String(format: "%02d:%02d", t / 60, t % 60) }

    private func loadAndPlay() async {
        loadingAudio = true; defer { loadingAudio = false }
        if let url = await store.downloadAudio(recording) { player.load(url); player.toggle() }
    }

    // MARK: Empty / pending

    private var pending: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath").font(.system(size: 36)).foregroundStyle(Theme.faint)
            Text("还没成文").foregroundStyle(Theme.inkRead).font(.system(size: 17, weight: .semibold))
            Text("服务器每 2 小时自动处理一次，过会儿再来看。")
                .foregroundStyle(Theme.secondary).font(.system(size: 15))
                .multilineTextAlignment(.center).padding(.horizontal, 40)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "speaker.slash").font(.system(size: 36)).foregroundStyle(Theme.faint)
            Text("没检测到语音").foregroundStyle(Theme.inkRead).font(.system(size: 17, weight: .semibold))
            Text(emptyReasonText).foregroundStyle(Theme.secondary).font(.system(size: 15))
                .multilineTextAlignment(.center).padding(.horizontal, 40)
        }
    }

    private var emptyReasonText: String {
        switch emptyReason {
        case "corrupt": return "这条录音的文件损坏了，没法转写。"
        case "silent":  return "这条录音太短或几乎是静音，没有可转写的内容。"
        default:        return "这条录音里没有识别到说话声，已标记为无语音。"
        }
    }

    // MARK: Voice editing (live agent)

    private func startEditing() {
        editing = true
        agent.onUpdate = { newDoc in
            doc = newDoc
            articleIndex = min(articleIndex, max(0, newDoc.resolvedArticles.count - 1))
        }
        agent.connect(recording)
        Task { await dictation.requestAuth() }
    }

    private func endEditing() {
        dictation.stop(); agent.disconnect(); editing = false
    }

    private var editBar: some View {
        let busy = agent.state == .working
        return VStack(spacing: 10) {
            if dictation.isRecording && !dictation.transcript.isEmpty {
                Text(dictation.transcript)
                    .font(.system(size: 15)).foregroundStyle(Theme.inkRead)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.borderRead, lineWidth: 1))
                    .padding(.horizontal, 16)
            }

            HStack(spacing: 14) {
                Button { endEditing() } label: {
                    Text("完成").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.plain)

                Text(holdLabel(busy: busy))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(dictation.isRecording ? .white : Theme.ink)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(dictation.isRecording ? Theme.accent : Theme.tileNeutral, in: Capsule())
                    .overlay(alignment: .trailing) {
                        if busy { ProgressView().tint(Theme.accent).padding(.trailing, 18) }
                        else {
                            Image(systemName: dictation.isRecording ? "waveform" : "mic.fill")
                                .foregroundStyle(dictation.isRecording ? .white : Theme.secondary)
                                .padding(.trailing, 18)
                        }
                    }
                    .contentShape(Capsule())
                    .gesture(holdGesture(disabled: busy || dictation.authorized != true))
            }
            .padding(.horizontal, 16)

            if let e = agent.error ?? dictation.error {
                Text(e).font(.system(size: 12)).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 14)
        .background(Theme.card)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 20, topTrailingRadius: 20))
        .overlay(alignment: .top) { Rectangle().fill(Theme.borderRead).frame(height: 1) }
        .shadow(color: .black.opacity(0.06), radius: 12, x: 0, y: -4)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func holdLabel(busy: Bool) -> String {
        if busy { return "正在修改…" }
        if dictation.authorized != true { return "需要麦克风权限" }
        return dictation.isRecording ? "松开发送" : "按住说出修改要求"
    }

    private func holdGesture(disabled: Bool) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard !disabled, !dictation.isRecording else { return }
                dictation.start()
            }
            .onEnded { _ in
                guard dictation.isRecording else { return }
                dictation.stop()
                let text = dictation.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { agent.send(text) }
            }
    }

    // MARK: Publish (WeChat)

    private func publishWechatTapped() async {
        await settings.loadWechat()
        guard settings.wechatConfigured else {
            publishAfterSetup = true
            showingWechatSettings = true
            return
        }
        await sendWechat()
    }

    private func sendWechat() async {
        publishing = true
        let result = await store.publishWechat(recording)
        publishing = false
        switch result {
        case .ok:
            showToast("已推送，约 1 分钟后到草稿箱")
        case .notConfigured:
            // Server says WeChat isn't configured (local state was stale) — open
            // the config sheet and continue the publish once saved.
            publishAfterSetup = true
            showingWechatSettings = true
        case .failed:
            showToast("推送失败，请稍后再试")
        }
    }

    private func showToast(_ msg: String) {
        toast = msg
        Task {
            try? await Task.sleep(nanoseconds: 2_800_000_000)
            if toast == msg { toast = nil }
        }
    }

    @ViewBuilder private var toastView: some View {
        if let toast {
            Text(toast)
                .font(.system(size: 15)).foregroundStyle(Theme.inkRead)
                .padding(.horizontal, 18).padding(.vertical, 12)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(Theme.borderRead, lineWidth: 1))
                .padding(.bottom, editing ? 130 : 32)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// A ready-to-share payload (article excerpt + short link), one String.
struct SharePayload: Identifiable { let text: String; var id: String { text } }

/// The system share sheet (UIActivityViewController) for SwiftUI.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
