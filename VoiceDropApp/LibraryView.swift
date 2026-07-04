import SwiftUI
import UIKit

/// 「我的录音」— the app's home (方案二). White-card list of recordings; a docked
/// pure-red record key at the bottom opens the full-screen recording takeover;
/// the gear pushes Settings. Pulls fresh data on appear and drains any pending
/// local uploads.
enum HomeTab { case recordings, community }

struct LibraryView: View {
    @State private var store = LibraryStore()
    @State private var uploader = Uploader()
    @State private var community = CommunityStore()
    @State private var statusSession = StatusSession()
    @State private var linkResponder = DeviceLinkResponder()
    @State private var tab: HomeTab = .recordings
    @State private var confirmDelete: Recording?
    @State private var confirmReprocess: Recording?
    @State private var showRecord = false
    @State private var showSettings = false
    @State private var selectedRec: Recording?
    @State private var selectedPost: CommunityPost?
    @State private var confirmUnshare: CommunityPost?

    // 语音指令 walkie-talkie: the red record button itself doubles as a
    // library-wide press-and-hold mic that can act on any recording by its
    // on-screen number ("删掉第二条"). Separate dictation + session instances
    // from RecordingDetailView's article-level editing.
    @State private var talking = false
    @State private var willCancel = false
    @State private var dictation = SpeechDictation()
    @State private var command = LibraryCommandSession()
    @State private var commandReply: AgentReply?
    @State private var confirmPrompt: (id: String, summary: String)?
    @EnvironmentObject private var router: AppRouter
    @Environment(\.scenePhase) private var scenePhase

    /// Local takes still uploading (top) + just-uploaded optimistic 待处理 +
    /// server recordings. Same audioName = same row id, so badges change in place.
    private var rows: [Recording] {
        let serverNames = Set(store.recordings.map(\.audioName))
        let uploading = uploader.pending
            .map { Recording(audioName: $0.lastPathComponent, uploaded: "", hasArticles: false, isEmpty: false, uploading: true) }
            .filter { !serverNames.contains($0.audioName) }
        let busy = serverNames.union(uploading.map(\.audioName))
        // Optimistic: an uploaded take shows as 待处理 immediately, before the
        // server list catches up — so the row never disappears between states.
        let optimistic = uploader.justUploaded
            .filter { !busy.contains($0) }
            .map { Recording(audioName: $0, uploaded: "", hasArticles: false, isEmpty: false, uploading: false) }
        // store.recordings is ALREADY ordered newest-first (LibraryStore.load → Recording.newestFirst);
        // do NOT re-sort here. Just prepend the in-flight rows (uploading / just-uploaded), which are
        // the newest by definition, so they sit on top.
        return uploading + optimistic + store.recordings
    }

    // Explicit Binding<Bool> so the SwiftUI view body doesn't pay to type-infer an
    // inline `.init(get:set:)` per alert — a chain of 4 alerts with inline bindings
    // blows the Swift type-checker's budget ("unable to type-check in reasonable time",
    // machine-dependent: passes locally, times out on the slower CI runner).
    private func clearBinding(_ isSet: @escaping () -> Bool, _ clear: @escaping () -> Void) -> Binding<Bool> {
        Binding(get: isSet, set: { if !$0 { clear() } })
    }

    // Split into two typed `some View` properties: the type-checker handles each half
    // independently, keeping each well under budget. Do NOT re-collapse into one chain.
    var body: some View {
        rowAlerts
            .alert(confirmPrompt?.summary ?? "确认操作",
                   isPresented: clearBinding({ confirmPrompt != nil }, { confirmPrompt = nil }),
                   presenting: confirmPrompt) { p in
                // 语音指令 destructive confirm (e.g. "删掉第二条") — the server asks
                // before acting; summary is its plain-language description of the action.
                Button("删除", role: .destructive) { command.confirm(p.id); confirmPrompt = nil }
                Button("取消", role: .cancel) { command.cancel(p.id); confirmPrompt = nil }
            }
    }

