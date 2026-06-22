import SwiftUI
import UIKit

/// One recording: an audio player on top, then a segmented switch between the
/// subtitle (SRT) and the mined article(s).
struct RecordingDetailView: View {
    let store: LibraryStore
    let recording: Recording

    @State private var player = AudioPlayer()
    @State private var doc: ArticleDoc?
    @State private var emptyReason: String?
    @State private var loadingDoc = true
    @State private var loadingAudio = false
    @State private var articleIndex = 0

    // Three-dots menu actions.
    @State private var settings = SettingsStore()      // for WeChat config status
    @State private var publishing = false
    @State private var showingWechatSettings = false
    @State private var publishAfterSetup = false        // tapped 发布 before configuring
    @State private var showingVoiceEdit = false
    @State private var toast: String?

    private var articles: [MinedArticle] { doc?.resolvedArticles ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            playerBar
            Divider().overlay(Color.white.opacity(0.1))
            if loadingDoc {
                Spacer(); ProgressView().tint(.white); Spacer()
            } else if recording.isEmpty {
                Spacer(); emptyState; Spacer()
            } else if articles.isEmpty {
                Spacer(); pending; Spacer()
            } else {
                // No 文章/字幕 tabs — show the article directly. The only switcher
                // is the per-article chip row inside articlePane, shown only when
                // there's more than one article.
                articlePane
            }
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle(recording.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.black, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            if !articles.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            Task { await publishWechatTapped() }
                        } label: { Label("发布微信公众号草稿", systemImage: "paperplane") }

                        Button {
                            showingVoiceEdit = true
                        } label: { Label("编辑", systemImage: "mic") }
                    } label: {
                        if publishing { ProgressView().tint(.white) }
                        else { Image(systemName: "ellipsis") }
                    }
                    .disabled(publishing)
                    .accessibilityLabel("更多")
                }
            }
        }
        .task {
            if recording.isEmpty {
                emptyReason = await store.fetchEmptyReason(recording)
            } else {
                doc = await store.fetchDoc(recording)
            }
            loadingDoc = false
            await settings.loadWechat()
        }
        .onDisappear { player.stop() }
        .sheet(isPresented: $showingWechatSettings, onDismiss: {
            // If they just finished configuring after tapping 发布, continue.
            if publishAfterSetup {
                publishAfterSetup = false
                if settings.wechatConfigured { Task { await sendWechat() } }
            }
        }) { WechatSettingsSheet(store: settings) }
        .sheet(isPresented: $showingVoiceEdit) {
            VoiceEditSheet { text in
                let ok = await store.savePrompt(recording, text)
                if ok { showToast("已发送修改要求到服务器") }
                return ok
            }
        }
        .overlay(alignment: .bottom) { toastView }
    }

    // MARK: Three-dots actions

    /// 发布微信公众号草稿: if AppID/Secret aren't set yet, open the WeChat settings
    /// sheet first (then auto-continue); otherwise dispatch the publish.
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
        let ok = await store.publishWechat(recording)
        publishing = false
        showToast(ok ? "已推送，约 1 分钟后到草稿箱" : "推送失败，请稍后再试")
    }

    private func showToast(_ msg: String) {
        toast = msg
        Task {
            try? await Task.sleep(nanoseconds: 2_800_000_000)
            if toast == msg { toast = nil }
        }
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast {
            Text(toast)
                .font(.callout).foregroundStyle(.white)
                .padding(.horizontal, 18).padding(.vertical, 12)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.bottom, 32)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: Article rendering

    /// Title + body as one styled, selectable AttributedString. Body markdown is
    /// parsed inline while preserving paragraph breaks.
    private func articleAttributed(_ a: MinedArticle) -> AttributedString {
        var title = AttributedString(a.title)
        title.font = .title3.bold()
        title.foregroundColor = .white
        var body = (try? AttributedString(markdown: a.body, options: .init(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible))) ?? AttributedString(a.body)
        body.font = .body
        body.foregroundColor = .white.opacity(0.82)
        return title + AttributedString("\n\n") + body
    }

    // MARK: Player

    private var playerBar: some View {
        HStack(spacing: 14) {
            Button {
                if player.duration == 0 { Task { await loadAndPlay() } } else { player.toggle() }
            } label: {
                Image(systemName: loadingAudio ? "arrow.down.circle" : (player.isPlaying ? "pause.circle.fill" : "play.circle.fill"))
                    .font(.system(size: 40)).foregroundStyle(.white)
                    .symbolEffect(.pulse, isActive: loadingAudio)
            }
            .disabled(loadingAudio)

            ProgressView(value: player.progress)
                .tint(.white).scaleEffect(y: 1.2)

            if let d = recording.durationLabel {
                Text(d).foregroundStyle(.white.opacity(0.5)).font(.caption.monospaced())
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

    private func loadAndPlay() async {
        loadingAudio = true; defer { loadingAudio = false }
        if let url = await store.downloadAudio(recording) {
            player.load(url); player.toggle()
        }
    }

    // MARK: Articles

    private var articlePane: some View {
        VStack(spacing: 0) {
            if articles.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(articles.enumerated()), id: \.offset) { i, a in
                            Button {
                                articleIndex = i
                            } label: {
                                Text(a.title).lineLimit(1)
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 12).padding(.vertical, 7)
                                    .background(i == articleIndex ? Color.white.opacity(0.18) : Color.white.opacity(0.06),
                                                in: Capsule())
                                    .foregroundStyle(i == articleIndex ? .white : .white.opacity(0.55))
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.bottom, 6)
            }
            if let a = articles[safe: articleIndex] {
                ScrollView {
                    // One selectable block (title + body) so a long-press → Select
                    // All → Copy grabs the whole article, not a single paragraph.
                    Text(articleAttributed(a))
                        .lineSpacing(5)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                }
            }
        }
    }

    private var pending: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 36)).foregroundStyle(.white.opacity(0.4))
            Text("还没成文").foregroundStyle(.white.opacity(0.7)).font(.headline)
            Text("服务器每 2 小时自动处理一次，过会儿再来看。")
                .foregroundStyle(.white.opacity(0.45)).font(.callout)
                .multilineTextAlignment(.center).padding(.horizontal, 40)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "speaker.slash")
                .font(.system(size: 36)).foregroundStyle(.white.opacity(0.35))
            Text("没检测到语音").foregroundStyle(.white.opacity(0.7)).font(.headline)
            Text(emptyReasonText)
                .foregroundStyle(.white.opacity(0.45)).font(.callout)
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
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
