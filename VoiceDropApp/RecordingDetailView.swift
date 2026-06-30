import SwiftUI
import UIKit
import PhotosUI
import LinkPresentation

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
    @State private var showCommunityTerms = false   // 社区公约 agree-gate before first post

    // Live voice editing — persistent push-to-talk bar.
    @State private var agentReply: AgentReply?
    @State private var agent = ArticleAgentSession()
    @State private var dictation = SpeechDictation()
    @State private var willCancel = false           // slid finger up past threshold
    @State private var connected = false
    @State private var confirmDeleteFromDetail = false
    @State private var showingInsertPhoto = false
    @State private var showRestyle = false       // 换风格重写 sheet
    @State private var restyling = false         // /agent/restyle in flight

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

    private var articles: [MinedArticle] { doc?.resolvedArticles ?? [] }

    /// The `style` chip label of the current article (e.g. "风格 v8"), from the body's
    /// `<!-- style: … -->` comment. nil → no chip (legacy / no-style articles).
    private var currentStyleLabel: String? {
        guard let body = articles.first?.body else { return nil }
        return ArticleBody.styleLabel(body)
    }
    private var currentStyleV: Int? {
        guard let body = articles.first?.body else { return nil }
        return ArticleBody.styleVersion(body)
    }
    /// A version already tagged with 文风 vN (the latest such) → reuse via patchHead, free.
    private func existingVersion(forStyle v: Int) -> ArticleVersionEntry? {
        versions.last { ArticleBody.styleVersion($0.articles.first?.body ?? "") == v }
    }

    /// Tappable chip on the meta line — opens 换风格重写. Shows the current 风格 vN.
    private var styleChip: some View {
        Button { showRestyle = true } label: {
            HStack(spacing: 5) {
                Image(systemName: "pencil").font(.system(size: 10, weight: .semibold))
                Text(currentStyleLabel ?? "选风格").font(.system(size: 12, weight: .semibold))
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.accent.opacity(0.55))
            }
            .foregroundStyle(Theme.accent)
            .padding(.leading, 9).padding(.trailing, 9).padding(.vertical, 4)
            .background(Theme.accentSoft, in: Capsule())
            .overlay(Capsule().stroke(Theme.accent.opacity(0.28), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    /// Switch the article to 文风 vN: reuse an existing tagged version (free patchHead),
    /// else re-mine via /agent/restyle (a new version). "原文不变，可随时换回."
    private func applyStyle(_ v: Int) {
        if let entry = existingVersion(forStyle: v) {
            head = entry.v; applyVersion(entry)
            Task { await store.patchHead(recording, head: entry.v) }
            return
        }
        Task {
            restyling = true
            if let _ = await store.restyle(recording, styleV: v) {
                doc = await store.fetchDoc(recording)
                articleIndex = 0
                await loadVersionHistory()
            } else {
                toast = "重写失败，稍后再试"
            }
            restyling = false
        }
    }

    private var restylingOverlay: some View {
        ZStack {
            Color.black.opacity(0.12).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView().tint(Theme.accent)
                Text("正在用新风格重写…").font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.ink)
            }
            .padding(.horizontal, 26).padding(.vertical, 22)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.borderChrome, lineWidth: 1))
        }
    }

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
        .overlay { if restyling { restylingOverlay } }
        .sheet(isPresented: $showRestyle) {
            RestyleSheet(versions: settings.styleVersions, currentStyleV: currentStyleV) { v in applyStyle(v) }
                .presentationDetents([.medium, .large])
        }
        .task {
            if recording.isEmpty {
                emptyReason = await store.fetchEmptyReason(recording)
            } else {
                doc = await store.fetchDoc(recording)
            }
            loadingDoc = false
            published = doc?.hasWechatDraft ?? false
            await settings.loadWechat()
            await settings.loadStyleHistory()   // for the 换风格 sheet
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
        .sheet(item: $sharePayload) { ShareSheet(items: $0.activityItems) }
        .sheet(isPresented: $showCommunityTerms) {
            CommunityTermsSheet(onAgree: { Task { await toggleCommunity(true) } }, onCancel: {})
        }
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
            // The reply stays on screen until it's replaced by a newer one or the
            // user taps elsewhere on the page — no auto-dismiss timer.
            agentReply = AgentReply(text: text, ok: ok)
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
            guard let sessionTs = RecordingName.parse(recording.stem)?.sessionTs else { showToast("无法插入图片"); return }
            // Offset = seconds from the recording start to this photo. For editor-
            // inserted photos that's "how long after recording it was added" (can be
            // large) — still unique & harmless; the offset semantics are only "录音内第几秒"
            // for the during-recording capture path.
            let sessionStart = RecordingName.date(fromTimestamp: sessionTs)

            var agentImages: [AgentImage] = []
            var relKeys: [String] = []
            for photo in captured {
                let offset = sessionStart.map { Int(photo.date.timeIntervalSince($0)) } ?? 0
                guard let key = await store.uploadPhoto(data: photo.data, sessionTs: sessionTs, offset: offset)
                else { showToast("图片上传失败"); return }
                relKeys.append(key)
                // Generate a 320×320 thumbnail and base64-encode it for the model to see.
                if let thumb = makeThumbnail(from: photo.data) {
                    agentImages.append(AgentImage(key: key, base64: thumb.base64EncodedString()))
                }
            }

            // Each photo is referenced by its OWN key as the marker — no array index
            // to keep in sync. The worker also passes these keys to the model.
            let keysDesc = relKeys.map { "[[photo:\($0)]]" }.joined(separator: "、")
            let countWord = relKeys.count == 1 ? "这张照片" : "这\(relKeys.count)张照片"
            agent.enqueue(
                "我刚拍了\(countWord)，请把\(relKeys.count == 1 ? "它" : "每一张都")插入文章里最合适的位置。每张照片用它自己的标记（原样写进正文，放在和场景最相符的段落附近）：\(keysDesc)。所有照片必须全部插入，不能遗漏。",
                images: agentImages, articleIndex: articleIndex
            )
            showToast("图片已上传，AI正在插入…")
        }
    }

    /// Resize image data to a 320×320 JPEG thumbnail for sending to the model.
    private func makeThumbnail(from data: Data, side: Int = 320) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let size = CGSize(width: side, height: side)
        return UIGraphicsImageRenderer(size: size).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }.jpegData(compressionQuality: 0.7)
    }

    // MARK: Nav bar

    /// 顶部导航：返回 … 播放键 [工具] ⋯。整条播放条收进右上角的播放键（外圈细圆环显示进度），
    /// 工具栏常驻：播放键 + 插入照片 + 撤销/重做（有多版本时）+ ⋯，都一直显示，
    /// 不再要求先 push-to-talk 才出现。
    private var navBar: some View {
        HStack {
            NavSquare(systemName: "chevron.left", stroke: Theme.inkRead, border: Theme.borderRead) { dismiss() }
                .accessibilityLabel("返回")
            Spacer()
            if !articles.isEmpty {
                HStack(spacing: 10) {
                    navPlayButton
                    insertPhotoButton
                    if versions.count > 1 { undoRedoGroup }   // 直接出现，无动画
                    moreMenu   // ⋯ 常驻
                }
            }
        }
        .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 8)
    }

    /// 播放键 + 外圈进度细圆环（取代整条播放条）。点一下播放/暂停；首次播放先下载音频。
    private var navPlayButton: some View {
        Button {
            if player.duration == 0 { Task { await loadAndPlay() } } else { player.toggle() }
        } label: {
            ZStack {
                // 外圈：轨道 + 进度弧（细 2.5pt，留 2pt 内边距不被裁切，半径≈18 对齐设计稿）
                Circle().stroke(Color(hex: "E7DECF"), lineWidth: 2.5).padding(2)
                Circle()
                    .trim(from: 0, to: player.progress)
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(2)
                // 内圈：赭红实心 + 播放/暂停图标
                Circle().fill(Theme.accent).frame(width: 30, height: 30)
                    .overlay(
                        Image(systemName: loadingAudio ? "arrow.down" : (player.isPlaying ? "pause.fill" : "play.fill"))
                            .font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                            .symbolEffect(.pulse, isActive: loadingAudio)
                    )
                    .shadow(color: Theme.accent.opacity(0.32), radius: 4, x: 0, y: 2)
            }
            .frame(width: 40, height: 40)
            .contentShape(Circle())
        }
        .buttonStyle(.plain).disabled(loadingAudio)
        .accessibilityLabel(player.isPlaying ? "暂停" : "播放")
        .animation(.linear(duration: 0.2), value: player.progress)   // 跟播放计时器 0.2s 节拍平滑推进
    }

    /// 编辑态：插入照片（拍照/相册）。
    private var insertPhotoButton: some View {
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
        .accessibilityLabel("插入照片")
    }

    /// 编辑态：撤销 / 重做（一个白底圆角分段控件，中间一条分隔线）。
    private var undoRedoGroup: some View {
        HStack(spacing: 0) {
            Button { performUndo() } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(canUndo ? Color(hex: "3A352E") : Color(hex: "C9BFB0"))
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(.plain).disabled(!canUndo).accessibilityLabel("撤销")
            Rectangle().fill(Theme.borderRead).frame(width: 1, height: 20)
            Button { performRedo() } label: {
                Image(systemName: "arrow.uturn.forward")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(canRedo ? Color(hex: "3A352E") : Color(hex: "C9BFB0"))
                    .frame(width: 38, height: 38)
            }
            .buttonStyle(.plain).disabled(!canRedo).accessibilityLabel("重做")
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.R.nav))
        .overlay(RoundedRectangle(cornerRadius: Theme.R.nav).stroke(Theme.borderRead, lineWidth: 1))
        .navButtonShadow()
    }

    /// ⋯ 菜单（发布/分享/删除），平时态与编辑态都常驻。白底灰点，与播放键的赭红圆环主次分明。
    private var moreMenu: some View {
        Menu {
            Button { Task { await publishWechatTapped() } } label: {
                Label(published ? "更新公众号草稿" : "发布公众号草稿", systemImage: "paperplane")
            }
            Toggle(isOn: Binding(
                get: { sharedToCommunity },
                set: { newValue in
                    // Apple 1.2: first community post requires agreeing to the 社区公约 (EULA).
                    if newValue && !CommunityTerms.agreed { showCommunityTerms = true }
                    else { Task { await toggleCommunity(newValue) } }
                }
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
                .fill(Theme.card)
                .frame(width: 38, height: 38)
                .overlay {
                    if publishing { ProgressView().tint(Theme.accent).scaleEffect(0.8) }
                    else { Image(systemName: "ellipsis").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.secondary) }
                }
                .overlay(RoundedRectangle(cornerRadius: Theme.R.nav).stroke(Theme.borderRead, lineWidth: 1))
                .navButtonShadow()
        }
        .accessibilityLabel("更多")
    }

    private func share() async {
        let allText = ArticleBody.shareText(articles)

        // Append the short link if we can get one. When we have a URL we hand it to
        // the share sheet as a real link (with the article title + first photo as
        // LPLinkMetadata), so WeChat builds a rich link card — image + description —
        // from the page's og tags. A combined text string would land in WeChat as a
        // plain text message with NO card (the bug this fixes). X still gets the
        // inline-URL text via ArticleShareItem's per-target branching.
        guard let u = await store.shareURL(recording, section: articleIndex) else {
            sharePayload = SharePayload(text: allText)        // no link → text only
            return
        }
        let title = articles[safe: articleIndex]?.title ?? "VoiceDrop"
        let image = await firstPhotoImage()                  // best-effort card thumbnail
        sharePayload = SharePayload(text: allText + "\n\n" + u.absoluteString,
                                    url: u, title: title, image: image)
    }

    /// The first photo of the currently-shown article, used as the WeChat link-card
    /// thumbnail. Best-effort: nil when the article has no photo or the fetch fails —
    /// WeChat then falls back to the page's og:image.
    private func firstPhotoImage() async -> UIImage? {
        guard let body = articles[safe: articleIndex]?.body,
              let relKey = ArticleBody.firstPhotoKey(in: body, photos: doc?.photos ?? []),
              let scope = await store.ownerScope(),
              let data = await store.photoData(fullKey: scope + relKey) else { return nil }
        return UIImage(data: data)
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
        // 整条播放条已收进顶部播放键，正文直接上移、阅读区更大。
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let a = articles[safe: articleIndex] {
                    Text(a.title)
                        .font(.system(size: 23, weight: .semibold)).foregroundStyle(Theme.inkRead)
                        .lineSpacing(5).fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 14)
                    // 时间 + 风格 chip 同一行（去掉了原来重复标题的内容）
                    HStack(spacing: 10) {
                        if let dt = recording.dateTimeLabel {
                            Text(dt).font(.system(size: 13)).foregroundStyle(Theme.metaRead)
                        }
                        if currentStyleLabel != nil { styleChip }
                    }
                    .padding(.top, 8)

                    if articles.count > 1 { chipRow.padding(.top, 16) }

                    articleBody(a).padding(.top, articles.count > 1 ? 16 : 20)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)
        }
        .contentMargins(.bottom, 96, for: .scrollContent)   // clear the floating pill
        // Tapping anywhere on the article body dismisses a lingering agent reply.
        // simultaneousGesture so it never blocks scrolling or text selection.
        .simultaneousGesture(TapGesture().onEnded {
            if agentReply != nil { agentReply = nil }
        })
    }

    /// One rendered row of the body: a numbered text paragraph, or a numbered image.
    /// Both share the SAME continuous 第N行 counter; an image additionally carries
    /// its 图M number (the M-th photo). So an image row is e.g. 第4行 + 图2.
    private enum BodyRow: Identifiable {
        case paragraph(Int, String)        // 第N行
        case image(Int, Int, String)       // 第N行, 图M, relative photo key
        var id: String {
            switch self {
            case .paragraph(let n, _): return "p\(n)"
            case .image(let n, _, _):  return "i\(n)"
            }
        }
    }

    /// Flatten the body (text + `[[photo:…]]` markers) into a numbered row list.
    /// EVERY row — paragraph OR image — consumes one slot of a single continuous
    /// 第N行 counter (counted by real line breaks; a photo marker is its own line),
    /// so paragraph line numbers correctly accumulate across images and the numbers
    /// the user sees line up 1:1 with the body the agent edits. Images ALSO carry a
    /// 图M number (M-th photo). Photos with no marker in the body are not shown.
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
            case .photo(let token):
                if let key = ArticleBody.resolvePhotoKey(token, photos: photos) {
                    lineNo += 1; imgNo += 1
                    rows.append(.image(lineNo, imgNo, key))
                }
            }
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
                case .image(let n, let m, let key):
                    PhotoTile(store: store, relKey: key)
                        .overlay(alignment: .topLeading) { lineNumber(n, visible: editing) }
                        .overlay(alignment: .topLeading) { imageBadge(m, visible: editing) }
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
    private func fmt(_ s: TimeInterval) -> String { s.clockString }

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

    /// The agent's one-line reply. Success: neutral light card. Error: muted-red
    /// border + warning glyph. It is NOT transient — it stays put until a newer
    /// reply replaces it or the user taps elsewhere on the page (see articlePane).
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
                    if !text.isEmpty { agent.enqueue(text, articleIndex: articleIndex) }
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

