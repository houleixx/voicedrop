import SwiftUI

// 设置 → 提示词（5a）：Prompt Manager 重构 Phase 2 的新列表页，替换旧的 InstructionSettingsView
// （旧页仍在文件里，Task 8 再删）。真源 = PromptStore（ref/fork 模型，GET/PUT /agent/prompts）。
// spec: docs/superpowers/specs/2026-07-13-prompt-manager-redesign.md §9
// plan: docs/superpowers/plans/2026-07-14-prompt-manager-phase2-ios.md Task 4
//
// 删除的落地方式：设计稿要「左滑删除」，但本页沿用旧页 ScrollView + SettingsCard 的卡片视觉
// （圆角卡+自定义分隔线），改用真正的 List 才有原生 .swipeActions；List 若要长得和现有
// SettingsCard 一样（合并圆角、NavigationLink 行还不能带系统自带的 disclosure chevron 和
// 我们手画的 settingsChevron 重复）风险和改动量都不小。plan 本身把 ScrollView + contextMenu
// 列为可接受的备选（"if you keep ScrollView, use contextMenu 「删除」as the affordance instead
// and note it"）——这里选了它：长按任意行弹出「删除」，行为（confirmationDialog → 从
// store.items 移除 → 保存 → 失败回滚）与设计稿完全一致，只是触发手势从左滑换成长按。

