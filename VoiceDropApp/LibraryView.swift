import SwiftUI

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
    @State private var tab: HomeTab = .recordings
    @State private var confirmDelete: Recording?
    @State private var confirmReprocess: Recording?
    @State private var showRecord = false
    @State private var showSettings = false
    @State private var selectedRec: Recording?
    @State private var selectedPost: CommunityPost?
    @State private var confirmUnshare: CommunityPost?
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
        return (uploading + optimistic + store.recordings).sorted { $0.audioName > $1.audioName }
    }

    var body: some View {
        mainContent
            .onChange(of: store.recordings) { _, recs in checkPendingReplies(recs) }
            .alert("删除这条录音？", isPresented: .init(
                get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }
            ), presenting: confirmDelete) { rec in
                Button("删除", role: .destructive) { Task { await store.delete(rec) } }
                Button("取消", role: .cancel) {}
            } message: { _ in Text("音频和已挖出的文章都会从云端删除，不可恢复。") }
            .alert("重新处理这篇文章？", isPresented: .init(
                get: { confirmReprocess != nil }, set: { if !$0 { confirmReprocess = nil } }
            ), presenting: confirmReprocess) { rec in
                Button("删除文章并重新生成", role: .destructive) { Task { await store.deleteArticle(rec) } }
                Button("取消", role: .cancel) {}
            } message: { _ in Text("会删掉已生成的文章、保留录音，下个周期重新挖一遍。") }
            .alert("从社区移除？", isPresented: .init(
                get: { confirmUnshare != nil }, set: { if !$0 { confirmUnshare = nil } }
            ), presenting: confirmUnshare) { post in
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
        .overlay(alignment: .bottom) { if tab == .recordings { recordButton } else { EmptyView() } }
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
            statusSession.connect()
            await refresh()
        }
        .onChange(of: scenePhase) { _, p in
            if p == .active { statusSession.connect(); Task { await refresh() } }
            else if p == .background { statusSession.disconnect() }
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
            RoundedRectangle(cornerRadius: Theme.R.card)
                .fill(empty ? Color(hex: "F1ECE3") : Theme.recordRedSoft)
                .frame(width: 42, height: 42)
                .overlay(WaveformBars(color: empty ? Color(hex: "C3B9A8") : Theme.recordRed,
                                      heights: [11, 19, 14], barWidth: 3, spacing: 2.5))

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
            }
            Spacer(minLength: 6)
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.chevron)
        }
        .padding(.vertical, 14).padding(.horizontal, 15)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.R.card))
        .overlay(RoundedRectangle(cornerRadius: Theme.R.card).stroke(Theme.borderChrome, lineWidth: 1))
        .cardChromeShadow()
        .opacity(empty ? 0.72 : 1)
    }

    @ViewBuilder private func statusBadge(_ rec: Recording) -> some View {
        if rec.uploading {
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

    // MARK: Record button (floats over the list — no pane)

    private var recordButton: some View {
        VStack(spacing: 7) {
            Button { showRecord = true } label: {
                Circle().fill(Theme.card).frame(width: 66, height: 66)
                    .overlay(Circle().stroke(Color(hex: "E8DECF"), lineWidth: 1))
                    .overlay(
                        Circle().fill(Theme.recordRed).frame(width: 54, height: 54)
                            .shadow(color: Color(.sRGB, red: 229/255, green: 57/255, blue: 46/255, opacity: 0.40), radius: 4, x: 0, y: 2)
                    )
                    .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 5)   // lift off the list
            }
            .buttonStyle(.plain).accessibilityLabel("录音")
            Text("轻点录音").font(.system(size: 12)).tracking(1).foregroundStyle(Theme.secondary)
        }
        .padding(.bottom, 8)
    }
}