/// A ready-to-share payload. `text` = "标题+正文 + 链接" (used by X / 复制 / 备忘录 等);
/// when `url` is set, link-card targets (WeChat) get the bare URL instead so they
/// render a rich card from the page's og:image / description.
struct SharePayload: Identifiable {
    let text: String
    var url: URL? = nil
    var title: String = "VoiceDrop"
    var image: UIImage? = nil
    var id: String { text }

    /// The activity items handed to `UIActivityViewController`. With a URL we wrap
    /// everything in `ArticleShareItem` (per-target adaptation); without one it's
    /// plain text (no card possible anyway).
    var activityItems: [Any] {
        guard let url else { return [text] }
        return [ArticleShareItem(text: text, url: url, title: title, image: image)]
    }
}

/// Adapts one share per target app so each gets what it renders best:
/// - WeChat (发送给朋友 + 朋友圈, `com.tencent.xin.*`) gets the bare URL → it builds a
///   rich link card from the page's og:image + `<meta name=description>`. Handing it a
///   combined text string would post a plain text message with NO card — the original bug.
/// - X / 其它 get the combined "标题+正文 + 链接" text (X drops a separately-attached URL
///   item, so the link must stay inline in that single string).
/// LPLinkMetadata (article title + first photo) is also provided so the card shows a
/// thumbnail immediately, without waiting on WeChat's server-side crawl.
final class ArticleShareItem: NSObject, UIActivityItemSource {
    private let text: String
    private let url: URL
    private let shareTitle: String
    private let image: UIImage?

