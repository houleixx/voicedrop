import SwiftUI
import UIKit

// 设置 → 提示词（5a）：Prompt Manager 重构 Phase 2 的新列表页，替换旧的 InstructionSettingsView
// （旧页仍在文件里，Task 8 再删）。真源 = PromptStore（ref/fork 模型，GET/PUT /agent/prompts）。
// spec: docs/superpowers/specs/2026-07-13-prompt-manager-redesign.md §9
// plan: docs/superpowers/plans/2026-07-14-prompt-manager-phase2-ios.md Task 4/7
//
// **第 6 轮拖拽重构（Task 1，2026-07-14）**：编辑态的拖拽物理彻底换掉。Task 7 的
// `editMode`-driven `.onMove`（顶层/组内两条独立 onMove）+ `.draggable`/`.dropDestination`
// （跨组拖进分组）已经全部删除，换成 `PromptDragEngine`（纯逻辑，见该文件）+ 手写 ≡ 手柄
// `DragGesture` + PreferenceKey 行帧收集 + overlay 浮层跟手 + 琥珀虚线缝隙。
// plan: docs/superpowers/plans/2026-07-14-prompt-manager-drag-6a6d.md Task 1（6a/6b）。
// **容器也换了**：编辑态不再是 List（`.onMove`/`.draggable` 都要求 List），改成
// `ScrollView` + 手画的卡片 `VStack`；普通态（List + 左滑删除/导入/恢复默认/高亮）完全不动。
// **「移出分组」左滑动作已随这次改造删除**——它原来挂在 Task 7 的组内子行上（`reorderChildRow`
// 的 `.swipeActions`），而 `swipeActions` 是 List 专属修饰符，编辑态换成 ScrollView 后这个
// UI 天然消失了，不是本次刻意裁剪的功能。**拖出分组的等价能力（6d「移到分组外」落点区）
// 交给 Task 2**——`PromptDragEngine` 已经把 `.outOfGroup` 判定和落地都实现好并测过了，
// Task 1 只是 UI 层暂时把这个 target 当 `.none` 处理（松手不生效，行弹回原位），代码里
// 标了 `// Task 2` 的位置就是要接张口/落点区视觉的地方。
//
// **排序态的模型（长按进入，「完成」退出并整树 PUT，Task 7 建立、这次原样保留）**：进入时把
// `store.items` 复制一份到本地 `draft`，之后所有拖动/拖进拖出操作只改 `draft`，UI 全程从
// `draft` 渲染，`store.items` 完全不动——直到「完成」才一次 `store.save()`。**为什么不是
// 实时改 store.items**：Task 1-6 建立的删除/新建/编辑纪律全部是「改一下就立刻整树 PUT」，
// 但排序途中每拖一次都 PUT 一次既浪费又容易在网络慢的时候拖出竞态；brief 明确要求
// 「一次 store.save() 整树承载」，local draft 是唯一能同时满足「实时拖动反馈」和
// 「一次性提交」的做法。`enterReorder`/`cancelReorder`/`commitReorder`/`applyReorder`
// （baseline 冲突检测）+ `isMutating` 门 + 退出确认对话框——全部原样保留,是 Task 7 的资产。
//
// **拖拽引擎怎么接**：编辑态每一行用 `.background(GeometryReader...)` 把自己的屏幕帧
// （`RowFrame`）经 `RowFramePreferenceKey` 收进 `rowFrames`（命名坐标空间 `editCoordSpace`）。
// ≡ 手柄（唯一的拖动发起点）挂 `DragGesture(minimumDistance: 2, coordinateSpace: .named(...))`：
// `onChanged` 里把当前手指 Y 喂给 `PromptDragEngine.dropIndex`，算出的 `DropTarget` 变了就
// `withAnimation(.easeOut(duration: 0.15))` 更新；浮起的视觉在 `.overlay` 里跟着 `translation`
// 走。松手（`onEnded`）→ `PromptDragEngine.apply` 落到 `draft`，清空拖拽状态。
//
// **⚠️ 身份修复（review 后补，2026-07-14）**：被拖的那一行**留在 `ForEach` 里、保持同一个
// id**——早先的实现把它整个从 `editRows()` 摘掉，等于让 SwiftUI 在触摸中途销毁承载
// `DragGesture` 的那个视图，手势（含 `onEnded`）可能死在半路：浮层永远收不回、其它行永远
// 停在 0.9 透明度、`editDrag` 悬空——下一次在别的行上开始的拖动会把新坐标写进这个残留
// 状态，视觉上挪的是错的那一行。现在改成"留位置但收起"：`.frame(height: isRowCollapsed ?
// 0 : nil).clipped().opacity(...)`，布局照样"收拢"，视图身份和手势活下来；折叠的行同时
// 不再经 `rowFramePublisher` 发布帧（0 高度的帧会污染 `dropIndex` 的组跨度判定），
// `editRows()` 里的缝隙插入位置相应换算成"跳过折叠行之后数到第几个"（`insertionIndex`）。
// 另外两层防御：① 手柄手势的 `onChanged` 发现 `editDrag` 属于别的行 id 时视为全新拖动，
// 立刻重置而不是往旧状态里写坐标（`dragGesture`）；② `scenePhase` 离开 `.active` 时兜底清空
// （`body` 的 `onChange`）。`cancelReorder`/`commitReorder`/`exitReorderDiscarding` 早就会
// 清 `editDrag`/`dropTarget`，原样保留。
struct PromptManagerView: View {
    @Environment(\.dismiss) private var dismiss
    /// 安全网第三层：切后台/锁屏等场景离开 active 时清空拖拽态（见 body 里的 onChange）——
    /// 万一某次 onEnded 真没触发（系统中断等边界情况，正常路径已被下面两层挡住），
    /// 不留一个悬空的 EditDragState 卡住浮层或污染下一次拖动。
    @Environment(\.scenePhase) private var scenePhase
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
    /// 分组行左滑「重命名」→ push 编辑页（分组没有独立的编辑入口；PromptEditView 对 group 只画名字字段，改名系统 group 会 fork）。
    @State private var renameTarget: PromptNode?
    /// Task 7：动作行点击进编辑页——原来是 `NavigationLink`，放进 List 后会带出系统 disclosure
    /// chevron，改成 Button + item-based `.navigationDestination`（和 renameTarget 同一个模式）。
    @State private var editTarget: PromptNode?
    /// Task 6：导入成功后高亮的新行 id，2 秒后自动清空（`#FBF3E9` 底渐隐）；
    /// `ScrollViewReader` 配合它把列表滚到新行——见 normalModeList 里的 ScrollViewReader + rowView。
    @State private var highlightedID: String?

