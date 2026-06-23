import SwiftUI
import UIKit

/// A transient one-line reply from the editing agent.
struct AgentReply: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let ok: Bool
}

/// 成文阅读：听录音 + 读挖出的文章 + 一键发布。暖灰阅读底（#F0EDE7）。
/// 右上角 ⋯ 菜单（发布公众号草稿 / 分享）；底部常驻一条微信式按住说话 bar。
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
    @State private var community = CommunityStore()
    @State private var published = false            // already has a WeChat draft
    @State private var sharedToCommunity = false    // already shared to the community
    @State private var communityShareId: String?    // shareId when shared (needed for unshare)

    // Live voice editing — persistent push-to-talk bar.
    @State private var agentReply: AgentReply?
    @State private var replyHeld = false
    @State private var agent = ArticleAgentSession()
    @State private var dictation = SpeechDictation()
    @State private var willCancel = false           // slid finger up past threshold
    @State private var connected = false

    private var articles: [MinedArticle] { doc?.resolvedArticles ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            navBar
            if loadingDoc {
                Spacer(); ProgressView().tint(Theme.accent); Spacer()
            } else if recording.isEmpty {
                emptyState
            } else if articles.isEmpty {
                pending
            } else {
                articlePane
            }
        }
        .background(Theme.readBG.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .bottom) { if !articles.isEmpty { voiceBar } }
        .overlay(alignment: .bottom) { toastView }
        .task {
            if recording.isEmpty {
                emptyReason = await store.fetchEmptyReason(recording)
            } else {
                doc = await store.fetchDoc(recording)
            }
            loadingDoc = false
            published = doc?.hasWechatDraft ?? false
            await settings.loadWechat()
            await connectIfNeeded()
            if !articles.isEmpty {
                communityShareId = await community.sharedShareId(recording)
                sharedToCommunity = communityShareId != nil
            }
        }
        .onDisappear { player.stop(); dictation.stop(); agent.disconnect() }
        .sheet(isPresented: $showingWechatSettings, onDismiss: {
            if publishAfterSetup {
                publishAfterSetup = false
                if settings.wechatConfigured { Task { await sendWechat() } }
            }
        }) { WechatSettingsSheet(store: settings) }
        .sheet(item: $sharePayload) { ShareSheet(items: [$0.text]) }
    }

    /// Open the editing socket + ask for mic/speech once the article is loaded.
    private func connectIfNeeded() async {
        guard !connected, !articles.isEmpty else { return }
        connected = true
        agent.onUpdate = { newDoc in
            doc = newDoc
            articleIndex = min(articleIndex, max(0, newDoc.resolvedArticles.count - 1))
            showToast("已更新")
        }
        agent.onReply = { text, ok in
            let reply = AgentReply(text: text, ok: ok)
            agentReply = reply
            if ok { scheduleReplyDismiss(reply) }
        }
        agent.connect(recording)
        await dictation.requestAuth()
    }

    // MARK: Nav bar

    private var navBar: some View {
        HStack {
            NavSquare(systemName: "chevron.left", stroke: Theme.inkRead, border: Theme.borderRead) { dismiss() }
                .accessibilityLabel("返回")
            Spacer()
            if !articles.isEmpty {
                Menu {
                    Button { Task { await publishWechatTapped() } } label: {
                        Label(published ? "更新公众号草稿" : "发布公众号草稿", systemImage: "paperplane")
                    }
                    Toggle(isOn: Binding(
                        get: { sharedToCommunity },
                        set: { newValue in Task { await toggleCommunity(newValue) } }
                    )) {
                        Label("VD社区可见", systemImage: "person.2")
                    }
                    Button { Task { await share() } } label: {
                        Label("分享", systemImage: "square.and.arrow.up")
                    }
                } label: {
                    RoundedRectangle(cornerRadius: Theme.R.nav)
                        .fill(Theme.ink)
                        .frame(width: 38, height: 38)
                        .overlay {
                            if publishing { ProgressView().tint(.white) }
                            else { Image(systemName: "ellipsis").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white) }
                        }
                        .navButtonShadow()
                }
                .accessibilityLabel("更多")
            }
        }
        .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 8)
    }

    private func share() async {
        if let u = await store.shareURL(recording) { sharePayload = SharePayload(text: u.absoluteString) }
        else { showToast("生成分享链接失败") }
    }

    private func toggleCommunity(_ visible: Bool) async {
        if visible {
            let shareId = await community.share(recording)
            if let shareId {
                communityShareId = shareId
                sharedToCommunity = true
                showToast("已在 VD社区可见")
            } else {
                sharedToCommunity = false
                showToast("分享失败，请稍后再试")
            }
        } else {
            guard let shareId = communityShareId else { return }
            sharedToCommunity = false
            let ok = await community.unshare(shareId)
            if ok {
                communityShareId = nil
                showToast("已从 VD社区隐藏")
            } else {
                sharedToCommunity = true
                showToast("操作失败，请稍后再试")
            }
        }
    }

    // MARK: Article pane

    private var articlePane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                playerCard.padding(.top, 6)

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
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
        }
        .contentMargins(.bottom, 96, for: .scrollContent)   // clear the floating pill
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

    /// Non-成文 states still keep the audio player up top so you can replay the take.
    private func statusScreen(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 0) {
            playerCard.padding(.horizontal, 20).padding(.top, 6)
            Spacer(minLength: 24)
            VStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 36)).foregroundStyle(Theme.faint)
                Text(title).foregroundStyle(Theme.inkRead).font(.system(size: 17, weight: .semibold))
                Text(subtitle).foregroundStyle(Theme.secondary).font(.system(size: 15))
                    .multilineTextAlignment(.center).padding(.horizontal, 40)
            }
            Spacer(minLength: 24)
        }
    }

    private var pending: some View {
        statusScreen(icon: "clock.arrow.circlepath", title: "还没成文",
                     subtitle: "服务器每小时自动处理一次，过会儿再来看。")
    }

    private var emptyState: some View {
        statusScreen(icon: "speaker.slash", title: "没检测到语音", subtitle: emptyReasonText)
    }

    private var emptyReasonText: String {
        switch emptyReason {
        case "corrupt": return "这条录音的文件损坏了，没法转写。"
        case "silent":  return "这条录音太短或几乎是静音，没有可转写的内容。"
        default:        return "这条录音里没有识别到说话声，已标记为无语音。"
        }
    }

    // MARK: Push-to-talk bar (按住说话，仿微信)

    private var voiceBar: some View {
        let recording = dictation.isRecording
        let working = agent.state == .working
        let firstId = agent.queue.first?.id
        return VStack(spacing: 8) {
            if let reply = agentReply { replyBubble(reply) }
            // Pending edits pile up here — newest on top, the one in flight sits
            // just above the button and drains first; each builds on the last.
            ForEach(agent.queue.reversed()) { req in
                queueRow(req, inFlight: req.id == firstId)
            }
            if recording { darkBubble(dictation.transcript) }
            pill(recording: recording, working: working)
                .shadow(color: .black.opacity(0.10), radius: 12, x: 0, y: 5)   // float over the body
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.22), value: agent.queue)
        .animation(.easeInOut(duration: 0.18), value: recording)
        .animation(.easeInOut(duration: 0.22), value: agentReply)
    }

    /// One queued instruction. The in-flight head is highlighted; the rest wait.
    private func queueRow(_ req: ArticleAgentSession.EditRequest, inFlight: Bool) -> some View {
        HStack(spacing: 8) {
            if inFlight {
                Image(systemName: "pencil").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .symbolEffect(.pulse, options: .repeating)
            } else {
                Image(systemName: "clock").font(.system(size: 12)).foregroundStyle(Theme.faint)
            }
            Text(req.text).font(.system(size: 15))
                .foregroundStyle(inFlight ? Theme.ink : Theme.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(inFlight ? Theme.accentSoft : Theme.card, in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13)
            .stroke(inFlight ? Theme.accent.opacity(0.5) : Theme.borderRead, lineWidth: 1))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func pill(recording: Bool, working: Bool) -> some View {
        HStack(spacing: 8) {
            if recording {
                Text(willCancel ? "上滑取消 · 松开放弃" : "松开 发送 · 上滑取消")
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
            } else if working {
                // The mic itself becomes the live "editing" indicator — no chip.
                Image(systemName: "pencil.line").font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .symbolEffect(.pulse, options: .repeating)
                Text("正在改…按住继续说").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.ink)
            } else {
                Image(systemName: "mic").font(.system(size: 16)).foregroundStyle(Theme.ink)
                Text("按住 说话 修改").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.ink)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 15)
        .background(RoundedRectangle(cornerRadius: Theme.R.primary)
            .fill(recording ? Theme.accent : Theme.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.R.primary)
            .stroke(recording ? Color(hex: "C94A2E") : Theme.borderRead, lineWidth: 1))
        .shadow(color: recording ? Color(.sRGB, red: 216/255, green: 89/255, blue: 59/255, opacity: 0.30) : .clear,
                radius: 7, x: 0, y: 4)
        .contentShape(RoundedRectangle(cornerRadius: Theme.R.primary))
        .gesture(holdGesture())
    }

    /// Auto-dismiss a successful reply after a beat — but not while the user is
    /// pressing it (replyHeld), and only if it's still the same reply on screen.
    private func scheduleReplyDismiss(_ reply: AgentReply) {
        Task {
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if agentReply?.id == reply.id, !replyHeld { agentReply = nil }
        }
    }

    /// The agent's transient one-line reply. Success: neutral light card that fades
    /// after ~6 s — press and hold to keep it up; it re-arms the fade on release.
    /// Error: muted-red border + warning glyph, sticky until tapped (release dismisses).
    private func replyBubble(_ reply: AgentReply) -> some View {
        let warn = Color(hex: "C0392B")
        return HStack(spacing: 8) {
            Image(systemName: reply.ok ? "sparkles" : "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(reply.ok ? Theme.accent : warn)
            Text(reply.text)
                .font(.system(size: 15))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13)
            .stroke(reply.ok ? Theme.borderRead : warn.opacity(0.7), lineWidth: 1))
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .contentShape(RoundedRectangle(cornerRadius: 13))
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in replyHeld = true }
                .onEnded { _ in
                    replyHeld = false
                    if reply.ok { scheduleReplyDismiss(reply) }   // re-arm the fade after release
                    else { agentReply = nil }                      // error: release/tap dismisses
                }
        )
    }

    /// Dark bubble above the bar showing the live transcript (text only).
    private func darkBubble(_ text: String) -> some View {
        VStack(spacing: 0) {
            Text(text.isEmpty ? "在听…" : text)
                .font(.system(size: 16))
                .foregroundStyle(text.isEmpty ? Color(hex: "B6AD9E") : Color(hex: "FBF6EE"))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Color(hex: "2E2823"), in: RoundedRectangle(cornerRadius: 16))
            DownTriangle().fill(Color(hex: "2E2823")).frame(width: 18, height: 9)
                .padding(.leading, 24).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Press-and-hold drives dictation; release sends (unless slid up to cancel).
    private func holdGesture() -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                // No working-state gate: speak the next sentence while the last rewrites.
                guard dictation.authorized == true else { return }
                if !dictation.isRecording { dictation.start() }
                willCancel = v.translation.height < -60
            }
            .onEnded { v in
                guard dictation.isRecording else { willCancel = false; return }
                let cancel = v.translation.height < -60
                willCancel = false
                if cancel { dictation.stop(); return }
                Task {
                    let text = (await dictation.stopAndGetFinal()).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { agent.enqueue(text) }
                }
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
        case .ok(let created, let updated):
            // Real, synchronous result now — no more "约 1 分钟后".
            showToast(created == 0 && updated > 0 ? "已更新草稿" : "已到草稿箱")
            published = true
        case .notConfigured:
            publishAfterSetup = true
            showingWechatSettings = true
        case .failed(let msg):
            showToast(msg ?? "推送失败，请稍后再试")
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
                .padding(.bottom, articles.isEmpty ? 32 : 120)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// Small downward tail for the transcript bubble.
struct DownTriangle: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        p.closeSubpath()
        return p
    }
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
