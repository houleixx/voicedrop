import SwiftUI
import UIKit

// Prompt Manager Phase 2（iOS）—— 5c 编辑页：名字/提示词/适用于两开关 + 分享卡，
// 核心是 fork-on-edit（改一条系统项 = 客户端实体化成 p_ 新项再整树 PUT）。
// spec: docs/superpowers/specs/2026-07-13-prompt-manager-redesign.md §3/§9
// plan: docs/superpowers/plans/2026-07-14-prompt-manager-phase2-ios.md Task 5
//
// 两种模式：
// - 编辑已有节点（`init(nodeID:)`）：节点每次都从 `store.items` 里活查（不留自己的快照），
//   这样 fork 保存后 id 变了，下一次查找立刻跟上新 id——分享卡、dirty 判断全部自动跟着走。
// - 新建（`init(draft:)`，PromptNewSheet「新建动作」用）：节点还不在 store.items 里，
//   本地持有这份草稿；保存 = 追加到列表末尾。
//
// 保存后**不自动退出**（区别于老 InstructionEditView）：分享卡要展示「fork 后码跟着换新
// id 但码本身不变」这件事，只有留在页面上才看得见；新建流程保存后才 dismiss，因为新建
// 没有「继续看分享卡」这一说（草稿还没进 store，不能分享）。