    private var rowAlerts: some View {
        mainContent
            .onChange(of: store.recordings) { _, recs in checkPendingReplies(recs) }
            .alert("删除这条录音？", isPresented: clearBinding({ confirmDelete != nil }, { confirmDelete = nil }),
                   presenting: confirmDelete) { rec in
                Button("删除", role: .destructive) { Task { await store.delete(rec) } }
                Button("取消", role: .cancel) {}
            } message: { _ in Text("音频和已挖出的文章都会从云端删除，不可恢复。") }
            .alert("重新生成这篇文章？", isPresented: clearBinding({ confirmReprocess != nil }, { confirmReprocess = nil }),
                   presenting: confirmReprocess) { rec in
                Button("重新生成", role: .destructive) { Task { await store.deleteArticle(rec) } }
                Button("取消", role: .cancel) {}
            } message: { _ in Text("删掉当前文章、保留录音，立即重新挖一遍。生成的内容可能和原来不同。") }
            .alert("从社区移除？", isPresented: clearBinding({ confirmUnshare != nil }, { confirmUnshare = nil }),
                   presenting: confirmUnshare) { post in
                Button("移除", role: .destructive) { Task { await community.unshare(post.shareId) } }
                Button("取消", role: .cancel) {}
            } message: { _ in Text("社区里将看不到这篇；你的原文章不受影响，以后还能再分享。") }
    }

    private var mainContent: some View {
        VStack(spacing: 0) {
            topBar
            tabHeader
            if tab == .recordings { recordingsContent } else { communityContent }
        }
        .background(Theme.appBG.ignoresSafeArea())
        .overlay(alignment: .bottom) {
            if tab == .recordings {
                recordButton
            } else {
                EmptyView()
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(item: $selectedRec) { rec in RecordingDetailView(store: store, recording: rec) }
        .navigationDestination(item: $selectedPost) { post in
            CommunityPostView(store: community, post: post, onRecordFinished: responseRecorded)
        }
        .navigationDestination(isPresented: $showSettings) { SettingsView(libraryStore: store) }
        .fullScreenCover(isPresented: $showRecord) {
            RecordSession { showRecord = false; Task { await refresh() } }
        }
        .task {
            statusSession.onPhase = { stem, phase in store.markPhase(stem: stem, phase: phase) }
            statusSession.onDone = { stem in store.markDone(stem: stem) }
            statusSession.onLinkRequest = { pid, code, pubkey in linkResponder.present(pairingId: pid, code: code, pubkey: pubkey) }
            statusSession.onLinkRelease = { pid in linkResponder.release(pairingId: pid) }
            statusSession.connect()
            await refresh()
        }
        .task {
            // Library-wide voice-command session: reply bubble + list refresh after
            // an edit lands + a destructive-action confirm prompt.
            command.onReply = { text, ok in commandReply = AgentReply(text: text, ok: ok) }
            command.onUpdate = { _ in Task { await refresh() } }
            command.onConfirm = { id, summary in
                confirmPrompt = (id: id, summary: summary)
                // A destructive result can land while a hold is still active (the
                // confirm round-trip is usually faster than a press, but not always)
                // — drop out of "talking" so the alert isn't fighting the mic UI.
                if talking { talking = false }
            }
            command.connect()
            await dictation.requestAuth()
        }
        .sheet(item: $linkResponder.pending) { p in
            DeviceLinkApprovalSheet(responder: linkResponder, pending: p)
        }
        .onChange(of: scenePhase) { _, p in
            if p == .active { statusSession.connect(); Task { await refresh() } }
            else if p == .background { statusSession.disconnect() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .vdDidAdoptAccount)) { _ in
            statusSession.disconnect()
            statusSession.connect()
            Task { await refresh() }
        }
        .onReceive(router.$pending.compactMap { $0 }) { link in
            // A deep link (voicedrop://<page>) arrived — apply it, clearing any
            // pushed detail/settings/record so it lands cleanly, then reset.
            showRecord = false
            switch link {
            case .recordings:
                tab = .recordings; selectedRec = nil; selectedPost = nil; showSettings = false
                Task { await refresh() }
            case .community:
                tab = .community; selectedRec = nil; selectedPost = nil; showSettings = false
            case .settings:
                selectedRec = nil; selectedPost = nil; showSettings = true
            case .record:
                selectedRec = nil; selectedPost = nil; showSettings = false; showRecord = true
            case .article(let stem):
                tab = .recordings; selectedPost = nil; showSettings = false
                if let rec = store.recordings.first(where: { $0.stem == stem }) {
                    selectedRec = rec
                } else {
                    Task { await refresh(); selectedRec = store.recordings.first { $0.stem == stem } }
                }
            }
            Task { @MainActor in router.pending = nil }
        }
    }

    private func checkPendingReplies(_ recs: [Recording]) {
        for rec in recs where rec.hasArticles {
            let key = "vd.pendingReply.\(rec.audioName)"
            if let replyTo = UserDefaults.standard.string(forKey: key) {
                UserDefaults.standard.removeObject(forKey: key)
                Task { _ = await community.share(rec, replyTo: replyTo) }
            }
        }
    }

    private func responseRecorded() { Task { await refresh() } }

    private func refresh() async {
        uploader.refreshPending()                 // surface 正在上传 rows immediately
        await store.load()
        if uploader.pendingCount > 0 { _ = await uploader.drainPending(); await store.load() }
        uploader.dropConfirmed(Set(store.recordings.map(\.audioName)))  // prune confirmed optimistic rows
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack {
            HStack(spacing: 8) {
                WaveformBars(color: Theme.recordRed, heights: [6, 12, 16, 8], barWidth: 3, spacing: 2.5)
                Text("VoiceDrop 口述").font(.system(size: 14, weight: .semibold)).tracking(1).foregroundStyle(Theme.ink)
            }
            Spacer()
            NavSquare(systemName: "gearshape") { showSettings = true }.accessibilityLabel("设置")
        }
        .padding(.top, 6).padding(.horizontal, 22).padding(.bottom, 10)
    }

    // MARK: Tabs (我的录音 / 社区)

    private var tabHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 20) {
            tabLabel("我的录音", .recordings)
            tabLabel("VD社区", .community)
            Spacer()
        }
        .padding(.horizontal, 22).padding(.bottom, 10)
    }