    init(text: String, url: URL, title: String, image: UIImage?) {
        self.text = text
        self.url = url
        self.shareTitle = title
        self.image = image
    }

    private func wantsLinkCard(_ type: UIActivity.ActivityType?) -> Bool {
        guard let raw = type?.rawValue else { return false }
        return raw.hasPrefix("com.tencent.xin")
    }

    func activityViewControllerPlaceholderItem(_ c: UIActivityViewController) -> Any { text }

    func activityViewController(_ c: UIActivityViewController,
                                itemForActivityType type: UIActivity.ActivityType?) -> Any? {
        wantsLinkCard(type) ? url : text
    }

    func activityViewController(_ c: UIActivityViewController,
                                subjectForActivityType type: UIActivity.ActivityType?) -> String {
        shareTitle
    }

    func activityViewControllerLinkMetadata(_ c: UIActivityViewController) -> LPLinkMetadata? {
        let md = LPLinkMetadata()
        md.originalURL = url
        md.url = url
        md.title = shareTitle
        if let image { md.imageProvider = NSItemProvider(object: image) }
        return md
    }
}

/// Full-width square photo taken during a recording session, rendered inline in
/// the article at its `[[photo:N]]` marker. Loads from the public `/photo/<full key>`
/// endpoint (own scope via `/whoami` + relKey) — the same photo URL the community and
/// share pages use.
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
            // Bind the download to `relKey`, NOT to the view's identity. In the body
            // ForEach a row's identity is positional ("i\(n)"), so when a newly inserted
            // photo shifts the numbering, an existing PhotoTile is reused with a *new*
            // relKey while its identity stays the same. A plain `.task` would not re-run,
            // leaving the stale (old) image on screen — two different markers showing the
            // same photo. `.task(id: relKey)` re-runs whenever the key changes.
            .task(id: relKey) {
                image = nil
                // One photo logic everywhere: resolve own scope → full key → public /photo endpoint.
                guard let scope = await store.ownerScope(),
                      let data = await store.photoData(fullKey: scope + relKey) else { return }
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

// MARK: - 换个风格重写 (per Player Edit Toolbar.dc.html, screen ③)

/// Pick a 文风 version to rewrite the current article with. "原文不变，可随时换回."
/// onUse(v): the detail view reuses an existing tagged version (free) or calls /agent/restyle.
struct RestyleSheet: View {
    let versions: [StyleVersion]      // 文风 versions, oldest-first
    let currentStyleV: Int?           // the article's current style version (if tagged)
    let onUse: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Int?

    private var pick: Int? { selected ?? currentStyleV }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("换个风格重写").font(.system(size: 19, weight: .semibold)).foregroundStyle(Theme.ink)
                    Text("选一个范文版本，把本文重写一遍。原文不变，可随时换回。")
                        .font(.system(size: 13)).foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.top, 6).padding(.bottom, 12)

                if versions.isEmpty {
                    Spacer()
                    Text("还没有写作风格版本。\n先去设置 → 写作风格里保存一份。")
                        .font(.system(size: 14)).foregroundStyle(Theme.faint).multilineTextAlignment(.center)
                    Spacer()
                } else {
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(versions.reversed()) { ver in row(ver) }
                        }
                        .padding(.horizontal, 16).padding(.top, 2).padding(.bottom, 8)
                    }
                    bottomButton.padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 10)
                }
            }
            .background(Theme.appBG.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } } }
        }
    }

    private func row(_ ver: StyleVersion) -> some View {
        let isPick = pick == ver.v
        return Button { selected = ver.v } label: {
            HStack(spacing: 12) {
                Text("v\(ver.v)").font(.system(size: 15, weight: .bold))
                    .foregroundStyle(isPick ? Theme.accent : Theme.ink).frame(width: 38, alignment: .leading)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(ver.displayName).font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(isPick ? Theme.accent : Theme.ink).lineLimit(1)
                        if ver.v == currentStyleV {
                            Text("当前").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.accent)
                                .padding(.horizontal, 6).padding(.vertical, 1).background(Theme.accentSoft, in: Capsule())
                        }
                    }
                    Text("\(ver.charCount) 字 · \(DateFormatter.zh("M月d日").string(from: ver.date))")
                        .font(.system(size: 12)).foregroundStyle(isPick ? Theme.accent.opacity(0.8) : Theme.secondary)
                }
                Spacer(minLength: 8)
                ZStack {
                    Circle().fill(isPick ? Theme.accent : .clear).frame(width: 21, height: 21)
                    Circle().stroke(isPick ? Theme.accent : Theme.inputBorder, lineWidth: 1.6).frame(width: 21, height: 21)
                    if isPick { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white) }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 13)
            .background(isPick ? Theme.accentSoft : Theme.card, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(isPick ? Theme.accent : Theme.inputBorder, lineWidth: isPick ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var bottomButton: some View {
        Button {
            if let p = pick { onUse(p); dismiss() }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 15, weight: .semibold))
                Text(pick.map { "用 v\($0) 重写本文" } ?? "选一个版本")
                    .font(.system(size: 16, weight: .semibold))
            }
            .foregroundStyle(.white).frame(maxWidth: .infinity).padding(.vertical, 15)
            .background(pick == nil ? Theme.accent.opacity(0.4) : Theme.accent, in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain).disabled(pick == nil)
    }
}
