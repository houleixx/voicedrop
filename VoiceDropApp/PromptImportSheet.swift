import SwiftUI

// Prompt Manager Phase 2（iOS）—— 4b 导入 sheet：输入/粘贴 7 位魔法数字或分享链接 →
// 自动查预览 →「加入我的提示词」。两条入口共用同一个 sheet：
//   1. PromptManagerView 里「输入魔法数字导入」虚线框按钮（`prefill: nil`）。
//   2. voicedrop.cn/<7位数字> universal link（`prefill` = 深链里的码，Task 6 Part B，
//      见 AppRouter.swift 的 `.promptImport` case + LibraryView.swift 的分发处）。
// spec: docs/superpowers/specs/2026-07-13-prompt-manager-redesign.md §9
// plan: docs/superpowers/plans/2026-07-14-prompt-manager-phase2-ios.md Task 6
//
// `onImported` 在深链路径下是默认 no-op：LibraryView 直接从根上弹本 sheet（PromptManagerView
// 未必在屏幕上），此时导入成功只是单纯关掉 sheet，没有列表可滚/高亮——见 Task 6 报告里
// 记的取舍。PromptManagerView 自己弹这个 sheet 时才传真正的回调（设 highlightedID 触发
// ScrollViewReader 滚动 + 2 秒高亮渐隐）。

struct PromptImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFocused: Bool

    private let onImported: (PromptNode) -> Void

    @State private var code: String
    @State private var previewState: PreviewState = .idle
    @State private var importing = false
    @State private var previewTask: Task<Void, Never>?

    init(prefill: String? = nil, onImported: @escaping (PromptNode) -> Void = { _ in }) {
        self.onImported = onImported
        _code = State(initialValue: Self.sanitize(prefill ?? ""))
    }

    private enum PreviewState {
        case idle
        case loading
        case loaded(SharePreview)
        case notFound
        case error(String)
    }

    var body: some View {
        VStack(spacing: 18) {
            header
            inputField
            previewSlot
            primaryButton
            footnote
        }
        .padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 24)
        .background(Theme.appBG.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .task {
            isFocused = code.isEmpty
            if code.count == 7 { fetchPreview(for: code) }
        }
    }

    // MARK: - 顶部

    private var header: some View {
        VStack(spacing: 4) {
            Text("导入提示词").font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.ink)
            Text("输入 7 位魔法数字，或粘贴分享链接").font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
        }
        .padding(.top, 6)
    }

    // MARK: - 输入框

    private var inputField: some View {
        TextField("", text: $code)
            .keyboardType(.numberPad)
            .multilineTextAlignment(.center)
            .font(.system(size: 30, weight: .bold, design: .monospaced))
            .tracking(8)
            .foregroundStyle(Theme.ink)
            .focused($isFocused)
            .frame(maxWidth: .infinity)
            .padding(14)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isFocused ? Theme.accent : Theme.borderChrome, lineWidth: isFocused ? 1.5 : 1)
            )
            .onChange(of: code) { _, new in
                let sanitized = Self.sanitize(new)
                guard sanitized == new else { code = sanitized; return }   // 净化后的值再走一轮 onChange
                if sanitized.count == 7 {
                    fetchPreview(for: sanitized)
                } else {
                    previewTask?.cancel()
                    previewState = .idle
                }
            }
    }

    /// 粘贴含链接的整段文本 → 用 PromptLogic.extractShareCode 抠码；纯数字键盘敲出来的
    /// 输入直接过滤非数字字符 + 封顶 7 位（numberPad 本来打不出非数字，封顶只是保险）。
    private static func sanitize(_ raw: String) -> String {
        if !raw.allSatisfy(\.isNumber), let extracted = PromptLogic.extractShareCode(raw) {
            return extracted
        }
        return String(raw.filter(\.isNumber).prefix(7))
    }

    // MARK: - 预览卡 / 错误态（同一块「卡片位置」，三态共用同一个容器）

    @ViewBuilder private var previewSlot: some View {
        switch previewState {
        case .idle:
            EmptyView()
        case .loading:
            cardContainer {
                HStack { Spacer(); ProgressView().tint(Theme.accent); Spacer() }
                    .padding(.vertical, 10)
            }
        case .loaded(let preview):
            cardContainer { previewCard(preview) }
        case .notFound:
            cardContainer { errorText(String(localized: "这个魔法数字无效或已停止分享")) }
        case .error(let message):
            cardContainer { errorText(message) }
        }
    }

    private func cardContainer<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(15)
            .frame(maxWidth: .infinity)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.borderChrome, lineWidth: 1))
    }

    private func errorText(_ text: String) -> some View {
        Text(text).font(.system(size: 14)).foregroundStyle(Theme.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }

    private func previewCard(_ preview: SharePreview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            AppliesToBadges(appliesTo: preview.appliesTo)
            Text(preview.label).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.ink)
            Text(preview.prompt).font(.system(size: 13.5)).foregroundStyle(Color(hex: "5b5349"))
                .lineSpacing(6.5)
            if let source = sourceLine(preview) {
                Text(source).font(.system(size: 12)).foregroundStyle(Theme.faint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// author 空串 → 只显示「已被导入 N 次」；N==0 → 不显示次数那截；两者都空 → 整行不画。
    private func sourceLine(_ p: SharePreview) -> String? {
        let author = p.author.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasAuthor = !author.isEmpty
        let hasCount = p.importCount > 0
        switch (hasAuthor, hasCount) {
        case (false, false): return nil
        case (false, true):  return String(localized: "已被导入 \(p.importCount) 次")
        case (true, false):  return String(localized: "来自 \(author)")
        case (true, true):   return String(localized: "来自 \(author) · 已被导入 \(p.importCount) 次")
        }
    }

    // MARK: - 主按钮

    private var primaryButton: some View {
        Button {
            Task { await performImport() }
        } label: {
            Group {
                if importing {
                    ProgressView().tint(.white)
                } else {
                    Text("加入我的提示词").font(.system(size: 16, weight: .semibold)).foregroundStyle(.white)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
        }
        .background(canImport ? Theme.accent : Theme.faint, in: RoundedRectangle(cornerRadius: 12))
        .disabled(!canImport || importing)
    }

    private var canImport: Bool {
        if case .loaded = previewState { return true }
        return false
    }

    // MARK: - 脚注

    private var footnote: some View {
        Text("导入后是你自己的副本，可改名、改内容、随时删除；原作者之后的修改不影响你。")
            .font(.system(size: 12)).foregroundStyle(Theme.faint)
            .multilineTextAlignment(.center)
    }

    // MARK: - 网络

    /// 输够 7 位自动查预览。code 相等校验 + task 句柄双重把关：请求在途时用户继续编辑，
    /// 旧请求回来时 `code` 已经不等于发起时的 `requestCode`，直接丢弃——永远不会用过期
    /// 结果覆盖用户正在看的新输入。
    private func fetchPreview(for requestCode: String) {
        previewTask?.cancel()
        previewState = .loading
        previewTask = Task {
            let result = await PromptStore.shared.sharePreview(code: requestCode)
            guard !Task.isCancelled, code == requestCode else { return }
            previewState = result.map(PreviewState.loaded) ?? .notFound
        }
    }

    private func performImport() async {
        guard case .loaded = previewState, !importing else { return }
        importing = true
        defer { importing = false }
        let result = await PromptStore.shared.importPrompt(code: code)
        switch result {
        case .success(let node):
            onImported(node)
            dismiss()
        case .failure(let err):
            previewState = .error(err.message)
        }
    }
}