struct PromptEditView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store = PromptStore.shared

    private let isCreate: Bool
    @State private var currentID: String
    @State private var draftNode: PromptNode?

    @State private var nameDraft = ""
    @State private var promptDraft = ""
    @State private var appliesToDraft: Set<String> = []
    @State private var textShake: CGFloat = 0
    @State private var imageShake: CGFloat = 0

    @State private var saving = false
    @State private var toast: String?

    // 分享卡
    @State private var shareStates: [String: ShareState] = [:]
    @State private var shareToggling = false
    @State private var shareError: String?
    @State private var codeCopied = false
    @State private var linkCopied = false
    @State private var sharePayload: ShareCodePayload?

    /// 编辑已有节点：id 活查 `store.items`（顶层或组内子项）。
    init(nodeID: String) {
        isCreate = false
        _currentID = State(initialValue: nodeID)
        _draftNode = State(initialValue: nil)
    }

    /// 新建：节点还不在 store.items 里，本地持有草稿，保存时才追加进列表。
    init(draft: PromptNode) {
        isCreate = true
        _currentID = State(initialValue: draft.id)
        _draftNode = State(initialValue: draft)
    }

    private var node: PromptNode? {
        isCreate ? draftNode : Self.find(currentID, in: store.items)
    }

    private static func find(_ id: String, in items: [PromptNode]) -> PromptNode? {
        for item in items {
            if item.id == id { return item }
            if let child = item.children?.first(where: { $0.id == id }) { return child }
        }
        return nil
    }

    private var isGroup: Bool { node?.type == "group" }

    private var orderedAppliesTo: [String] {
        ["text", "image"].filter { appliesToDraft.contains($0) }
    }

    private var dirty: Bool {
        guard let node else { return false }
        if isGroup { return nameDraft != node.label }
        return nameDraft != node.label
            || promptDraft != (node.prompt ?? "")
            || appliesToDraft != Set(node.appliesTo ?? [])
    }

    private var canSave: Bool {
        guard node != nil else { return false }

        // Always require non-empty trimmed name (both create and edit modes)
        let nameTrimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nameTrimmed.isEmpty else { return false }

        // For actions (not groups), also require non-empty trimmed prompt (both create and edit modes)
        if !isGroup {
            let promptTrimmed = promptDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !promptTrimmed.isEmpty else { return false }
        }

        // In create mode, the checks above are sufficient
        if isCreate {
            return true
        }

        // In edit mode, additionally require dirty
        return dirty
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    nameField
                    if !isGroup {
                        promptField
                        appliesToBlock
                        if !isCreate {
                            shareCard
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 40)
            }
        }
        .background(Theme.appBG.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .bottom) { toastView }
        .sheet(item: $sharePayload) { ShareSheet(items: [$0.url]) }
        .task {
            nameDraft = node?.label ?? ""
            promptDraft = node?.prompt ?? ""
            appliesToDraft = Set(node?.appliesTo ?? (isCreate ? ["text", "image"] : []))
            if !isCreate && !isGroup {
                await refreshShareStates()
            }
        }
    }

    // MARK: - 顶栏

    private var header: some View {
        HStack(spacing: 14) {
            NavSquare(systemName: "chevron.left", size: 36) { dismiss() }
            Text((node?.label.isEmpty ?? true) ? String(localized: "提示词") : (node?.label ?? ""))
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Theme.ink).lineLimit(1)
            Spacer()
            saveButton
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 6)
    }

    private var saveButton: some View {
        Button {
            Task { await performSave() }
        } label: {
            if saving {
                ProgressView().tint(.white).frame(width: 52, height: 34)
            } else {
                Text("保存").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 52, height: 34)
            }
        }
        .background(canSave ? Theme.accent : Theme.faint, in: RoundedRectangle(cornerRadius: 9))
        .disabled(!canSave || saving || store.isMutating || shareToggling)
    }

    // MARK: - 字段

    private var nameField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("菜单里的名字").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.secondary)
            TextField("", text: $nameDraft)
                .font(.system(size: 15)).foregroundStyle(Theme.ink)
                .padding(.horizontal, 12).frame(height: 44)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var promptField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("提示词").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.secondary)
            TextEditor(text: $promptDraft)
                .font(.system(size: 15)).foregroundStyle(Theme.ink)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 150)
                .padding(10)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: - 「适用于」两开关

    private var appliesToBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("适用于").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.secondary)
                Spacer()
                Text("决定在哪种长按里出现").font(.system(size: 12)).foregroundStyle(Theme.faint)
            }
            HStack(spacing: 10) {
                appliesToggle(.text, icon: "pencil", label: String(localized: "文字"))
                appliesToggle(.image, icon: "photo", label: String(localized: "图片"))
            }
        }
    }

    private func appliesToggle(_ anchor: PromptAnchor, icon: String, label: String) -> some View {
        let selected = appliesToDraft.contains(anchor.rawValue)
        return Button {
            toggleApplies(anchor)
        } label: {
            VStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 18))
                Text(label).font(.system(size: 13, weight: .semibold))
                if selected {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold))
                } else {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color(hex: "D8CFC0"), lineWidth: 1.5)
                        .frame(width: 15, height: 15)
                }
            }
            .foregroundStyle(selected ? Theme.accent : Theme.sectionLabel)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(selected ? Theme.accent : Theme.fuBorder, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .offset(x: anchor == .text ? textShake : imageShake)
    }

    private func toggleApplies(_ anchor: PromptAnchor) {
        let key = anchor.rawValue
        if !appliesToDraft.contains(key) {
            appliesToDraft.insert(key)
            return
        }
        guard appliesToDraft.count > 1 else {
            shake(anchor)
            return
        }
        appliesToDraft.remove(key)
    }

    /// 取消最后一个开关时的抖动反馈（offset keyframes）：不生效，只是告诉用户「不行」。
    private func shake(_ anchor: PromptAnchor) {
        let keyframes: [CGFloat] = [0, -6, 6, -4, 4, 0]
        Task {
            for offset in keyframes {
                withAnimation(.easeInOut(duration: 0.05)) {
                    if anchor == .text { textShake = offset } else { imageShake = offset }
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    // MARK: - 保存语义（核心）

    private func performSave() async {
        guard let node, canSave, !saving else { return }
        saving = true
        defer { saving = false }

        // Trim fields before building the node to save
        let trimmedName = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = promptDraft.trimmingCharacters(in: .whitespacesAndNewlines)

        if isCreate {
            var newNode = node
            newNode.label = trimmedName
            newNode.prompt = trimmedPrompt
            newNode.appliesTo = orderedAppliesTo
            guard let err = await store.add(newNode) else { dismiss(); return }
            showToast(err)
            return
        }

        var edited = node
        edited.label = trimmedName
        if !isGroup {
            edited.prompt = trimmedPrompt
            edited.appliesTo = orderedAppliesTo
        }
        // origin=="system" 的项一旦 dirty 保存 → 客户端实体化（fork）：新 p_ id +
        // forkedFrom + origin=custom，替换原位置节点；custom/user 直接原位改字段。
        let toSave = node.origin == "system" ? PromptLogic.fork(edited) : edited

        guard let err = await store.replace(id: currentID, with: toSave) else {
            // fork 换了 id：下次 `node` 活查会跟着换——dirty 因此自动归零，分享卡的
            // key 也自动跟着新 id 走（服务端已经把码 re-key 过去，Task 1）。
            currentID = toSave.id
            if !isGroup { await refreshShareStates() }
            return
        }
        showToast(err)
    }

    // MARK: - 分享卡（照搬 InstructionSettingsView.shareCard/shareAction/ShareCodePayload，
    // 数据源换成 store.shareStates()/store.setSharing(id:on:)，分享键 = 当前节点 id）

    @ViewBuilder private var shareCard: some View {
        let sharing = shareStates[currentID]?.sharing ?? false
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("分享这条提示词").font(.system(size: 15)).foregroundStyle(Theme.ink)
                    Text(sharing ? "分享中，关闭后分享码立即失效"
                                 : "开启后，任何人对 VoiceDrop 说出分享码，或打开链接，就能看到并一次性使用这条提示词")
                        .font(.system(size: 12)).foregroundStyle(Theme.faint)
                }
                Spacer()
                if shareToggling {
                    ProgressView().tint(Theme.accent).frame(width: 51)
                } else {
                    Toggle("", isOn: Binding(get: { sharing }, set: { on in
                        Task { await toggleSharing(on) }
                    }))
                    .labelsHidden().tint(Theme.accent)
                    .disabled(saving || store.isMutating)
                }
            }
            if let err = shareError {
                Text(err).font(.system(size: 12.5)).foregroundStyle(Theme.accent)
            }
            if sharing, let code = shareStates[currentID]?.code {
                VStack(spacing: 10) {
                    Text(code)
                        .font(.system(size: 34, weight: .bold, design: .monospaced)).tracking(6)
                        .foregroundStyle(Theme.ink)
                        .frame(maxWidth: .infinity)
                    Text("voicedrop.cn/\(code)").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                    HStack(spacing: 8) {
                        shareAction(codeCopied ? String(localized: "已复制") : String(localized: "复制数字"),
                                    codeCopied ? "checkmark" : "doc.on.doc") {
                            UIPasteboard.general.string = code
                            codeCopied = true
                            Task { try? await Task.sleep(nanoseconds: 1_800_000_000); codeCopied = false }
                        }
                        shareAction(linkCopied ? String(localized: "已复制") : String(localized: "复制链接"),
                                    linkCopied ? "checkmark" : "link") {
                            UIPasteboard.general.string = API.sharePage(code).absoluteString
                            linkCopied = true
                            Task { try? await Task.sleep(nanoseconds: 1_800_000_000); linkCopied = false }
                        }
                        shareAction(String(localized: "分享…"), "square.and.arrow.up") {
                            sharePayload = ShareCodePayload(code: code, label: nameDraft.isEmpty ? (node?.label ?? "") : nameDraft)
                        }
                    }
                    if dirty {
                        Text("分享的始终是已保存的版本").font(.system(size: 12)).foregroundStyle(Theme.faint)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
    }

    private func shareAction(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
                Text(title).font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(Theme.accent)
            .frame(maxWidth: .infinity).frame(height: 34)
            .background(Theme.accentSoft, in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
    }

    private func toggleSharing(_ on: Bool) async {
        shareToggling = true; shareError = nil
        shareError = await store.setSharing(id: currentID, on: on)
        shareToggling = false
        await refreshShareStates()
    }

    /// fork 保存后分享码在服务端被 re-key 到新 id（Task 1），每次 save 后都要重新拉
    /// 一次状态，分享卡才会跟着新 id 走而不是停在旧内容上。
    private func refreshShareStates() async {
        shareStates = await store.shareStates()
    }

    // MARK: - Toast（保存失败：Task 4 引入的惯例，替代老页面内联的「保存失败，请重试」）

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

/// 系统分享 sheet 的载荷：直接分享落地页 URL——纯文本文案微信收不了（分享面板里
/// 点微信没反应），URL 会落成可点的链接；落地页本身已把「码 + 怎么用 + 下载」讲清楚。
/// （照搬自 InstructionSettingsView.swift，老页面 Task 8 才删，两边各留一份。）
private struct ShareCodePayload: Identifiable {
    let code: String
    let label: String
    var id: String { code }
    var url: URL { API.sharePage(code) }
}
