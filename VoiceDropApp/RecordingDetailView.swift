import SwiftUI
import UIKit
import PhotosUI

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
    @State private var confirmDeleteFromDetail = false
    @State private var showingInsertPhoto = false
    @State private var hasSpokenOnce = false   // once set, editing toolbar stays visible until dismiss

    // Undo/redo: versions (oldest-first) + head loaded on open and refreshed after
    // each agent edit. Undo/redo move head locally for instant UI update, then
    // fire an async PATCH to sync the server pointer (no new version written).
    @State private var versions: [ArticleVersionEntry] = []
    @State private var head: Int = 0
    private var canUndo: Bool {
        guard let first = versions.first else { return false }
        return head > first.v
    }
    private var canRedo: Bool {
        guard let last = versions.last else { return false }
        return head < last.v
    }
    // Editing toolbar shows once the user has ever spoken, and stays until the view is dismissed.
    private var isEditing: Bool { hasSpokenOnce || dictation.isRecording || agent.state == .working }

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
        .fullScreenCover(isPresented: $showingInsertPhoto) {
            PhotoCaptureView(recordingStart: nil) { photos in insertPhotos(photos) }
                .ignoresSafeArea()
        }
        .alert("删除这条录音？", isPresented: $confirmDeleteFromDetail) {
            Button("删除", role: .destructive) {
                Task { await store.delete(recording); dismiss() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("音频和已挖出的文章都会从云端删除，不可恢复。")
        }
    }

    /// Open the editing socket + ask for mic/speech once the article is loaded.
    private func connectIfNeeded() async {
        guard !connected, !articles.isEmpty else { return }
        connected = true
        agent.onUpdate = { [self] newDoc in
            doc = newDoc
            articleIndex = min(articleIndex, max(0, newDoc.resolvedArticles.count - 1))
            // A new agent edit writes a new version; refresh history and reset to latest.
            Task { await loadVersionHistory() }
        }
        agent.onReply = { text, ok in
            let reply = AgentReply(text: text, ok: ok)
            agentReply = reply
            if ok { scheduleReplyDismiss(reply) }
        }
        agent.connect(recording)
        await dictation.requestAuth()
        await loadVersionHistory()
    }

    private func loadVersionHistory() async {
        let h = await store.fetchVersionHistory(recording)
        versions = h.versions
        head = h.head
    }

    private func performUndo() {
        guard canUndo, let target = versions.last(where: { $0.v < head }) else { return }
        head = target.v
        applyVersion(target)
        Task { await store.patchHead(recording, head: target.v) }
    }

    private func performRedo() {
        guard canRedo, let target = versions.first(where: { $0.v > head }) else { return }
        head = target.v
        applyVersion(target)
        Task { await store.patchHead(recording, head: target.v) }
    }

    private func applyVersion(_ entry: ArticleVersionEntry) {
        guard var current = doc else { return }
        // Patch only the articles array; all other metadata stays unchanged.
        let patched = ArticleDoc(
            id: current.id, sourceAudio: current.sourceAudio, createdAt: current.createdAt,
            transcript: current.transcript, srt: current.srt,
            articles: entry.articles,
            photos: current.photos, title: current.title, body: current.body
        )
        doc = patched
        articleIndex = min(articleIndex, max(0, patched.resolvedArticles.count - 1))
    }


    private func insertPhotos(_ captured: [CapturedPhoto]) {
        showingInsertPhoto = false
        guard !captured.isEmpty else { return }
        showToast("正在上传图片…")
        Task {
            let parts = recording.stem.components(separatedBy: "-")
            guard parts.count >= 5, parts[0] == "VoiceDrop" else { showToast("无法插入图片"); return }
            let sessionTs = "\(parts[1])-\(parts[2])-\(parts[3])-\(parts[4])"
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd-HHmmss"

            var relKeys: [String] = []
            for photo in captured {
                let captureTs = formatter.string(from: photo.date)
                guard let key = await store.uploadPhoto(data: photo.data, sessionTs: sessionTs, captureTs: captureTs)
                else { showToast("图片上传失败"); return }
                relKeys.append(key)
            }

            let startCount = doc?.photos?.count ?? 0
            let keysDesc = relKeys.enumerated()
                .map { "\($0.element)(第\(startCount + $0.offset + 1)张)" }
                .joined(separator: "、")
            agent.enqueue("请将刚上传的\(relKeys.count == 1 ? "照片" : "\(relKeys.count)张照片") \(keysDesc) 加入文章，在最合适的位置依次插入[[photo:N]]标记，并确保photos数组包含这些key。如无法判断位置，放在结尾。")
            showToast("图片已上传，AI正在插入…")
        }
    }

    // MARK: Nav bar

    private var navBar: some View {
        HStack {
            NavSquare(systemName: "chevron.left", stroke: Theme.inkRead, border: Theme.borderRead) { dismiss() }
                .accessibilityLabel("返回")
            Spacer()
            if !articles.isEmpty {
                if isEditing {
                    // 编辑工具替换 ⋯ 菜单：插入照片 + 撤销/重做
                    HStack(spacing: 8) {
                        Button { showingInsertPhoto = true } label: {
                            RoundedRectangle(cornerRadius: Theme.R.nav)
                                .fill(Theme.card)
                                .frame(width: 38, height: 38)
                                .overlay(
                                    Image(systemName: "photo")
                                        .font(.system(size: 16, weight: .regular))
                                        .foregroundStyle(Color(hex: "5A5249"))
                                )
                                .overlay(RoundedRectangle(cornerRadius: Theme.R.nav).stroke(Theme.borderRead, lineWidth: 1))
                                .navButtonShadow()
                        }
                        .buttonStyle(.plain)

                        if versions.count > 1 {
                            HStack(spacing: 0) {
                                Button { performUndo() } label: {
                                    Image(systemName: "arrow.uturn.backward")
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundStyle(canUndo ? Color(hex: "3A352E") : Color(hex: "C9BFB0"))
                                        .frame(width: 38, height: 38)
                                }
                                .buttonStyle(.plain).disabled(!canUndo)
                                Rectangle().fill(Theme.borderRead).frame(width: 1, height: 20)
                                Button { performRedo() } label: {
                                    Image(systemName: "arrow.uturn.forward")
                                        .font(.system(size: 15, weight: .medium))
                                        .foregroundStyle(canRedo ? Color(hex: "3A352E") : Color(hex: "C9BFB0"))
                                        .frame(width: 38, height: 38)
                                }
                                .buttonStyle(.plain).disabled(!canRedo)
                            }
                            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.R.nav))
                            .overlay(RoundedRectangle(cornerRadius: Theme.R.nav).stroke(Theme.borderRead, lineWidth: 1))
                            .navButtonShadow()
                        }
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                } else {
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
                        Divider()
                        Button(role: .destructive) { confirmDeleteFromDetail = true } label: {
                            Label("删除", systemImage: "trash")
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
        }
        .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 8)
        .animation(.easeInOut(duration: 0.2), value: isEditing)
    }

    private func share() async {
        // Build full text from ALL articles (all sections), strip photo markers
        let allText = articles.enumerated().map { i, a in
            let body = ArticleBody.stripMarkers(a.body)
            return articles.count > 1 ? "【\(a.title)】\n\n\(body)" : "\(a.title)\n\n\(body)"
        }.joined(separator: "\n\n---\n\n")

        // Append the short link if we can get one
        if let u = await store.shareURL(recording, section: articleIndex) {
            sharePayload = SharePayload(text: allText + "\n\n" + u.absoluteString)
        } else {
            // Share text even without URL
            sharePayload = SharePayload(text: allText)
        }
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
        VStack(spacing: 0) {
            playerCard
                .padding(.horizontal, 18).padding(.top, 6).padding(.bottom, 14)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let a = articles[safe: articleIndex] {
                        Text(a.title)
                            .font(.system(size: 23, weight: .semibold)).foregroundStyle(Theme.inkRead)
                            .lineSpacing(5).fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 20)
                        Text(recording.displayTitle)
                            .font(.system(size: 13)).foregroundStyle(Theme.metaRead)
                            .padding(.top, 8)

                        if articles.count > 1 { chipRow.padding(.top, 16) }

                        articleBody(a).padding(.top, articles.count > 1 ? 16 : 20)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }
            .contentMargins(.bottom, 96, for: .scrollContent)   // clear the floating pill
        }
    }

    /// One rendered row of the body: a numbered text paragraph, or a numbered image.
    private enum BodyRow: Identifiable {
        case paragraph(Int, String)   // 第N行
        case image(Int, String)       // 图N (relative photo key)
        var id: String {
            switch self {
            case .paragraph(let n, _): return "p\(n)"
            case .image(let n, _):     return "i\(n)"
            }
        }
    }

    /// Flatten the body (text + `[[photo:N]]` markers + trailing photos) into a
    /// numbered row list: paragraphs counted 第1/2/3…行 by real line breaks, images
    /// counted 图1/2/3… by appearance. These are the locators the user speaks to.
    private func bodyRows(_ a: MinedArticle) -> [BodyRow] {
        let photos = doc?.photos ?? []
        let segments = ArticleBody.segments(a.body)
        var rows: [BodyRow] = []
        var lineNo = 0, imgNo = 0
        for seg in segments {
            switch seg {
            case .text(let t):
                for raw in t.components(separatedBy: "\n") {
                    let para = raw.trimmingCharacters(in: .whitespaces)
                    if para.isEmpty { continue }
                    lineNo += 1
                    rows.append(.paragraph(lineNo, para))
                }
            case .photo(let n):
                if let key = photos[safe: n - 1] { imgNo += 1; rows.append(.image(imgNo, key)) }
            }
        }
        let placed = Set(segments.compactMap { if case .photo(let n) = $0 { return n } else { return nil } })
        for i in photos.indices where !placed.contains(i + 1) {
            imgNo += 1; rows.append(.image(imgNo, photos[i]))
        }
        return rows
    }

    /// Body rows with locators (line numbers + 图N badges) that float in the left
    /// margin / image corner. They're absolutely positioned (overlay) so the text
    /// never reflows — they only fade in while the user holds to talk.
    @ViewBuilder
    private func articleBody(_ a: MinedArticle) -> some View {
        let editing = dictation.isRecording
        // ~22pt between rows restores the blank-line gap paragraphs had before they
        // were split into numbered rows (previously a `\n\n` break inside one Text).
        VStack(alignment: .leading, spacing: 22) {
            ForEach(bodyRows(a)) { row in
                switch row {
                case .paragraph(let n, let text):
                    Text(textAttributed(text))
                        .font(.system(size: 16)).foregroundStyle(Theme.bodyRead)
                        .lineSpacing(9).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .topLeading) { lineNumber(n, visible: editing) }
                case .image(let n, let key):
                    PhotoTile(store: store, relKey: key)
                        .overlay(alignment: .topLeading) { imageBadge(n, visible: editing) }
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: editing)
    }

    /// Line number floating in the left margin, vertically centered on the first
    /// text line. Anchored to the paragraph's topLeading and offset left, so it
    /// occupies zero layout width (no reflow). Right-aligned in its gutter box,
    /// 7px clear of the text.
    private func lineNumber(_ n: Int, visible: Bool) -> some View {
        Text("\(n)")
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(Theme.accent.opacity(0.55))
            .frame(width: 18, height: 20, alignment: .trailing)
            .offset(x: -25)                       // 18 (box) + 7 (gap) → right edge 7px left of text
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(false)
    }

    /// "图N" badge in the image's top-left corner, fading in during editing.
    private func imageBadge(_ n: Int, visible: Bool) -> some View {
        Text("图\(n)")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 9).padding(.vertical, 3)
            .background(Color(red: 20/255, green: 18/255, blue: 16/255).opacity(0.34),
                        in: RoundedRectangle(cornerRadius: 6))
            .padding(8)
            .opacity(visible ? 1 : 0)
            .allowsHitTesting(false)
    }

    private func textAttributed(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible))) ?? AttributedString(s)
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
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.accent)
            } else if working {
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
        .background(RoundedRectangle(cornerRadius: Theme.R.primary).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.R.primary).stroke(Theme.borderRead, lineWidth: 1))
        .shadow(color: .clear, radius: 7, x: 0, y: 4)
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

    /// Dark bubble above the bar showing the live transcript. Locator references
    /// the user speaks — 第N行 / 图N — are highlighted in accent so it's clear the
    /// app understood which line/image is meant.
    private func darkBubble(_ text: String) -> some View {
        VStack(spacing: 0) {
            Group {
                if text.isEmpty { Text("在听…").foregroundStyle(Color(hex: "B6AD9E")) }
                else { highlightedTranscript(text) }
            }
            .font(.system(size: 16))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color(hex: "2E2823"), in: RoundedRectangle(cornerRadius: 16))
            DownTriangle().fill(Color(hex: "2E2823")).frame(width: 18, height: 9)
                .padding(.leading, 24).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Transcript text with every 第N行 / 图N locator tinted accent (#F0B59B).
    private func highlightedTranscript(_ s: String) -> Text {
        var att = AttributedString(s)
        att.foregroundColor = Color(hex: "FBF6EE")
        if let re = try? NSRegularExpression(pattern: "第[0-9]+行|图[0-9]+") {
            let ns = s as NSString
            for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
                guard let sr = Range(m.range, in: s),
                      let lo = AttributedString.Index(sr.lowerBound, within: att),
                      let hi = AttributedString.Index(sr.upperBound, within: att) else { continue }
                att[lo..<hi].foregroundColor = Color(hex: "F0B59B")
                att[lo..<hi].font = .system(size: 16, weight: .semibold)
            }
        }
        return Text(att)
    }

    /// Press-and-hold drives dictation; release sends (unless slid up to cancel).
    private func holdGesture() -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                // No working-state gate: speak the next sentence while the last rewrites.
                guard dictation.authorized == true else { return }
                if !dictation.isRecording { dictation.start(); hasSpokenOnce = true }
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

/// Full-width square photo taken during a recording session, rendered inline in
/// the article at its `[[photo:N]]` marker. Downloads via the authenticated
/// Files API using the stored bearer token.
struct PhotoTile: View {
    let store: LibraryStore
    let relKey: String   // relative key, e.g. "photos/<ts>/<ts>.jpg"

    @State private var image: UIImage?

    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Theme.card)
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay {
                if let img = image {
                    Image(uiImage: img)
                        .resizable().scaledToFill()
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                } else {
                    ProgressView().tint(Theme.accent)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .task {
                guard let data = try? await store.downloadData(relKey) else { return }
                image = UIImage(data: data)
            }
    }
}

/// The system share sheet (UIActivityViewController) for SwiftUI.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