    private func tabLabel(_ title: String, _ t: HomeTab) -> some View {
        let active = tab == t
        return Button {
            tab = t
            if t == .community { Task { await community.load() } }
        } label: {
            VStack(spacing: 5) {
                Text(title).font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(active ? Theme.ink : Theme.faint)
                Capsule().fill(active ? Theme.recordRed : .clear).frame(height: 3)
                    .frame(maxWidth: active ? .infinity : 0)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: List

    @ViewBuilder private var recordingsContent: some View {
        if store.loading && rows.isEmpty {
            Spacer(); ProgressView().tint(Theme.recordRed); Spacer()
        } else if let err = store.error, rows.isEmpty {
            Spacer(); message("加载失败", err); Spacer()
        } else if rows.isEmpty {
            Spacer(); message("还没有录音", "点下面的红键录一条，过会儿服务器会自动转写并挖成文章。"); Spacer()
        } else {
            List {
                ForEach(rows) { rec in
                    Group {
                        if rec.uploading {
                            rowCard(rec)
                        } else {
                            // Button (not NavigationLink) so the List doesn't add its
                            // own trailing disclosure chevron — the card draws its own.
                            Button { selectedRec = rec } label: { rowCard(rec) }
                                .buttonStyle(.plain)
                        }
                    }
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 6, trailing: 16))
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        if !rec.uploading {
                            Button(role: .destructive) { confirmDelete = rec } label: { Label("删除", systemImage: "trash") }
                                .tint(.red)
                            // 「重写」在删除左边：复用已有 ASR、按原逻辑重挖（仅对已成文的录音）
                            if rec.hasArticles {
                                Button { Task { await store.remine(rec) } } label: { Label("重写", systemImage: "arrow.clockwise") }
                                    .tint(Theme.accent)
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .contentMargins(.bottom, 104, for: .scrollContent)   // clear the floating button
            .refreshable { await refresh() }
        }
    }

    // MARK: Community list

    @ViewBuilder private var communityContent: some View {
        if community.loading && community.posts.isEmpty {
            Spacer(); ProgressView().tint(Theme.accent); Spacer()
        } else if let err = community.error, community.posts.isEmpty {
            Spacer(); message("加载失败", err); Spacer()
        } else if community.posts.isEmpty {
            Spacer(); message("VD社区还没有分享", "在文章右上角 ⋯ 里点「分享到 VD社区」，大家就能看到。"); Spacer()
        } else {
            List {
                ForEach(community.posts) { post in
                    Button { selectedPost = post } label: { communityCard(post) }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear).listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 6, trailing: 16))
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if post.mine == true {
                                Button(role: .destructive) { confirmUnshare = post } label: { Label("取消分享", systemImage: "trash") }
                                    .tint(.red)
                            }
                        }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .contentMargins(.bottom, 24, for: .scrollContent)
            .refreshable { await community.load() }
        }
    }

    private func communityCard(_ post: CommunityPost) -> some View {
        HStack(spacing: 13) {
            RoundedRectangle(cornerRadius: Theme.R.card)
                .fill(Theme.accentSoft)
                .frame(width: 42, height: 42)
                .overlay(Image(systemName: "doc.text").font(.system(size: 17)).foregroundStyle(Theme.accent))
            VStack(alignment: .leading, spacing: 5) {
                Text(post.title ?? "(无题)").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.ink)
                    .lineLimit(1).truncationMode(.tail)
                HStack(spacing: 9) {
                    Text(post.author ?? "匿名").font(.system(size: 13)).foregroundStyle(Theme.accent)
                    Text(communityDate(post.firstSharedAt)).font(.system(size: 13)).foregroundStyle(Theme.metaChrome)
                }
            }
            Spacer(minLength: 6)
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.chevron)
        }
        .padding(.vertical, 14).padding(.horizontal, 15)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.R.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.R.card).stroke(Theme.borderChrome, lineWidth: 1))
        .cardChromeShadow()
    }

    private func rowCard(_ rec: Recording) -> some View {
        let empty = rec.isEmpty
        return HStack(spacing: 13) {
            // The article's first photo as the row icon when it has one; otherwise
            // the waveform tile (also the fallback while the photo loads / on fail).
            if let cover = rec.coverPhotoKey {
                RowCoverIcon(store: store, relKey: cover)
            } else {
                waveTile(empty: empty)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(rec.rowTitle).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.ink)
                    .lineLimit(1).truncationMode(.tail)
                HStack(spacing: 9) {
                    if let dt = rec.dateTimeLabel {
                        Text(dt).font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.metaChrome)
                    }
                    if let d = rec.durationLabel {
                        Text(d).font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.metaChrome)
                    }
                    statusBadge(rec)
                }
                if let tags = rec.tags, !tags.isEmpty {
                    Text(tags.map { "#" + $0 }.joined(separator: "  "))
                        .font(.system(size: 11)).foregroundStyle(Theme.metaChrome)
                        .lineLimit(1).truncationMode(.tail)
                }
            }
            Spacer(minLength: 6)
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.chevron)
        }
        .padding(.vertical, 14).padding(.horizontal, 15)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.R.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.R.card).stroke(Theme.borderChrome, lineWidth: 1))
        .cardChromeShadow()
        .opacity(empty ? 0.72 : 1)
        .overlay(alignment: .topLeading) {
            if talking, let n = commandNumber(for: rec) { numberBadge(n) }
        }
    }

    /// Small number ("2") pinned to a row's top-left corner while holding the red
    /// key to talk — the number the user speaks to target that recording ("删掉第
    /// 二条"). Design: a white rounded-square chip with a tan border (Navigation.dc).
    private func numberBadge(_ n: Int) -> some View {
        Text("\(n)")
            .font(.system(size: 12, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(Color(hex: "4A4438"))
            .frame(width: 20, height: 20)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.white))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(Color(hex: "E4DBCB"), lineWidth: 1))
            .shadow(color: Color(hex: "3C2D1E").opacity(0.10), radius: 4, x: 0, y: 1)
            .offset(x: 13, y: 10)
    }

    /// The default row icon: a soft rounded tile with a 3-bar waveform. Unchanged
    /// visual — used for rows without a cover photo, and as `RowCoverIcon`'s fallback.
    private func waveTile(empty: Bool) -> some View {
        RoundedRectangle(cornerRadius: Theme.R.card)
            .fill(empty ? Color(hex: "F1ECE3") : Theme.recordRedSoft)
            .frame(width: 42, height: 42)
            .overlay(WaveformBars(color: empty ? Color(hex: "C3B9A8") : Theme.recordRed,
                                  heights: [11, 19, 14], barWidth: 3, spacing: 2.5))
    }

    @ViewBuilder private func statusBadge(_ rec: Recording) -> some View {
        if store.reminingStems.contains(rec.stem) {
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini).tint(Theme.accent)
                Text("重写中").font(.system(size: 12.5)).foregroundStyle(Theme.accent)
            }
        } else if rec.uploading {
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini).tint(Theme.recordRed)
                Text("正在上传").font(.system(size: 12.5)).foregroundStyle(Theme.recordRed)
            }
        } else if rec.hasArticles {
            badge(Theme.greenDone, "已成文")
                .contentShape(Rectangle())
                .onLongPressGesture { confirmReprocess = rec }
        } else if rec.isEmpty {
            badge(Theme.faint, "无语音")
        } else if let phase = rec.phase {
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini).tint(Theme.accent)
                Text(phase.badge).font(.system(size: 12.5)).foregroundStyle(Theme.accent)
            }
        } else if let r = rec.blockReason {
            badge(Color(hex: "C0392B"), BlockReason(rawValue: r)?.label ?? BlockReason.noCredit.label)
        } else {
            badge(Theme.amberPending, "待处理")
        }
    }

    private func badge(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.system(size: 12.5)).foregroundStyle(color)
        }
    }

    private func message(_ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 10) {
            Text(title).foregroundStyle(Theme.ink).font(.system(size: 17, weight: .semibold))
            Text(subtitle).foregroundStyle(Theme.secondary).font(.system(size: 15))
                .multilineTextAlignment(.center).padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Record button (floats over the list — no pane; IS the walkie-talkie)

    /// The red key itself: tap records a take (unchanged); press-and-hold turns
    /// it into a 微信式「按住说话」 mic for library-wide 语音指令 ("删掉第二条"),
    /// reusing the same feedback bubbles as article-level voice editing.
    private var recordButton: some View {
        VStack(spacing: 7) {
            if talking || commandReply != nil || !command.queue.isEmpty {
                VoiceFeedbackStack(transcript: talking ? dictation.transcript : nil,
                                   reply: commandReply, queue: command.queue)
                    .padding(.horizontal, 16)
            }
            redCircle
                .scaleEffect(talking ? 1.08 : 1)
                .gesture(talkGesture)
                .simultaneousGesture(TapGesture().onEnded { if !talking { showRecord = true } })
            Text(talking ? (willCancel ? "上滑取消 · 松开放弃" : "松开发送 · 上滑取消") : "轻点录音 · 长按说话")
                .font(.system(size: 12)).tracking(1)
                .foregroundStyle(talking ? Theme.accent : Theme.secondary)
        }
        .padding(.bottom, 8)
        .animation(.easeInOut(duration: 0.18), value: talking)
    }

    /// The pure-red circle key. Same visuals as before at rest; while `talking`
    /// a thin accent ring adds emphasis (the `scaleEffect` bump lives in
    /// `recordButton`, applied on top of this).
    private var redCircle: some View {
        Circle().fill(Theme.card).frame(width: 66, height: 66)
            .overlay(Circle().stroke(talking ? Theme.recordRed.opacity(0.55) : Color(hex: "E8DECF"),
                                      lineWidth: talking ? 2 : 1))
            .overlay(
                Circle().fill(Theme.recordRed).frame(width: 54, height: 54)
                    .shadow(color: Color(.sRGB, red: 229/255, green: 57/255, blue: 46/255, opacity: 0.40), radius: 4, x: 0, y: 2)
            )
            .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 5)   // lift off the list
            .contentShape(Circle())
            .accessibilityLabel("录音")
    }

    /// Sequenced long-press → drag so the whole hold is ONE continuous touch:
    /// a quick tap never engages this gesture (falls through to the sibling
    /// `TapGesture` and records normally); holding past 0.3s starts dictation,
    /// and sliding up cancels — mirroring `PushToTalkBar.holdGesture()`.
    private var talkGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                if case .second(true, let drag) = value {
                    if !talking {
                        talking = true
                        commandReply = nil
                        if dictation.authorized == true { dictation.start() }
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    }
                    willCancel = (drag?.translation.height ?? 0) < -60
                }
            }
            .onEnded { value in
                guard case .second(true, _) = value else { return }
                let cancel = willCancel
                talking = false; willCancel = false
                if cancel { dictation.stop(); return }
                Task {
                    let text = (await dictation.stopAndGetFinal()).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    command.setRefs(currentRefs())
                    command.enqueue(text, images: [], articleIndex: 0)
                }
            }
    }

    // MARK: 语音指令 refs (长按红键说话)

    /// Numbered refs for the command agent, matching the on-screen circled numbers
    /// in `rowCard` 1:1 — both are absolute positions in `store.recordings`
    /// (newest-first). In-flight uploads/optimistic rows aren't real articles yet,
    /// so they're not numbered and can't be targeted by a spoken command.
    private func currentRefs() -> [LibraryCommandSession.CommandRef] {
        store.recordings.enumerated().map { i, rec in
            .init(n: i + 1, stem: rec.stem, title: rec.rowTitle)
        }
    }

    /// The circled number to show on `rec`'s row while holding the red key to
    /// talk, or nil if `rec` isn't a numbered target (still uploading / not yet
    /// on the server).
    private func commandNumber(for rec: Recording) -> Int? {
        guard let idx = store.recordings.firstIndex(where: { $0.id == rec.id }) else { return nil }
        return idx + 1
    }
}