    // MARK: - 排序态（Task 7 建立，Task 1 只换了拖拽物理，生命周期/落盘全部保留）

    @State private var reordering = false
    /// 排序态本地草稿——所有拖动/拖进拖出只改这份，「完成」才整树 PUT（见文件头长注释）。
    @State private var draft: [PromptNode] = []
    /// 进入排序态前的展开集合，退出时（无论完成还是取消）恢复，排序态自己的展开/收起
    /// 不污染正常浏览态。
    @State private var savedExpandedGroups: Set<String> = []
    /// 进入排序态时的 store.items 扁平 id 序列——用于检测期间的并发 import/深链更新。
    @State private var reorderBaseline: [String] = []
    @State private var showCancelConfirm = false

    // MARK: - 第 6 轮拖拽（6a/6b，Task 1）：≡ 手柄驱动的自定义拖拽状态

    /// 编辑态每一行当前的屏幕帧，命名坐标空间 `editCoordSpace`，`RowFramePreferenceKey` 收集。
    @State private var rowFrames: [RowFrame] = []
    /// 非 nil = 有一行正被 ≡ 手柄拖着走。
    @State private var editDrag: EditDragState?
    /// `PromptDragEngine.dropIndex` 算出的当前落点——驱动缝隙动画 + 松手落地。
    @State private var dropTarget: DropTarget = .none

