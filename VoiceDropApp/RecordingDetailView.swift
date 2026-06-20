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
    @State private var tab = 0                 // 0 = 文章, 1 = 字幕
    @State private var articleIndex = 0
    @State private var sharing = false
    @State private var shareLink: IdentifiableURL?

    private var articles: [MinedArticle] { doc?.resolvedArticles ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            playerBar
            Divider().overlay(Color.white.opacity(0.1))
            if loadingDoc {
                Spacer(); ProgressView().tint(.white); Spacer()
            } else if recording.isEmpty {
                Spacer(); emptyState; Spacer()
            } else if articles.isEmpty && (doc?.srt ?? "").isEmpty {
                Spacer(); pending; Spacer()
            } else {
                Picker("", selection: $tab) {
                    Text("文章\(articles.count > 1 ? " (\(articles.count))" : "")").tag(0)
                    Text("字幕").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16).padding(.vertical, 10)

                if tab == 0 { articlePane } else { srtPane }
            }
        }
        .background(Color.black.ignoresSafeArea())
        .navigationTitle(recording.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.black, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task {
            if recording.isEmpty {
                emptyReason = await store.fetchEmptyReason(recording)
            } else {
                doc = await store.fetchDoc(recording)
            }
            loadingDoc = false
        }
        .onDisappear { player.stop() }
        .sheet(item: $shareLink) { ShareSheet(items: [$0.url]) }
    }

    // MARK: Share + article rendering

    private var shareButton: some View {
        Button {
            Task {
                sharing = true
                if let u = await store.shareURL(recording) { shareLink = IdentifiableURL(url: u) }
                sharing = false
            }
        } label: {
            roundIcon(sharing ? "ellipsis" : "square.and.arrow.up")
        }
        .disabled(sharing)
        .accessibilityLabel("分享文章")
    }

    private func roundIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.callout).foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .padding(12).background(.white.opacity(0.14), in: Circle())
    }

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
                .overlay(alignment: .bottomTrailing) {
                    HStack(spacing: 12) {
                        shareButton
                        Button {
                            UIPasteboard.general.string = a.title + "\n\n" + a.body
                        } label: {
                            roundIcon("doc.on.doc")
                        }
                        .accessibilityLabel("拷贝全文")
                    }
                    .padding(18)
                }
            }
        }
    }

    // MARK: SRT

    private var srtPane: some View {
        ScrollView {
            Text((doc?.srt?.isEmpty == false ? doc!.srt! : (doc?.transcript ?? "")))
                .font(.callout.monospaced())
                .foregroundStyle(.white.opacity(0.75))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(20)
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

/// Wraps a URL so it can drive `.sheet(item:)`.
struct IdentifiableURL: Identifiable { let url: URL; var id: String { url.absoluteString } }

/// The system share sheet (UIActivityViewController) for SwiftUI.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