/// A 42×42 row icon showing the article's first photo. Loads it once (own scope +
/// rel key, same public `/photo/<key>` path as PhotoTile); shows the waveform tile
/// until the image lands and if it can't load — so a row never looks broken.
private struct RowCoverIcon: View {
    let store: LibraryStore
    let relKey: String
    @State private var image: UIImage?

    /// Process-wide decoded-image cache, shared across every row. Keyed by rel key
    /// (unique per photo). NSCache evicts under memory pressure on its own. This is
    /// what stops a re-download every time a row scrolls back into view.
    private static let cache = NSCache<NSString, UIImage>()

    var body: some View {
        RoundedRectangle(cornerRadius: Theme.R.card)
            .fill(Theme.recordRedSoft)
            .frame(width: 42, height: 42)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    WaveformBars(color: Theme.recordRed, heights: [11, 19, 14], barWidth: 3, spacing: 2.5)
                }
            }
            .frame(width: 42, height: 42)
            .clipShape(RoundedRectangle(cornerRadius: Theme.R.card))
            .task(id: relKey) { await load() }
    }

    private func load() async {
        // Cache hit → show instantly, no network, no waveform flash. (Set to the
        // cached image for THIS key — or nil if absent — so a recycled row never
        // shows the previous photo.)
        let cached = Self.cache.object(forKey: relKey as NSString)
        image = cached
        if cached != nil { return }
        guard let scope = await store.ownerScope() else { return }
        if let data = await store.photoData(fullKey: scope + relKey), let ui = UIImage(data: data) {
            Self.cache.setObject(ui, forKey: relKey as NSString)
            // Guard against a stale set if the row got recycled to a new key mid-fetch
            // (.task(id:) cancels the old task on key change).
            if !Task.isCancelled { image = ui }
        }
    }
}