    var body: some View {
        VStack(spacing: 0) {
            header

            if reordering {
                editModeScrollView
            } else {
                normalModeList
            }
        }
        .background(Theme.appBG.ignoresSafeArea())
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else { return }
            editDrag = nil
            dropTarget = .none
        }
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
            ? String(localized: "拖 ≡ 手柄调顺序；拖到 folder 标题收进去。")
            : String(localized: "一套指令，长按文字或图片时按『适用于』自动筛选。改过的系统项标『已自定义』，自己建的标『自建』。")
    }

    private func addGroup(named name: String) async {
        let group = PromptNode(id: PromptLogic.newUserID(), type: "group", label: name, origin: "user", children: [])
        if let err = await store.add(group) {
            showToast(String(localized: "新建分组失败，已恢复（\(err)）"))
        }
    }

    // MARK: - 顶栏（Task 7：排序态下左「取消」右「完成」，替换 ← / ＋；6a：返回方块隐藏）

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

    // MARK: - 正常态：List（不动）—— 行 = 顶层项 + 展开的组内子项，摊平成一个数组统一画分隔线/圆角

    private var normalModeList: some View {
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
                    if store.error != nil {
                        Section {
                            HStack(spacing: 12) {
                                Text("加载失败，显示的可能不是最新列表")
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(Color(hex: "B98A3E"))
                                Spacer()
                                Button {
                                    Task { await store.refresh() }
                                } label: {
                                    Text("重试")
                                        .font(.system(size: 13))
                                        .foregroundStyle(Theme.accent)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(10)
                            .background(Color(hex: "FBF3E9"), in: RoundedRectangle(cornerRadius: 8))
                            .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 10, trailing: 4))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                        }
                    }
                    Section {
                        normalCardSection
                    }
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
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .listSectionSpacing(10)
            .onChange(of: highlightedID) { _, id in
                guard let id else { return }
                withAnimation { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

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

    // MARK: - 编辑态（第 6 轮拖拽，6a/6b）：ScrollView + 手写卡片，≡ 手柄驱动 PromptDragEngine

    private let editCoordSpace = "promptManagerEditRows"

    private var editModeScrollView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(introText)
                    .font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
                    .padding(.horizontal, 19)
                    .padding(.top, 6)
                editList
            }
            .padding(.bottom, 24)
        }
    }

    /// 编辑态当前应渲染的行序列：被拖的那一行（连同——如果拖的是展开着的 folder 标题——它
    /// 露出来的孤儿子行）**留在数组里**（身份修复，见文件头长注释），渲染时靠 `isRowCollapsed`
    /// 收成 0 高度；当前 `dropTarget` 若是 `.reorder`，在对应 scope 里插入一个 44pt 缝隙占位。
    /// `.intoGroup`/`.outOfGroup`/`.none` 不出缝隙——folder 张口 / 移出区是 Task 2 的活，
    /// Task 1 阶段悬停在这些落点上时列表就正常收拢，松手也不生效。
    private func editRows() -> [EditRow] {
        var topLevelChunks: [[EditRow]] = []

        for node in draft {
            if node.type == "group" {
                var chunk: [EditRow] = [.group(node)]
                if expandedGroups.contains(node.id) {
                    var children: [EditRow] = (node.children ?? []).map { .child($0, parent: node.id) }
                    if case .reorder(let index, let scope) = dropTarget, scope == .group(node.id) {
                        let insertAt = insertionIndex(in: children, target: max(index, 0), isCollapsed: isRowCollapsed)
                        children.insert(.gap, at: insertAt)
                    }
                    chunk += children
                }
                topLevelChunks.append(chunk)
            } else {
                topLevelChunks.append([.action(node)])
            }
        }

        if case .reorder(let index, .topLevel) = dropTarget {
            let insertAt = insertionIndex(in: topLevelChunks, target: max(index, 0)) { chunk in
                chunk.first.map(isRowCollapsed) ?? false
            }
            topLevelChunks.insert([.gap], at: insertAt)
        }

        return topLevelChunks.flatMap { $0 }
    }

    /// 折叠判定——被拖的那一行本身，或者（拖的是某个展开着的 folder 标题时）它名下的子行：
    /// 之前整块从流里摘掉，现在只让承载手势的那一行留在树里，若不连带把孤儿子行也一起收起，
    /// 会出现"标题飞在浮层里、没头的子行还占着位置"。用同一份判定同时喂
    /// `rowFramePublisher`（折叠的行不发布帧，0 高度的帧不该进 `dropIndex` 的几何计算）。
    private func isCollapsed(id: String, kind: RowFrame.Kind) -> Bool {
        guard let draggedID = editDrag?.id else { return false }
        if id == draggedID { return true }
        if case .child(let parent) = kind, parent == draggedID { return true }
        return false
    }

    private func isRowCollapsed(_ row: EditRow) -> Bool {
        switch row {
        case .group(let n): return isCollapsed(id: n.id, kind: .groupTitle)
        case .action(let n): return isCollapsed(id: n.id, kind: .action)
        case .child(let n, let parent): return isCollapsed(id: n.id, kind: .child(parent: parent))
        case .gap: return false
        }
    }

    /// `PromptDragEngine.dropIndex` 给出的 index 是"排除被拖（含折叠）元素后，插入到第几个
    /// 可见元素之前"；被拖元素现在仍留在数组里撑住视图身份，这里把 index 换算回真实数组
    /// 下标——从头数，跳过折叠元素，数到第 index 个可见元素时就是插入点，数不够则插到最后。
    private func insertionIndex<T>(in elements: [T], target index: Int, isCollapsed: (T) -> Bool) -> Int {
        var seen = 0
        for (i, element) in elements.enumerated() where !isCollapsed(element) {
            if seen == index { return i }
            seen += 1
        }
        return elements.count
    }

    private var editList: some View {
        let rows = editRows()
        return VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                if isGapRow(row) {
                    dropGapView
                } else {
                    let collapsed = isRowCollapsed(row)
                    let isFirst = i == 0 || isGapRow(rows[i - 1])
                    let isLast = i == rows.count - 1 || isGapRow(rows[i + 1])
                    editRowContent(row)
                        .background(Color.white)
                        .clipShape(cardCorner(isFirst: isFirst, isLast: isLast))
                        .overlay(alignment: .bottom) {
                            if !isLast {
                                Rectangle().fill(Theme.dividerInCard).frame(height: 1)
                            }
                        }
                        // 身份修复：被拖（或孤儿子）行留在树里，靠 0 高度 + clipped + opacity 0
                        // 视觉收起——"收拢"的布局效果不变，但视图身份/手势活着（见文件头长注释）。
                        .frame(height: collapsed ? 0 : nil)
                        .clipped()
                        .opacity(collapsed ? 0 : 1)
                }
            }
        }
        .opacity(editDrag == nil ? 1 : 0.9) // 6b：拖动中其余行 opacity 0.9
        .coordinateSpace(name: editCoordSpace)
        .overlay(alignment: .topLeading) { floatingDragOverlay }
        .onPreferenceChange(RowFramePreferenceKey.self) { rowFrames = $0 }
    }

    private func isGapRow(_ row: EditRow) -> Bool {
        if case .gap = row { return true }
        return false
    }

    @ViewBuilder
    private func editRowContent(_ row: EditRow) -> some View {
        switch row {
        case .group(let node): editGroupRow(node)
        case .action(let node): editActionRow(node)
        case .child(let node, let parent): editChildRow(node, parent: parent)
        case .gap: EmptyView()
        }
    }

    /// 6a：folder 默认收起（`enterReorder` 已把 `expandedGroups` 清空）——行 = 手柄 + folder
    /// 图标（30×30 `#F1ECE3`，图标 `#7A6E5C`）+ 名字 15 + 「N 项」12 `#b8ae9e` + ⌄ `#CFC6B6`。
    /// 6d：点标题仍可展开/收起（组内调序在 Task 1 已可用，收纳/移出落点区留 Task 2）。
    private func editGroupRow(_ node: PromptNode) -> some View {
        let expanded = expandedGroups.contains(node.id)
        return HStack(spacing: 12) {
            editHandle(active: editDrag?.id == node.id)
                .frame(width: 30, height: 44)
                .contentShape(Rectangle())
                .gesture(dragGesture(for: node.id, kind: .groupTitle, label: node.label, symbol: "folder"))
            RoundedRectangle(cornerRadius: Theme.R.promptEditTile)
                .fill(Theme.tileNeutral)
                .frame(width: 30, height: 30)
                .overlay(Image(systemName: "folder").font(.system(size: 13)).foregroundStyle(Color(hex: "7A6E5C")))
            Text(node.label).font(.system(size: 15)).foregroundStyle(Theme.ink)
            Spacer(minLength: 8)
            if !expanded {
                Text("\(node.children?.count ?? 0) 项")
                    .font(.system(size: 12)).foregroundStyle(Color(hex: "b8ae9e"))
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color(hex: "CFC6B6"))
                .rotationEffect(.degrees(expanded ? 180 : 0))
        }
        .padding(.vertical, 12).padding(.horizontal, 15)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.18)) {
                if expanded { expandedGroups.remove(node.id) } else { expandedGroups.insert(node.id) }
            }
        }
        .background(rowFramePublisher(id: node.id, kind: .groupTitle))
    }

    /// 6a：行右尖角/适用于标/origin 标全部隐藏——编辑态行 = 手柄 + 图标块 + 名字。
    private func editActionRow(_ node: PromptNode) -> some View {
        HStack(spacing: 12) {
            editHandle(active: editDrag?.id == node.id)
                .frame(width: 30, height: 44)
                .contentShape(Rectangle())
                .gesture(dragGesture(for: node.id, kind: .action, label: node.label, symbol: actionSymbol(node)))
            actionTile(node, cornerRadius: Theme.R.promptEditTile)
            Text(node.label).font(.system(size: 15)).foregroundStyle(Theme.ink)
            Spacer(minLength: 8)
        }
        .padding(.vertical, 12).padding(.horizontal, 15)
        .background(rowFramePublisher(id: node.id, kind: .action))
    }

    /// 6d：组内行——缩进 30、图标 26×26/圆角 6、名字 14.5，自带 ≡ 手柄。组内互相调序走同一套
    /// `PromptDragEngine`（scope `.group`），Task 1 已完整可用；拖进/挪出组的落点视觉
    /// （6c 张口 + 6d「移到分组外」）是 Task 2 的活——这里手指越出组边界只是不落地，
    /// 松手行弹回原位（`commitDrag` 对 `.intoGroup`/`.outOfGroup` 是 no-op，标了 `// Task 2`）。
    private func editChildRow(_ node: PromptNode, parent: String) -> some View {
        HStack(spacing: 10) {
            editHandle(active: editDrag?.id == node.id)
                .frame(width: 26, height: 40)
                .contentShape(Rectangle())
                .gesture(dragGesture(for: node.id, kind: .child(parent: parent), label: node.label, symbol: actionSymbol(node)))
            iconTile(bg: isImageOnly(node) ? Theme.accentSoft : Theme.tileNeutral,
                     symbol: actionSymbol(node),
                     fg: isImageOnly(node) ? Theme.accent : Theme.secondary,
                     size: 26, iconSize: 12, cornerRadius: Theme.R.promptEditChildTile)
            Text(node.label).font(.system(size: 14.5)).foregroundStyle(Theme.ink)
            Spacer(minLength: 8)
        }
        .padding(.leading, 30).padding(.vertical, 10).padding(.trailing, 15)
        .background(rowFramePublisher(id: node.id, kind: .child(parent: parent)))
    }

    private func editHandle(active: Bool) -> some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 16, weight: active ? .semibold : .medium))
            .foregroundStyle(active ? Color(hex: "D8A25B") : Color(hex: "C9C0B1"))
    }

    /// 折叠（被拖/孤儿子行）时不发布帧——0 高度的帧一旦被 `PromptDragEngine.dropIndex` 读到
    /// 会污染组跨度（`groupRows` 的 minY/maxY）等几何判定；起点帧在拖动开始那一刻已经从
    /// `rowFrames` 里取过一次快照（`dragGesture`），后续折叠不再更新它不影响浮层跟手。
    private func rowFramePublisher(id: String, kind: RowFrame.Kind) -> some View {
        GeometryReader { geo in
            Color.clear.preference(
                key: RowFramePreferenceKey.self,
                value: isCollapsed(id: id, kind: kind) ? [] : [RowFrame(id: id, frame: geo.frame(in: .named(editCoordSpace)), kind: kind)]
            )
        }
    }

    /// 6b：琥珀虚线缝隙——高 44、margin 5×10、1.5pt dashed `#D8A25B`、圆角 8、底 `#FBF3E9`、无文字。
    private var dropGapView: some View {
        RoundedRectangle(cornerRadius: 8)
            .strokeBorder(Color(hex: "D8A25B"), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            .background(Color(hex: "FBF3E9"), in: RoundedRectangle(cornerRadius: 8))
            .frame(height: 44)
            .padding(.vertical, 5)
            .padding(.horizontal, 10)
            .transition(.opacity)
    }

    /// 6b：浮起行跟手——scale(1.03)、投影 `0 14 30 rgba(60,48,30,0.26)`、边 1px `#EBD9B8`、
    /// 圆角 9、手柄 `#D8A25B`、名字 semibold。位置 = 起点帧中心 + 手指位移（不是直接贴手指，
    /// 保持抓取点相对行的位置不跳）。
    @ViewBuilder
    private var floatingDragOverlay: some View {
        if let d = editDrag {
            HStack(spacing: 12) {
                editHandle(active: true).frame(width: 30, height: 44)
                iconTile(bg: Theme.tileNeutral, symbol: d.symbol, fg: Theme.secondary)
                Text(d.label).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                Spacer(minLength: 8)
            }
            .padding(.vertical, 12).padding(.horizontal, 15)
            .frame(width: d.originFrame.width, height: d.originFrame.height, alignment: .leading)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color(hex: "EBD9B8"), lineWidth: 1))
            .shadow(color: Color(.sRGB, red: 60 / 255, green: 48 / 255, blue: 30 / 255, opacity: 0.26), radius: 15, x: 0, y: 14)
            .scaleEffect(1.03)
            .position(x: d.originFrame.midX, y: d.originFrame.midY + d.translation.height)
            .allowsHitTesting(false)
        }
    }

    private func actionSymbol(_ node: PromptNode) -> String {
        isImageOnly(node) ? "photo" : "text.quote"
    }

    private func isImageOnly(_ node: PromptNode) -> Bool {
        (node.appliesTo ?? []) == ["image"]
    }

    /// ≡ 手柄的拖拽手势——**唯一的拖动发起点**，挂在手柄的 30×44（组内行 26×40）命中区上，
    /// 不挂在整行，行体的其它点击（folder 标题展开/收起）互不打架。
    private func dragGesture(for id: String, kind: RowFrame.Kind, label: String, symbol: String) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(editCoordSpace))
            .onChanged { value in
                // 接管守卫（安全网第二层）：身份修复后正常情况下不会走到这——但万一某次
                // onEnded 真没触发（系统中断等边界情况），残留的 editDrag 属于别的行时，
                // 这次触摸必须当全新拖动处理，绝不把新坐标写进那份陈旧状态（否则视觉上会
                // 挪动错误的那一行）。
                if editDrag != nil && editDrag?.id != id {
                    editDrag = nil
                    dropTarget = .none
                }
                if editDrag == nil {
                    guard let origin = rowFrames.first(where: { $0.id == id })?.frame else { return }
                    editDrag = EditDragState(id: id, kind: kind, label: label, symbol: symbol, originFrame: origin)
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }
                editDrag?.translation = value.translation
                editDrag?.fingerY = value.location.y
                recomputeDropTarget()
            }
            .onEnded { _ in commitDrag() }
    }

    private func recomputeDropTarget() {
        guard let d = editDrag else { return }
        let target = PromptDragEngine.dropIndex(fingerY: d.fingerY, rows: rowFrames, draggedID: d.id, draggedKind: d.kind, items: draft)
        guard target != dropTarget else { return }
        withAnimation(.easeOut(duration: 0.15)) { dropTarget = target }
    }

    private func commitDrag() {
        guard let d = editDrag else { return }
        if case .reorder = dropTarget, let moved = PromptDragEngine.apply(dropTarget, draggedID: d.id, items: draft) {
            draft = moved
        }
        // .intoGroup / .outOfGroup / .none：Task 1 阶段松手不落地（Task 2 接 6c 张口收纳 +
        // 6d「移到分组外」落点区的视觉与落地）。
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.easeOut(duration: 0.15)) {
            editDrag = nil
            dropTarget = .none
        }
    }

    // MARK: - 排序态：进入 / 完成 / 取消

    private func enterReorder() {
        guard !reordering, !store.isMutating else { return }
        savedExpandedGroups = expandedGroups
        draft = store.items
        reorderBaseline = PromptLogic.flattenIDs(store.items)
        expandedGroups = [] // 6a：进编辑态 folder 默认全部收起
        editDrag = nil
        dropTarget = .none
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
        editDrag = nil
        dropTarget = .none
        reordering = false
    }

    /// 「完成」→ 一次 store.applyReorder(draft, baseline:) 整树 PUT。失败：store 内部已经把
    /// `store.items` 回滚到排序前的快照，但这里**继续留在排序态、draft 原样不动**——
    /// 用户刚花力气摆好的顺序不因为一次网络失败就白干，toast 提示后可以直接再按一次
    /// 「完成」重试。成功才退出排序态（恢复排序前的展开集合）。
    /// 冲突检测：如果期间有并发 import/深链更新，baseline 校验拒绝此次 PUT 并返回"已在别处更新"，
    /// 用户刷新列表重新调整。
    private func commitReorder() {
        guard !store.isMutating else { return }
        Task {
            if let err = await store.applyReorder(draft, baseline: reorderBaseline) {
                showToast(String(localized: "保存失败，已恢复（\(err)）"))
            } else {
                expandedGroups = savedExpandedGroups
                editDrag = nil
                dropTarget = .none
                reordering = false
            }
        }
    }

    // MARK: - 图标块 / 标

    private func iconTile(bg: Color, symbol: String, fg: Color, size: CGFloat = 34, iconSize: CGFloat = 14, cornerRadius: CGFloat = Theme.R.tile) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(bg)
            .frame(width: size, height: size)
            .overlay(Image(systemName: symbol).font(.system(size: iconSize)).foregroundStyle(fg))
    }

    /// 图标按内容挑：只适用于图片的动作用 photo/赭红，其余（仅文字或都行）用 text.quote/中性灰。
    /// `cornerRadius` 可选覆盖——正常态调用不传，维持 `Theme.R.tile`(8)；编辑态行
    /// （editActionRow）传 `Theme.R.promptEditTile`(7)，对齐 editGroupRow 的 folder 图标。
    private func actionTile(_ node: PromptNode, cornerRadius: CGFloat = Theme.R.tile) -> some View {
        iconTile(bg: isImageOnly(node) ? Theme.accentSoft : Theme.tileNeutral,
                  symbol: isImageOnly(node) ? "photo" : "text.quote",
                  fg: isImageOnly(node) ? Theme.accent : Theme.secondary,
                  cornerRadius: cornerRadius)
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

// MARK: - 第 6 轮拖拽（Task 1）：编辑态私有辅助类型

/// 正在被 ≡ 手柄拖着走的那一行的状态——起点帧 + 实时位移，驱动浮层跟手与 `dropIndex` 判定。
private struct EditDragState {
    let id: String
    let kind: RowFrame.Kind
    let label: String
    let symbol: String
    let originFrame: CGRect
    var translation: CGSize = .zero
    var fingerY: CGFloat = 0
}

/// 编辑态渲染用的行——比 `PromptNode` 多一个 `.gap`（当前落点的琥珀虚线缝隙占位）。
private enum EditRow: Identifiable {
    case group(PromptNode)
    case action(PromptNode)
    case child(PromptNode, parent: String)
    case gap

    var id: String {
        switch self {
        case .group(let n): return n.id
        case .action(let n): return n.id
        case .child(let n, _): return n.id
        case .gap: return "‹gap›" // 同一时刻至多一个缝隙，固定 id 足够
        }
    }
}

/// 收集编辑态每一行在 `editCoordSpace` 命名坐标空间里的屏幕帧，喂给 `PromptDragEngine`。
private struct RowFramePreferenceKey: PreferenceKey {
    static var defaultValue: [RowFrame] { [] } // 计算属性，不是存储的可变全局状态——Swift 6 并发检查要求
    static func reduce(value: inout [RowFrame], nextValue: () -> [RowFrame]) {
        value += nextValue()
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
