import SwiftUI
import UIKit
import PhotosUI
import LinkPresentation

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
    @State private var xhsWorking = false
    @State private var community = CommunityStore()
    @State private var published = false            // already has a WeChat draft
    @State private var sharedToCommunity = false    // already shared to the community
    @State private var communityShareId: String?    // shareId when shared (needed for unshare)
    @State private var showCommunityTerms = false   // 社区公约 agree-gate before first post

    // Live voice editing — persistent push-to-talk bar.
    @State private var agentReply: AgentReply?
    @State private var agent = ArticleAgentSession()
    @State private var dictation = SpeechDictation()
    @State private var connected = false
    @State private var confirmDeleteFromDetail = false
    @State private var showingInsertPhoto = false
    @State private var showRestyle = false       // 换风格重写 sheet
    @State private var restyling = false         // /agent/restyle in flight
    @State private var lpMenu: LongpressPresentation?   // 长按操作菜单（自绘覆盖层）

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

    /// The 文风 version of the current article — the per-article `style` field;
    /// legacy articles fall back to the body's `<!-- style: … -->` comment.
    /// nil → no chip (no-style articles).
    private var currentStyleV: Int? {
        guard let a = articles.first else { return nil }
        return a.style ?? ArticleBody.styleVersion(a.body)
    }
    /// The chip label: "v8 风格", or "v8 王建硕" when the version's name is known
    /// (styleVersions loads async — the label upgrades once history arrives).
    private var currentStyleLabel: String? {
        currentStyleV.map { v in
            StyleNaming.chipLabel(v: v, style: settings.styleVersions.first { $0.v == v }?.style)
        }
    }
    /// A version already tagged with 文风 vN (the latest such) → reuse via patchHead, free.
    private func existingVersion(forStyle v: Int) -> ArticleVersionEntry? {
        versions.last { entry in
            guard let a = entry.articles.first else { return false }
            return (a.style ?? ArticleBody.styleVersion(a.body)) == v
        }
    }

    /// Tappable chip on the meta line — opens 换风格重写. Shows the current 风格 vN.
    /// 素样式：和左边的日期同色同号（13px metaRead），不做胶囊底，只靠铅笔+箭头示意可点。
    private var styleChip: some View {
        Button { showRestyle = true } label: {
            HStack(spacing: 4) {
                Image(systemName: "pencil").font(.system(size: 11))
                Text(currentStyleLabel ?? "选风格").font(.system(size: 13))
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.chevron)
            }
            .foregroundStyle(Theme.metaRead)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
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
        .blur(radius: lpMenu == nil ? 0 : 3)   // 长按菜单出现时正文压暗模糊（设计稿 2a）
        .background(Theme.readBG.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .bottom) {
            if !articles.isEmpty {
                PushToTalkBar(dictation: dictation, session: agent, highlightLocators: true,
                              articleIndex: { articleIndex }, agentReply: agentReply)
            }
        }
        .overlay(alignment: .bottom) { toastView }
        .overlay { if restyling { restylingOverlay } }
        .overlay {
            if let m = lpMenu {
                LongpressMenuOverlay(model: m) {
                    withAnimation(.easeOut(duration: 0.15)) { lpMenu = nil }
                }
                .transition(.opacity)
            }
        }
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
        agent.onUpdate = { [self] newDoc, _ in
            guard let newDoc else { return }
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
        // 长按菜单配置：后台拉一次，失败静默（缓存/内置兜底，长按永远有菜单）。
        Task { await UIConfigStore.shared.refresh() }
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
            articles: entry.articles, tags: current.tags,
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
            Button { Task { await shareToXHS() } } label: {
                Label(xhsWorking ? "正在生成小红书文案…" : "分享到小红书", systemImage: "book.closed")
            }
            .disabled(xhsWorking)
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

    /// 分享到小红书（第一期：内容包 + 剪贴板直达）：服务端把文章转成小红书文案
    /// （标题≤20字、正文≤1000字、3–5个标签），全文写进剪贴板；文章配图（≤9张）
    /// 走 ShareSheet 分享给小红书 App，用户在发布页长按粘贴文案即可。
    private func shareToXHS() async {
        guard !xhsWorking else { return }
        xhsWorking = true
        defer { xhsWorking = false }
        guard let pack = await store.xhsPack(recording) else {
            showToast("小红书文案生成失败，稍后再试")
            return
        }
        UIPasteboard.general.string = pack.clipboardText
        var images: [UIImage] = []
        if !pack.photoKeys.isEmpty, let scope = await store.ownerScope() {
            for relKey in pack.photoKeys.prefix(9) {   // 小红书一篇最多 9 图
                if let data = await store.photoData(fullKey: scope + relKey),
                   let img = UIImage(data: data) { images.append(img) }
            }
        }
        if images.isEmpty {
            showToast("文案已复制。这篇没有配图，去小红书选一张图后粘贴文案")
            return
        }
        showToast("文案已复制，分享图片到小红书后粘贴")
        sharePayload = SharePayload(text: pack.clipboardText, images: images)
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
                        // 无风格版本（老文章/合并文章）也显示 chip（「选风格」），
                        // 否则这些文章没有入口打开换风格重写。
                        styleChip
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
                    // 长按出操作菜单（自绘覆盖层）——为此取消了 .textSelection（长按
                    // 选择与菜单手势冲突），菜单尾部的本地「拷贝」项补偿。
                    Text(textAttributed(text))
                        .font(.system(size: 16)).foregroundStyle(Theme.bodyRead)
                        .lineSpacing(9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay {
                            GeometryReader { geo in
                                Color.clear.contentShape(Rectangle())
                                    .onLongPressGesture(minimumDuration: 0.35) {
                                        presentTextMenu(line: n, text: text, frame: geo.frame(in: .global))
                                    }
                            }
                        }
                        .overlay(alignment: .topLeading) { lineNumber(n, visible: editing) }
                case .image(let n, let m, let key):
                    PhotoTile(store: store, relKey: key,
                              onLongPress: { img, frame in presentImageMenu(img, relKey: key, frame: frame) })
                        .overlay(alignment: .topLeading) { lineNumber(n, visible: editing) }
                        .overlay(alignment: .topLeading) { imageBadge(m, visible: editing) }
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: editing)
    }

    /// 长按段落 → 自绘操作菜单：服务端配置的「改写这段 / 插入图片」+ 客户端本地「拷贝」
    /// （拷贝不进服务端配置、不走网络）。点选把成品指令交给现有语音编辑队列——
    /// 与口述/插入照片同一入口，排队、串行、「正在改」指示全部复用。
    private func presentTextMenu(line: Int, text: String, frame: CGRect) {
        guard let menu = UIConfigStore.shared.textMenu(page: "voice-editor") else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            lpMenu = LongpressPresentation(
                anchor: .text(text), frame: frame, menu: menu,
                fill: { UIConfigStore.fill($0, ["LINE": String(line), "QUOTE": Self.quotePrefix(text)]) },
                onPick: { agent.enqueue($0, articleIndex: articleIndex) },
                localRows: [LongpressLocalRow(label: "拷贝", systemImage: "doc.on.doc",
                                              action: { UIPasteboard.general.string = text })]
            )
        }
    }

    /// 长按已出图的配图 → 自绘操作菜单（图片风格）。{{KEY}} 在这里换成该图 relKey。
    private func presentImageMenu(_ img: UIImage, relKey: String, frame: CGRect) {
        guard let menu = UIConfigStore.shared.imageMenu(page: "voice-editor") else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            lpMenu = LongpressPresentation(
                anchor: .image(img), frame: frame, menu: menu,
                fill: { UIConfigStore.fill($0, ["KEY": relKey]) },
                onPick: { agent.enqueue($0, articleIndex: articleIndex) }
            )
        }
    }

    /// {{QUOTE}} = 段落开头 ~15 字（双引号换成单引号，避免嵌进指令引文时断裂）。
    private static func quotePrefix(_ text: String) -> String {
        String(text.prefix(15)).replacingOccurrences(of: "\"", with: "'")
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
        let e = emptyDisplay
        return statusScreen(icon: e.icon, title: e.title, subtitle: e.subtitle)
    }

    /// Reason-aware empty state. The server marks a recording empty for several distinct
    /// reasons (miner.js writeEmpty): `no-article` means ASR DID hear speech but the model
    /// found nothing worth publishing — NOT「没检测到语音」. Only no-speech/silent is真没声。
    private var emptyDisplay: (icon: String, title: String, subtitle: String) {
        switch emptyReason {
        case "no-article":
            return ("text.badge.xmark", "没挖出文章",
                    "这段录音听到了，只是没找到能单独成篇的内容——可能太零碎，或者还没说成一件事。把想法讲完整一点、重录一段试试。")
        case "too-short":
            return ("timer", "录得太短", "这段录音太短，没攒够能成文的内容。")
        case "corrupt":
            return ("exclamationmark.triangle", "文件损坏", "这条录音的文件损坏了，没法转写。")
        case let r? where r.hasPrefix("asr-error"):
            return ("exclamationmark.triangle", "转写没成", "这段录音转写时出错了，过会儿再试或重录一段。")
        default:   // no-speech / silent / empty-text / 未知
            return ("speaker.slash", "没检测到语音", "这条录音里没有识别到说话声。")
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

/// A ready-to-share payload. `text` = "标题+正文 + 链接" (used by X / 复制 / 备忘录 等);
/// when `url` is set, link-card targets (WeChat) get the bare URL instead so they
/// render a rich card from the page's og:image / description.
struct SharePayload: Identifiable {
    let text: String
    var url: URL? = nil
    var title: String = "VoiceDrop"
    var image: UIImage? = nil
    var images: [UIImage] = []   // 小红书通道：只给图（文案在剪贴板，混入文本项会被它的分享扩展拒收）
    var id: String { text }

    /// The activity items handed to `UIActivityViewController`. With `images` it's
    /// a pure-image share (小红书). With a URL we wrap everything in `ArticleShareItem`
    /// (per-target adaptation); without one it's plain text (no card possible anyway).
    var activityItems: [Any] {
        if !images.isEmpty { return images }
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
    let relKey: String
    /// 长按回调（已解码的图 + 该 tile 的 global frame），由父视图注入并呈现自绘菜单；
    /// 缺省 nil = 无长按行为。仅已出图（image != nil）时手势才挂载——制作中/失败态
    /// 编辑一张还没出的图必然失败，直接不给入口（失败态的重试按钮也不能被挡）。
    var onLongPress: ((UIImage, CGRect) -> Void)? = nil

    @State private var image: UIImage?
    @State private var failed = false
    @State private var reloadToken = 0
    @State private var dim = false   // 呼吸点/扫光驱动
    @State private var showMaking = false   // 0.9s 宽限期后才升级为「制作中」

    // 设计稿 Image Placeholder.dc.html 的暖纸/金棕/灰配色
    private let paperTop = Color(red: 0.953, green: 0.933, blue: 0.894)   // #F3EEE4
    private let paperBot = Color(red: 0.925, green: 0.894, blue: 0.839)   // #ECE4D6
    private let gold     = Color(red: 0.788, green: 0.541, blue: 0.180)   // #C98A2E
    private let goldText = Color(red: 0.541, green: 0.482, blue: 0.376)   // #8A7B60
    private let corner   = Color(red: 0.706, green: 0.663, blue: 0.561)   // #B4A98F
    private let failBg   = Color(red: 0.957, green: 0.945, blue: 0.922)   // #F4F1EB
    private let failIcon = Color(red: 0.690, green: 0.655, blue: 0.596)   // #B0A798
    private let failText = Color(red: 0.604, green: 0.569, blue: 0.514)   // #9A9183
    private let retryOra = Color(red: 0.753, green: 0.408, blue: 0.180)   // #C0682E

    var body: some View {
        // 占位态保持 1:1 正方形；图加载成功后壳子跟随图片真实宽高比，横图竖图不再被裁方。
        RoundedRectangle(cornerRadius: 12)
            .fill(Theme.card)
            .aspectRatio(image.map { $0.size.width / max($0.size.height, 1) } ?? 1, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay {
                if let img = image {
                    Image(uiImage: img).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 12))
                } else if failed {
                    failedView
                } else if showMaking {
                    makingView
                } else {
                    graceView
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay {
                if let img = image, let onLongPress {
                    GeometryReader { geo in
                        Color.clear.contentShape(Rectangle())
                            .onLongPressGesture(minimumDuration: 0.35) {
                                onLongPress(img, geo.frame(in: .global))
                            }
                    }
                }
            }
            .animation(.easeInOut(duration: 0.25), value: image != nil)
            .task(id: "\(relKey)#\(reloadToken)") { await load() }
    }

    /// 加载前 ~0.9s 的宽限期：只露暖纸底色，不出「制作中」文案，避免正常图片一闪而过。
    private var graceView: some View {
        LinearGradient(colors: [paperTop, paperBot], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    private var makingView: some View {
        LinearGradient(colors: [paperTop, paperBot], startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay {
                VStack(spacing: 12) {
                    Image(systemName: "photo").font(.system(size: 30, weight: .regular)).foregroundStyle(gold)
                    Text("正在制作中").font(.system(size: 13, weight: .semibold)).foregroundStyle(goldText)
                    HStack(spacing: 5) {
                        ForEach(0..<3) { i in
                            Circle().fill(gold).frame(width: 5, height: 5)
                                .opacity(dim ? 0.25 : 1)
                                .animation(.easeInOut(duration: 0.7).repeatForever().delay(Double(i) * 0.2), value: dim)
                        }
                    }
                    Text("约 1 分钟完成").font(.system(size: 11)).foregroundStyle(corner)
                }
            }
            .onAppear { dim = true }
    }

    private var failedView: some View {
        failBg.overlay {
            VStack(spacing: 10) {
                Image(systemName: "photo").font(.system(size: 30)).foregroundStyle(failIcon)
                Text("暂时无法显示").font(.system(size: 12)).foregroundStyle(failText)
                Button {
                    failed = false; image = nil; reloadToken += 1
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                        Text("重试").font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(retryOra)
                    .padding(.horizontal, 11).padding(.vertical, 4)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(retryOra.opacity(0.35)))
                }
            }
        }
    }

    private func load() async {
        image = nil; failed = false; showMaking = false
        guard let scope = await store.ownerScope() else { failed = true; return }
        // 0.9s 宽限期：正常已存在的图片多在此窗口内加载完成，不升级为「制作中」；
        // 只有真的还没出图才翻牌。
        let grace = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 900_000_000)
            if image == nil && !Task.isCancelled { showMaking = true }
        }
        defer { grace.cancel() }
        let deadline = Date().addingTimeInterval(300)   // 5 分钟封顶
        while !Task.isCancelled && Date() < deadline {
            if let data = await store.photoData(fullKey: scope + relKey), let ui = UIImage(data: data) {
                image = ui; showMaking = false; return
            }
            try? await Task.sleep(nanoseconds: 3_000_000_000)  // 3s 后重试（仅在图可见且未出时）
        }
        if image == nil && !Task.isCancelled { failed = true }
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
