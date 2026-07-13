import SwiftUI
import UIKit

// 设置 → 提示词（5a）：Prompt Manager 重构 Phase 2 的新列表页，替换旧的 InstructionSettingsView
// （旧页仍在文件里，Task 8 再删）。真源 = PromptStore（ref/fork 模型，GET/PUT /agent/prompts）。
// spec: docs/superpowers/specs/2026-07-13-prompt-manager-redesign.md §9
// plan: docs/superpowers/plans/2026-07-14-prompt-manager-phase2-ios.md Task 4/7
//
// Task 7：页面从 ScrollView 改成真正的 `List`——.onMove（拖动排序）和 .swipeActions（1b 左滑
// 删除，替换 Task 4 的长按 contextMenu 临时方案）都要求 List。为了让 List 长得还是「一张白色
// 圆角卡 + 暖色发丝分隔线」而不是系统默认的分组样式：`.listStyle(.plain)` +
// `.scrollContentBackground(.hidden)` 去掉系统底色和默认分组视觉；每行 `.listRowInsets(.zero)`
// + `.listRowBackground(.clear)`，卡片白底/圆角改由行内容自己 `.background(.white)` +
// `.clipShape(RoundedCorner(...))`（只有整卡的第一行/最后一行需要圆角，中间行是直角矩形）；
// 分隔线复用 List 原生 separator（`.listRowSeparatorTint`），不再手画 `settingsRowDivider`。
// 行点击进编辑页原来用 `NavigationLink`——放进 List 后系统会自动在行尾加一个原生 disclosure
// chevron（和我们手画的 `settingsChevron` 重复），换成 `Button` + `.navigationDestination(item:)`
// （页面里 `renameTarget`/`newActionDraft` 已经是这个模式）就完全绕开了这个问题，不需要
// 「NavigationLink→EmptyView()→.opacity(0)」的遮盖技巧。
//
// **排序态的模型（长按进入，「完成」退出并整树 PUT）**：进入时把 `store.items` 复制一份到
// 本地 `draft`，之后所有拖动/拖进拖出操作只改 `draft`，UI 全程从 `draft` 渲染，`store.items`
// 完全不动——直到「完成」才一次 `store.save()`。**为什么不是实时改 store.items**：Task 1-6
// 建立的删除/新建/编辑纪律全部是「改一下就立刻整树 PUT」，但排序途中每拖一次都 PUT 一次既
// 浪费又容易在网络慢的时候拖出竞态；brief 明确要求「一次 store.save() 整树承载」，local draft
// 是唯一能同时满足「实时拖动反馈」和「一次性提交」的做法。
//
// **进组/出组/两级封顶的具体落地**：顶层重排 + 组内重排用 List 原生 `.onMove`（各自一个
// ForEach，天然只能在同一个 ForEach 内部重排，不会互相跨越——这正好就是 brief 要的「顶层与
// 组内各自 onMove」）。**跨组移动**（动作拖进分组）用 iOS 16+ `Transferable`
// `.draggable`/`.dropDestination`——这是一条独立于 onMove 的拖拽会话，可以和 onMove 的拖动
// 手柄共存在同一行上：拖动手柄（trailing，系统画的）触发线性重排；直接按住行体拖动触发
// `.draggable`，落在某个分组行的 `.dropDestination` 上 = 拖进该组末尾（`isTargeted` 给了实时
// 虚线高亮，`PromptLogic.movingIntoGroup` 判断被拖对象是不是 group 来做两级封顶，是则
// 忽略+触觉反馈，不落地）。**拖出分组**没有用真正的跨 Section drop-to-gap（那需要在每个
// 缝隙都放一个 drop target，复杂度和脆弱度都明显更高，brief 也点名这是可接受的降级点）——
// 换成组内子行左滑「移出分组」（`PromptLogic.movingOutOfGroup`，落到顶层末尾），文档化的
// 保真度取舍。
//
// **已知与设计稿的差距（记在这里，报告里也会提）**：
// 1) 「被拖行 scale(1.03)+投影+边框、手柄变色」这组「拖动中实时反馈」——List 原生 onMove 的
//    拖动没有公开 API 暴露「当前是哪一行在被拖」，做不到逐行反馈；只有 .draggable 那条跨组
//    拖拽路径能拿到真实的拖动预览（`reorderDragPreview`，做了同款的白底+琥珀边+投影）。
// 2) List 在 onMove 生效时会在行尾自动画一个系统own的三横线拖动手柄（灰色，位置/颜色不可改）；
//    我们按设计稿在行首另画了一个 `line.3.horizontal`（`#C9C0B1`）——所以排序态每行会有两个
//    手柄图标（系统一个在右，我们画的一个在左），这是保留 onMove 功能的必然代价。
// 3) 卡片整体的 1px 描边（`Theme.borderChrome`）在 List 行拼接下没有做（每行独立描边会在行与
//    行之间露缝）——只做了首行顶部圆角/末行底部圆角 + 发丝分隔线，视觉上仍是「一张白卡」，
//    只是没有外描边和整卡投影。

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
    /// Task 7：动作行点击进编辑页——原来是 `NavigationLink`，放进 List 后会带出系统 disclosure
    /// chevron，改成 Button + item-based `.navigationDestination`（和 renameTarget 同一个模式）。
    @State private var editTarget: PromptNode?
    /// Task 6：导入成功后高亮的新行 id，2 秒后自动清空（`#FBF3E9` 底渐隐）；
    /// `ScrollViewReader` 配合它把列表滚到新行——见 body 里的 ScrollViewReader + rowView。
    @State private var highlightedID: String?

    // MARK: - Task 7：排序态

    @State private var reordering = false
    /// 排序态本地草稿——所有拖动/拖进拖出只改这份，「完成」才整树 PUT（见文件头长注释）。
    @State private var draft: [PromptNode] = []
    /// 进入排序态前的展开集合，退出时（无论完成还是取消）恢复，排序态自己的展开/收起
    /// 不污染正常浏览态。
    @State private var savedExpandedGroups: Set<String> = []
    @State private var showCancelConfirm = false
    /// 跨组拖拽实时高亮：当前正被拖拽悬停的分组行 id（`.dropDestination` 的 isTargeted 回调）。
    @State private var targetedGroupID: String?

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollViewReader { proxy in
                List {
                    Section {
                        Text(introText)
                            .font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
                            .listRowInsets(EdgeInsets(top: 6, leading: 4, bottom: 2, trailing: 4))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }

                    if store.loading && store.items.isEmpty {
                        Section {
                            HStack { Spacer(); ProgressView().tint(Theme.accent); Spacer() }
                                .padding(.top, 40)
                                .listRowInsets(EdgeInsets())
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                        }
                    } else if let err = store.error, store.items.isEmpty {
                        Section {
                            Text(err).font(.system(size: 14)).foregroundStyle(Theme.faint)
                                .frame(maxWidth: .infinity, alignment: .center).padding(.top, 40)
                                .listRowInsets(EdgeInsets())
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                        }
                    } else {
                        Section {
                            if reordering { reorderCardSection } else { normalCardSection }
                        }

                        if !reordering {
                            Section {
                                importBox
                                    .listRowInsets(EdgeInsets())
                                    .listRowSeparator(.hidden)
                                    .listRowBackground(Color.clear)

                                Button {
                                    showRestoreConfirm = true
                                } label: {
                                    Text("恢复默认提示词").font(.system(size: 13)).foregroundStyle(Theme.accent)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.top, 4)
                                .listRowInsets(EdgeInsets())
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .listSectionSpacing(10)
                .environment(\.editMode, .constant(reordering ? .active : .inactive))
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
        .confirmationDialog(String(localized: "放弃这次调整的顺序？"), isPresented: $showCancelConfirm, titleVisibility: .visible) {
            Button(String(localized: "放弃"), role: .destructive) { exitReorderDiscarding() }
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
        .navigationDestination(item: $editTarget) { node in
            PromptEditView(nodeID: node.id)
        }
    }

    private var introText: String {
        reordering
            ? String(localized: "长按左侧手柄拖动排序；把动作拖到分组行上收进该组；组内项左滑「移出分组」。")
            : String(localized: "一套指令，长按文字或图片时按『适用于』自动筛选。改过的系统项标『已自定义』，自己建的标『自建』。")
    }

    private func addGroup(named name: String) async {
        let group = PromptNode(id: PromptLogic.newUserID(), type: "group", label: name, origin: "user", children: [])
        if let err = await store.add(group) {
            showToast(String(localized: "新建分组失败，已恢复（\(err)）"))
        }
    }

    // MARK: - 顶栏（Task 7：排序态下左「取消」右「完成」，替换 ← / ＋）

    private var header: some View {
        HStack(spacing: 14) {
            if reordering {
                Button { cancelReorder() } label: {
                    Text("取消").font(.system(size: 15)).foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.plain)
                .frame(width: 36, height: 36, alignment: .leading)
            } else {
                NavSquare(systemName: "chevron.left", size: 36) { dismiss() }
            }
            Text("提示词").font(.system(size: 26, weight: .semibold)).foregroundStyle(Theme.ink)
            Spacer()
            if reordering {
                Button { commitReorder() } label: {
                    Text("完成").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color(hex: "D8593B"))
                }
                .buttonStyle(.plain)
                .disabled(store.isMutating)
            } else {
                addButton
            }
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 6)
    }

    private var addButton: some View {
        Button { showNewSheet = true } label: {
            RoundedRectangle(cornerRadius: Theme.R.nav)
                .fill(Theme.accent)
                .frame(width: 36, height: 36)
                .overlay(Image(systemName: "plus").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 正常态：行（顶层项 + 展开的组内子项，摊平成一个数组统一画分隔线/圆角）

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

    private func flatRows(_ items: [PromptNode]) -> [Row] {
        items.flatMap { node -> [Row] in
            guard node.type == "group" else { return [.action(node, indent: 0)] }
            var rows: [Row] = [.group(node)]
            if expandedGroups.contains(node.id) {
                rows += (node.children ?? []).map { .action($0, indent: 16) }
            }
            return rows
        }
    }

    @ViewBuilder private var normalCardSection: some View {
        let rows = flatRows(store.items)
        ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
            Group {
                switch row {
                case .group(let node): normalGroupRow(node)
                case .action(let node, let indent): normalActionRow(node, indent: indent)
                }
            }
            .background(Color.white)
            .clipShape(cardCorner(isFirst: i == 0, isLast: i == rows.count - 1))
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
            .listRowSeparatorTint(Theme.dividerInCard)
            .listRowSeparator(i == rows.count - 1 ? .hidden : .visible, edges: .bottom)
        }
    }

    /// Task 7：长按进排序态 vs 点击进编辑页——两个手势必须**互斥**而不是并存。原来用
    /// `Button + .simultaneousGesture(LongPressGesture)`：SwiftUI 的 `Button` 点击判定
    /// 不看按住时长（不像 UIKit `UITapGestureRecognizer` 有默认超时），`simultaneousGesture`
    /// 又明确「两个手势互不阻挡」——按住 0.4s 再松手会**两个都触发**（既进了排序态又跳进了
    /// 编辑页）。改用 `LongPressGesture(...).exclusively(before: TapGesture(...))`：谁先满足
    /// 判定条件就吃掉这次触摸、另一个不再触发，这才是「长按 vs 点击」该有的互斥语义。
    /// 代价：不再是原生 Button，`.accessibilityAddTraits(.isButton)` 补回可访问性语义。
    private func normalActionRow(_ node: PromptNode, indent: CGFloat) -> some View {
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
        // Task 6：导入成功后 2 秒高亮新行——`#FBF3E9` 底，随 highlightedID 清空自动渐隐。
        .background(highlightedID == node.id ? Color(hex: "FBF3E9") : Color.clear)
        .animation(.easeInOut(duration: 0.4), value: highlightedID)
        .gesture(
            LongPressGesture(minimumDuration: 0.4).onEnded { _ in enterReorder() }
                .exclusively(before: TapGesture().onEnded { editTarget = node })
        )
        .accessibilityAddTraits(.isButton)
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { deleteTarget = node } label: {
                Label(String(localized: "删除"), systemImage: "trash")
            }
            .disabled(store.isMutating)
        }
    }

    private func normalGroupRow(_ node: PromptNode) -> some View {
        let expanded = expandedGroups.contains(node.id)
        return HStack(spacing: 12) {
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
        .gesture(
            LongPressGesture(minimumDuration: 0.4).onEnded { _ in enterReorder() }
                .exclusively(before: TapGesture().onEnded {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        if expanded { expandedGroups.remove(node.id) } else { expandedGroups.insert(node.id) }
                    }
                })
        )
        .accessibilityAddTraits(.isButton)
        // Task 7：原来「重命名」在 contextMenu 里（长按弹出）——但 contextMenu 本身就是一个
        // 长按手势识别器，和这个页面新加的「长按任意行进排序态」在同一行上直接抢手势，两个
        // 长按谁触发说不准。挪到左滑（分组行专属，action 行没有这个需要）彻底避开冲突，
        // 也顺应本次改造把「行内操作」统一收进 swipeActions 的方向——比留在 contextMenu 更干净。
        .swipeActions(edge: .leading) {
            Button { renameTarget = node } label: {
                Label(String(localized: "重命名"), systemImage: "pencil")
            }
            .tint(Theme.accent)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { deleteTarget = node } label: {
                Label(String(localized: "删除"), systemImage: "trash")
            }
            .disabled(store.isMutating)
        }
    }

    // MARK: - 排序态：顶层 + 组内各自 onMove，跨组用 draggable/dropDestination

    @ViewBuilder private var reorderCardSection: some View {
        let visibleIDs = reorderVisibleIDs
        ForEach(Array(draft.enumerated()), id: \.element.id) { _, node in
            if node.type == "group" {
                reorderGroupRow(node)
                    .background(Color.white)
                    .clipShape(cardCorner(isFirst: node.id == visibleIDs.first,
                                           isLast: node.id == visibleIDs.last && !expandedGroups.contains(node.id)))
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparatorTint(Theme.dividerInCard)

                if expandedGroups.contains(node.id) {
                    ForEach(Array((node.children ?? []).enumerated()), id: \.element.id) { _, child in
                        reorderChildRow(child)
                            .background(Color.white)
                            .clipShape(cardCorner(isFirst: false, isLast: child.id == visibleIDs.last))
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                            .listRowSeparatorTint(Theme.dividerInCard)
                    }
                    .onMove { from, to in moveWithinGroup(groupID: node.id, from: from, to: to) }
                }
            } else {
                reorderActionRow(node)
                    .background(Color.white)
                    .clipShape(cardCorner(isFirst: node.id == visibleIDs.first, isLast: node.id == visibleIDs.last))
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparatorTint(Theme.dividerInCard)
            }
        }
        .onMove(perform: moveTopLevel)
    }

    /// 排序态当前实际可见的行 id，按渲染顺序——只用来判断哪一行是"整卡最外层"的第一行/
    /// 最后一行（圆角），和具体的 ForEach/onMove 拆分结构无关。
    private var reorderVisibleIDs: [String] {
        draft.flatMap { node -> [String] in
            guard node.type == "group" else { return [node.id] }
            var ids = [node.id]
            if expandedGroups.contains(node.id) { ids += (node.children ?? []).map(\.id) }
            return ids
        }
    }

    private var dragHandle: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 13))
            .foregroundStyle(Color(hex: "C9C0B1"))
            .frame(width: 20)
    }

    private func reorderGroupRow(_ node: PromptNode) -> some View {
        let expanded = expandedGroups.contains(node.id)
        let isTargeted = targetedGroupID == node.id
        return HStack(spacing: 12) {
            dragHandle
            iconTile(bg: Theme.tileNeutral, symbol: "folder", fg: Theme.secondary)
            HStack(spacing: 6) {
                Text(node.label).font(.system(size: 15)).foregroundStyle(Theme.ink)
                originBadge(node.origin)
                Text("分组 · \(node.children?.count ?? 0) 项")
                    .font(.system(size: 12)).foregroundStyle(Theme.sectionLabel)
            }
            Spacer(minLength: 8)
            if isTargeted {
                Text("拖到这里收进分组")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(Color(hex: "D8A25B"))
            } else {
                settingsChevron.rotationEffect(.degrees(expanded ? 90 : 0))
            }
        }
        .padding(.vertical, 12).padding(.horizontal, 15)
        .contentShape(Rectangle())
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color(hex: "D8A25B"), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .opacity(isTargeted ? 1 : 0)
                .padding(2)
        )
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.18)) {
                if expanded { expandedGroups.remove(node.id) } else { expandedGroups.insert(node.id) }
            }
        }
        .draggable(node.id) {
            reorderDragPreview(label: node.label, symbol: "folder")
        }
        .dropDestination(for: String.self) { droppedIDs, _ in
            handleDropIntoGroup(droppedIDs, groupID: node.id)
        } isTargeted: { targeted in
            targetedGroupID = targeted ? node.id : (targetedGroupID == node.id ? nil : targetedGroupID)
        }
    }

    private func reorderActionRow(_ node: PromptNode) -> some View {
        HStack(alignment: .top, spacing: 12) {
            dragHandle
            actionTile(node)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(node.label).font(.system(size: 15)).foregroundStyle(Theme.ink)
                    originBadge(node.origin)
                }
                AppliesToBadges(appliesTo: node.appliesTo ?? [])
            }
            Spacer(minLength: 8)
        }
        .padding(.vertical, 12).padding(.horizontal, 15)
        .contentShape(Rectangle())
        .draggable(node.id) {
            reorderDragPreview(label: node.label, symbol: "text.quote")
        }
    }

    /// 组内子行（缩进 16pt）：多一个左滑「移出分组」——真正的跨 Section 拖拽落点（缝隙间
    /// drop target）复杂度明显更高，这里用 swipe 做保真度取舍（文件头长注释已记录）。
    private func reorderChildRow(_ node: PromptNode) -> some View {
        HStack(alignment: .top, spacing: 12) {
            dragHandle
            actionTile(node)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(node.label).font(.system(size: 15)).foregroundStyle(Theme.ink)
                    originBadge(node.origin)
                }
                AppliesToBadges(appliesTo: node.appliesTo ?? [])
            }
            Spacer(minLength: 8)
        }
        .padding(.leading, 16)
        .padding(.vertical, 12).padding(.horizontal, 15)
        .contentShape(Rectangle())
        .draggable(node.id) {
            reorderDragPreview(label: node.label, symbol: "text.quote")
        }
        .swipeActions(edge: .trailing) {
            Button {
                moveChildOut(childID: node.id)
            } label: {
                Label(String(localized: "移出分组"), systemImage: "arrow.up.right.square")
            }
            .tint(Color(hex: "D8A25B"))
        }
    }

    /// `.draggable` 的拖动预览——onMove 拿不到"当前哪行在被拖"的状态做不了逐行 scale/投影，
    /// 这条跨组拖拽路径是唯一能给出真实拖动态视觉反馈的地方，按设计稿的投影/描边 token 做。
    private func reorderDragPreview(label: String, symbol: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(Theme.accent)
            Text(label).font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.ink)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(hex: "EBD9B8"), lineWidth: 1))
        .shadow(color: Color(.sRGB, red: 60 / 255, green: 48 / 255, blue: 30 / 255, opacity: 0.22), radius: 13, x: 0, y: 6)
    }

    // MARK: - 排序态：进入 / 完成 / 取消

    private func enterReorder() {
        guard !reordering, !store.isMutating else { return }
        savedExpandedGroups = expandedGroups
        draft = store.items
        expandedGroups = []
        reordering = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func cancelReorder() {
        if draft != store.items {
            showCancelConfirm = true
        } else {
            exitReorderDiscarding()
        }
    }

    private func exitReorderDiscarding() {
        draft = []
        expandedGroups = savedExpandedGroups
        reordering = false
    }

    /// 「完成」→ 一次 store.applyReorder(draft) 整树 PUT。失败：store 内部已经把
    /// `store.items` 回滚到排序前的快照，但这里**继续留在排序态、draft 原样不动**——
    /// 用户刚花力气摆好的顺序不因为一次网络失败就白干，toast 提示后可以直接再按一次
    /// 「完成」重试。成功才退出排序态（恢复排序前的展开集合）。
    private func commitReorder() {
        guard !store.isMutating else { return }
        Task {
            if let err = await store.applyReorder(draft) {
                showToast(String(localized: "保存失败，已恢复（\(err)）"))
            } else {
                expandedGroups = savedExpandedGroups
                reordering = false
            }
        }
    }

    private func moveTopLevel(from: IndexSet, to: Int) {
        guard let f = from.first else { return }
        draft = PromptLogic.moving(draft, fromTop: f, toTop: to)
    }

    private func moveWithinGroup(groupID: String, from: IndexSet, to: Int) {
        guard let f = from.first else { return }
        draft = PromptLogic.movingWithinGroup(draft, groupID: groupID, fromChild: f, toChild: to)
    }

    /// 拖进分组：`PromptLogic.movingIntoGroup` 返回 nil = 两级封顶命中（被拖的是个 group）
    /// 或目标/来源找不到——忽略这次 drop（返回 false）+ 触觉反馈；成功则落地并自动展开
    /// 目标组，方便立刻看到新成员落位，返回 true。
    @discardableResult
    private func handleDropIntoGroup(_ droppedIDs: [String], groupID: String) -> Bool {
        guard let actionID = droppedIDs.first else { return false }
        guard let moved = PromptLogic.movingIntoGroup(draft, actionID: actionID, groupID: groupID) else {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
            return false
        }
        withAnimation { draft = moved }
        expandedGroups.insert(groupID)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        return true
    }

    private func moveChildOut(childID: String) {
        draft = PromptLogic.movingOutOfGroup(draft, childID: childID, toTopIndex: draft.count)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
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

    // MARK: - 卡片圆角（只有整卡最外层的第一行/最后一行需要圆角，中间行是直角矩形）

    private func cardCorner(isFirst: Bool, isLast: Bool) -> RoundedCorner {
        var corners: UIRectCorner = []
        if isFirst { corners.formUnion([.topLeft, .topRight]) }
        if isLast { corners.formUnion([.bottomLeft, .bottomRight]) }
        return RoundedCorner(radius: Theme.R.card, corners: corners)
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

    // MARK: - 删除（1b：现在由 .swipeActions 触发，流程本身不变——见 normalActionRow/normalGroupRow）

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

/// Task 7：List 行拼成"一张卡"要只圆第一行/最后一行的角——UIBezierPath 按 corner mask 裁切。
private struct RoundedCorner: Shape {
    var radius: CGFloat = .infinity
    var corners: UIRectCorner = .allCorners

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(roundedRect: rect, byRoundingCorners: corners, cornerRadii: CGSize(width: radius, height: radius))
        return Path(path.cgPath)
    }
}