struct PromptManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store = PromptStore.shared
    @State private var expandedGroups: Set<String> = []
    @State private var deleteTarget: PromptNode?
    @State private var showRestoreConfirm = false
    @State private var showNewSheet = false
    @State private var showImportSheet = false
    @State private var toast: String?
    /// ＋ →「新建动作」交回的草稿（还没进 store.items）：sheet 关掉之后（`onDismiss`）
    /// 才 push 编辑页，避免 sheet 收起动画和 push 动画打架。
    @State private var pendingNewActionDraft: PromptNode?
    @State private var newActionDraft: PromptNode?
    /// 长按分组行「重命名」→ push 编辑页（分组没有独立的编辑入口，复用同一个
    /// contextMenu 添加；PromptEditView 对 group 只画名字字段，改名系统 group 会 fork）。
    @State private var renameTarget: PromptNode?
    /// Task 6：导入成功后高亮的新行 id，2 秒后自动清空（`#FBF3E9` 底渐隐）；
    /// `ScrollViewReader` 配合它把列表滚到新行——见 body 里的 ScrollViewReader + rowView。
    @State private var highlightedID: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                NavSquare(systemName: "chevron.left", size: 36) { dismiss() }
                Text("提示词").font(.system(size: 26, weight: .semibold)).foregroundStyle(Theme.ink)
                Spacer()
                addButton
            }
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 6)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("一套指令，长按文字或图片时按『适用于』自动筛选。改过的系统项标『已自定义』，自己建的标『自建』。")
                            .font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
                            .padding(.horizontal, 4).padding(.bottom, 2)

                        if store.loading && store.items.isEmpty {
                            HStack { Spacer(); ProgressView().tint(Theme.accent).padding(.top, 40); Spacer() }
                        } else if let err = store.error, store.items.isEmpty {
                            Text(err).font(.system(size: 14)).foregroundStyle(Theme.faint)
                                .frame(maxWidth: .infinity, alignment: .center).padding(.top, 40)
                        } else {
                            SettingsCard {
                                ForEach(Array(flatRows.enumerated()), id: \.element.id) { i, row in
                                    rowView(row)
                                    if i < flatRows.count - 1 { settingsRowDivider }
                                }
                            }

                            importBox

                            Button {
                                showRestoreConfirm = true
                            } label: {
                                Text("恢复默认提示词").font(.system(size: 13)).foregroundStyle(Theme.accent)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 4)
                        }
                    }
                    .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 40)
                }
                .onChange(of: highlightedID) { _, id in
                    guard let id else { return }
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
        .background(Theme.appBG.ignoresSafeArea())
        .overlay(alignment: .bottom) { toastView }
        .toolbar(.hidden, for: .navigationBar)
        .task { await store.refresh() }
        .confirmationDialog(deleteDialogTitle, isPresented: deleteDialogBinding, titleVisibility: .visible) {
            Button(String(localized: "删除"), role: .destructive) {
                if let node = deleteTarget { Task { await performDelete(node) } }
            }
            .disabled(store.isMutating)
            Button(String(localized: "取消"), role: .cancel) {}
        }
        .confirmationDialog(String(localized: "把系统自带的提示词补回列表？你自建和改过的都不受影响。"),
                             isPresented: $showRestoreConfirm, titleVisibility: .visible) {
            Button(String(localized: "恢复默认提示词")) { Task { _ = await store.restoreDefaults() } }
            Button(String(localized: "取消"), role: .cancel) {}
        }
        .sheet(isPresented: $showNewSheet, onDismiss: {
            // sheet 完全收起之后再 push 编辑页——避免 sheet dismiss 动画和 push 动画同时跑。
            if let draft = pendingNewActionDraft {
                pendingNewActionDraft = nil
                newActionDraft = draft
            }
        }) {
            PromptNewSheet(onNewAction: { draft in
                pendingNewActionDraft = draft
                showNewSheet = false
            }, onNewGroup: { name in
                showNewSheet = false
                Task { await addGroup(named: name) }
            })
            .presentationDetents([.height(300)])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showImportSheet) {
            PromptImportSheet { newNode in
                // 成功回调先于 sheet 自己的 dismiss() 跑：先标记高亮 id，等 sheet 收起动画
                // 结束、下面的列表重新可见时，ScrollViewReader 的 onChange 立刻把它滚进视野。
                highlightedID = newNode.id
                Task {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    if highlightedID == newNode.id {
                        withAnimation(.easeOut(duration: 0.6)) { highlightedID = nil }
                    }
                }
            }
        }
        .navigationDestination(item: $newActionDraft) { draft in
            PromptEditView(draft: draft)
        }
        .navigationDestination(item: $renameTarget) { node in
            PromptEditView(nodeID: node.id)
        }
    }

    private func addGroup(named name: String) async {
        let group = PromptNode(id: PromptLogic.newUserID(), type: "group", label: name, origin: "user", children: [])
        if let err = await store.add(group) {
            showToast(String(localized: "新建分组失败，已恢复（\(err)）"))
        }
    }

    // MARK: - 顶栏「＋」

    private var addButton: some View {
        Button { showNewSheet = true } label: {
            RoundedRectangle(cornerRadius: Theme.R.nav)
                .fill(Theme.accent)
                .frame(width: 36, height: 36)
                .overlay(Image(systemName: "plus").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 行（顶层项 + 展开的组内子项，摊平成一个数组统一画分隔线）

    private enum Row: Identifiable {
        case action(PromptNode, indent: CGFloat)
        case group(PromptNode)
        var id: String {
            switch self {
            case .action(let n, _): return n.id
            case .group(let n): return n.id
            }
        }
    }

    private var flatRows: [Row] {
        store.items.flatMap { node -> [Row] in
            guard node.type == "group" else { return [.action(node, indent: 0)] }
            var rows: [Row] = [.group(node)]
            if expandedGroups.contains(node.id) {
                rows += (node.children ?? []).map { .action($0, indent: 16) }
            }
            return rows
        }
    }

    @ViewBuilder private func rowView(_ row: Row) -> some View {
        switch row {
        case .group(let node): groupRow(node)
        case .action(let node, let indent): actionRow(node, indent: indent)
        }
    }

    private func actionRow(_ node: PromptNode, indent: CGFloat) -> some View {
        NavigationLink {
            PromptEditView(nodeID: node.id)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                actionTile(node)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(node.label).font(.system(size: 15)).foregroundStyle(Theme.ink)
                        originBadge(node.origin)
                    }
                    AppliesToBadges(appliesTo: node.appliesTo ?? [])
                }
                Spacer(minLength: 8)
                settingsChevron
            }
            .padding(.leading, indent)
            .padding(.vertical, 12).padding(.horizontal, 15)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Task 6：导入成功后 2 秒高亮新行——`#FBF3E9` 底，随 highlightedID 清空自动渐隐。
        .background(highlightedID == node.id ? Color(hex: "FBF3E9") : Color.clear)
        .animation(.easeInOut(duration: 0.4), value: highlightedID)
        .contextMenu {
            Button(role: .destructive) { deleteTarget = node } label: {
                Label(String(localized: "删除"), systemImage: "trash")
            }
            .disabled(store.isMutating)
        }
    }

    private func groupRow(_ node: PromptNode) -> some View {
        let expanded = expandedGroups.contains(node.id)
        return Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                if expanded { expandedGroups.remove(node.id) } else { expandedGroups.insert(node.id) }
            }
        } label: {
            HStack(spacing: 12) {
                iconTile(bg: Theme.tileNeutral, symbol: "folder", fg: Theme.secondary)
                HStack(spacing: 6) {
                    Text(node.label).font(.system(size: 15)).foregroundStyle(Theme.ink)
                    originBadge(node.origin)
                    Text("分组 · \(node.children?.count ?? 0) 项")
                        .font(.system(size: 12)).foregroundStyle(Theme.sectionLabel)
                }
                Spacer(minLength: 8)
                settingsChevron.rotationEffect(.degrees(expanded ? 90 : 0))
            }
            .padding(.vertical, 12).padding(.horizontal, 15)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            // 分组行本身没有独立的「编辑」入口（点它是展开/收起），改名走长按菜单——
            // PromptEditView 对 group 只画名字字段；系统 group 改名同样会 fork（spec §3）。
            Button { renameTarget = node } label: {
                Label(String(localized: "重命名"), systemImage: "pencil")
            }
            Button(role: .destructive) { deleteTarget = node } label: {
                Label(String(localized: "删除分组"), systemImage: "trash")
            }
            .disabled(store.isMutating)
        }
    }

    // MARK: - 图标块 / 标

    private func iconTile(bg: Color, symbol: String, fg: Color, size: CGFloat = 34, iconSize: CGFloat = 14) -> some View {
        RoundedRectangle(cornerRadius: Theme.R.tile)
            .fill(bg)
            .frame(width: size, height: size)
            .overlay(Image(systemName: symbol).font(.system(size: iconSize)).foregroundStyle(fg))
    }

    /// 图标按内容挑：只适用于图片的动作用 photo/赭红，其余（仅文字或都行）用 text.quote/中性灰。
    private func actionTile(_ node: PromptNode) -> some View {
        let imageOnly = (node.appliesTo ?? []) == ["image"]
        return iconTile(bg: imageOnly ? Theme.accentSoft : Theme.tileNeutral,
                         symbol: imageOnly ? "photo" : "text.quote",
                         fg: imageOnly ? Theme.accent : Theme.secondary)
    }

    @ViewBuilder private func originBadge(_ origin: String) -> some View {
        switch origin {
        case "custom": badge(String(localized: "已自定义"), fg: Theme.amber, bg: Theme.amberSoft, weight: .semibold)
        case "user": badge(String(localized: "自建"), fg: Theme.greenDone, bg: Theme.okBannerBG, weight: .semibold)
        default: EmptyView() // system 是常态，不画标
        }
    }

    private func badge(_ text: String, fg: Color, bg: Color, weight: Font.Weight = .regular) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: weight))
            .foregroundStyle(fg)
            .padding(.vertical, 1).padding(.horizontal, 6)
            .background(bg, in: RoundedRectangle(cornerRadius: 4))
    }

    // MARK: - 4a 导入虚线框

    private var importBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { showImportSheet = true } label: {
                HStack(spacing: 12) {
                    iconTile(bg: Theme.accentSoft, symbol: "square.and.arrow.down", fg: Theme.accent, size: 42, iconSize: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("输入魔法数字导入").font(.system(size: 15.5, weight: .semibold)).foregroundStyle(Theme.ink)
                        Text("把别人分享的提示词存进你的菜单").font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
                    }
                    Spacer(minLength: 8)
                    settingsChevron
                }
                .padding(16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(Color(hex: "FBF3E9"), in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color(hex: "D8B08A"), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            )

            Text("也可以在录音时直接对 VoiceDrop 说出数字，或点开 voicedrop.cn 链接自动跳转到这里。")
                .font(.system(size: 12)).foregroundStyle(Theme.faint)
                .padding(.horizontal, 4)
        }
        .padding(.top, 14)
    }

    // MARK: - 删除

    private var deleteDialogBinding: Binding<Bool> {
        Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })
    }

    private var deleteDialogTitle: String {
        guard let node = deleteTarget else { return "" }
        if node.type == "group" {
            let n = node.children?.count ?? 0
            return String(localized: "删除分组『\(node.label)』和组内 \(n) 条？此操作不可恢复（可用底部「恢复默认提示词」找回系统项）")
        }
        return String(localized: "删除『\(node.label)』？此操作不可恢复（可用底部「恢复默认提示词」找回系统项）")
    }

    private func performDelete(_ node: PromptNode) async {
        guard !store.isMutating else { return }
        guard let err = await store.delete(id: node.id) else {
            // 只有确认成功之后才收起展开态（MINOR 3）——回滚的组要带着原来的展开状态重新出现，
            // 不能在还不知道 save() 成不成功时就先收起。
            expandedGroups.remove(node.id)
            return
        }
        showToast(String(localized: "删除失败，已恢复（\(err)）"))
    }

    // MARK: - Toast（拷贝 Community.swift / RecordingDetailView.swift 的 toast 惯例——
    // 这条页原来在 ScrollView 顶部塞一行内联错误文字，删除下滑一屏后的行时用户根本看不到）

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
                .font(.system(size: 15)).foregroundStyle(Theme.ink)
                .padding(.horizontal, 18).padding(.vertical, 12)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().stroke(Theme.borderChrome, lineWidth: 1))
                .padding(.bottom, 32)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// 「适用于」标（仅文字 / 仅图片 / 文字+图片两枚）——PromptManagerView 列表行 AND
/// PromptImportSheet（Task 6）预览卡共用，抽成共享 view 而不是各画一份。
struct AppliesToBadges: View {
    let appliesTo: [String]

    var body: some View {
        let hasText = appliesTo.contains("text")
        let hasImage = appliesTo.contains("image")
        HStack(spacing: 6) {
            if hasText && hasImage {
                tag(String(localized: "文字"), fg: Color(hex: "7A6E5C"), bg: Theme.tileNeutral)
                tag(String(localized: "图片"), fg: Color(hex: "7A6E5C"), bg: Theme.tileNeutral)
            } else if hasText {
                tag(String(localized: "仅文字"), fg: Theme.greenDone, bg: Theme.okBannerBG)
            } else if hasImage {
                tag(String(localized: "仅图片"), fg: Theme.accent, bg: Theme.accentSoft)
            }
        }
    }

    private func tag(_ text: String, fg: Color, bg: Color) -> some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(fg)
            .padding(.vertical, 1).padding(.horizontal, 6)
            .background(bg, in: RoundedRectangle(cornerRadius: 4))
    }
}
