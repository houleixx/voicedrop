import SwiftUI
import Observation

// 追问（follow-up questions）：成文后 AI 针对文章最薄处追问 1–3 题，用户按住说话
// 回答，回答被 edit agent 织进正文对应段落。设计稿 design_handoff_follow_up_questions
// 第 3 轮定稿：3a 底部逐题卡片 / 3b 说话条星标收起态 / 3c 回答后确认 + 正文荧光高亮。
// 问题本体是服务端 doc 顶层 sidecar（ArticleDoc.questions），不进正文、不进版本。

/// 追问的页面状态机。视图注入两个钩子：`patch`（状态回写服务器，fire-and-forget）
/// 与 `onHighlight`（正文第N行荧光高亮）。回答的织入走现有 edit WebSocket——
/// 视图 enqueue 指令，`handleUpdated` 在 onUpdate 里收尾（diff → 确认 → 翻题）。
@MainActor
@Observable
final class FollowupState {
    enum Sheet { case expanded, collapsed, dismissed }

    private(set) var all: [FollowupQuestion] = []
    var sheet: Sheet = .dismissed
    var currentId: String?
    var confirmText: String?          // 3c 绿色确认行（「第 1 题已回答 · 补进了第 2 段」）
    var failureText: String?          // 「没听清，再试一次」
    var answering = false             // 提交后等 onUpdate 期间（按钮 spinner）

    struct Pending { let id: String; let ordinal: Int; let articleIndex: Int; let oldBody: String }
    private(set) var pending: Pending?

    var patch: ((String, String) -> Void)?     // (questionId, status) → PATCH
    var onHighlight: ((Int) -> Void)?          // 织入段落的第N行 → 正文高亮

    private static let maxAgeMs: Double = 7 * 24 * 3600 * 1000   // 7 天未答自动消失

    /// doc 加载/重挖后同步。追问只属于当前这版：过期的丢掉；有未答题就自动升起
    /// （设计①「成文后自动升起」——进入成文页即卡片升起，一滑即收）。
    func load(_ doc: ArticleDoc?) {
        let now = Date().timeIntervalSince1970 * 1000
        all = (doc?.questions ?? []).filter { q in
            guard let t = q.createdAt else { return true }
            return now - t < Self.maxAgeMs
        }
        confirmText = nil; failureText = nil; answering = false; pending = nil
        currentId = all.first { $0.status == "pending" }?.id
        sheet = all.contains { $0.status == "pending" } ? .expanded : .dismissed
    }

    // ── 每篇文章各自的题组 ─────────────────────────────────────────────────────
    func questions(for articleIndex: Int) -> [FollowupQuestion] {
        all.filter { ($0.articleIndex ?? 0) == articleIndex }
    }
    func pendingCount(for articleIndex: Int) -> Int {
        questions(for: articleIndex).filter { $0.status == "pending" }.count
    }
    func current(for articleIndex: Int) -> FollowupQuestion? {
        let qs = questions(for: articleIndex)
        if let id = currentId, let q = qs.first(where: { $0.id == id && $0.status == "pending" }) { return q }
        return qs.first { $0.status == "pending" }
    }
    /// 「追问 N/M」的 N（当前题在本篇题组里的序号，1-based）。
    func ordinal(of q: FollowupQuestion, in articleIndex: Int) -> Int {
        (questions(for: articleIndex).firstIndex { $0.id == q.id } ?? 0) + 1
    }

    // ── 动作 ──────────────────────────────────────────────────────────────────
    /// 跳过当前题：进度段保持灰色，翻下一题；没有下一题就收卡片。
    func skip(articleIndex: Int) {
        guard let q = current(for: articleIndex) else { return }
        setStatus(q.id, "skipped")
        confirmText = nil; failureText = nil
        advance(articleIndex: articleIndex)
    }

    /// 松开提交口述回答：记住旧正文供 diff，等 onUpdate 收尾。
    func beginAnswer(_ q: FollowupQuestion, articleIndex: Int, oldBody: String) {
        pending = Pending(id: q.id, ordinal: ordinal(of: q, in: articleIndex), articleIndex: articleIndex, oldBody: oldBody)
        answering = true
        confirmText = nil; failureText = nil
    }

    /// edit agent 回写成功（onUpdate）：diff 出被补写的段落 → 确认行 + 正文高亮，
    /// 状态回写 answered，翻下一题；全部答完/跳完 → 短暂停留后收卡片。
    func handleUpdated(_ doc: ArticleDoc?) {
        guard let p = pending, let doc else { return }
        pending = nil; answering = false
        let arts = doc.resolvedArticles
        let newBody = (p.articleIndex >= 0 && p.articleIndex < arts.count) ? arts[p.articleIndex].body : ""
        setStatus(p.id, "answered")
        if let hit = Self.firstChangedRow(old: p.oldBody, new: newBody) {
            confirmText = "第 \(p.ordinal) 题已回答 · 补进了第 \(hit.paragraph) 段"
            onHighlight?(hit.line)
        } else {
            confirmText = "第 \(p.ordinal) 题已回答"
        }
        advance(articleIndex: p.articleIndex)
    }

    /// 织入失败（error / reply ok=false）：红字提示，题不翻页。
    func handleFailure() {
        guard pending != nil || answering else { return }
        pending = nil; answering = false
        failureText = "没听清，再试一次"
    }

    private func setStatus(_ id: String, _ status: String) {
        guard let i = all.firstIndex(where: { $0.id == id }) else { return }
        all[i].status = status
        patch?(id, status)
    }

    private func advance(articleIndex: Int) {
        if let next = questions(for: articleIndex).first(where: { $0.status == "pending" }) {
            currentId = next.id
            return
        }
        currentId = nil
        // 全部答完或全部跳过 → 星标移除；留 1.6s 给确认行，然后收起整张卡。
        let hadConfirm = confirmText != nil
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: hadConfirm ? 1_600_000_000 : 200_000_000)
            withAnimation(.easeInOut(duration: 0.25)) { self.sheet = .dismissed }
        }
    }

    // ── diff：找口述回答被织进了哪一段 ─────────────────────────────────────────
    /// 行 = 正文按真实换行拆出的非空行（照片标记也占行号，与成文页第N行一致）；
    /// 段 = 其中的文字行序号（「补进了第 2 段」）。返回第一处不同的行。
    static func firstChangedRow(old: String, new: String) -> (line: Int, paragraph: Int)? {
        func rows(_ s: String) -> [String] {
            s.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        let a = rows(old), b = rows(new)
        func isPhoto(_ s: String) -> Bool { s.hasPrefix("[[photo:") && s.hasSuffix("]]") }
        for i in 0..<b.count {
            if i >= a.count || a[i] != b[i] {
                let paragraph = b[0...i].filter { !isPhoto($0) }.count
                return (line: i + 1, paragraph: max(paragraph, 1))
            }
        }
        return nil
    }
}

// ── 3a：底部逐题卡片 ────────────────────────────────────────────────────────────

struct FollowupCard: View {
    let state: FollowupState
    let articleIndex: Int
    let dictation: SpeechDictation
    let onSubmit: (FollowupQuestion, String) -> Void
    let onCollapse: () -> Void

    @State private var willCancel = false
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        let qs = state.questions(for: articleIndex)
        let q = state.current(for: articleIndex)
        VStack(alignment: .leading, spacing: 0) {
            // 拖动把手（36×4，下滑 = 收起）
            RoundedRectangle(cornerRadius: 2).fill(Theme.fuHandle)
                .frame(width: 36, height: 4)
                .frame(maxWidth: .infinity)

            if let confirm = state.confirmText {
                confirmRow(confirm).padding(.top, 10)
            }
            if let failure = state.failureText {
                failureRow(failure).padding(.top, 10)
            }

            if let q {
                HStack {
                    Text("追问 \(state.ordinal(of: q, in: articleIndex))/\(qs.count)")
                        .font(.system(size: 12, weight: .bold)).kerning(1.5)
                        .foregroundStyle(Theme.fuAmber)
                    Spacer()
                    Button { state.skip(articleIndex: articleIndex) } label: {
                        Text("跳过").font(.system(size: 13)).foregroundStyle(Theme.metaRead)
                            .padding(.vertical, 2).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(state.answering)
                }
                .padding(.top, state.confirmText == nil && state.failureText == nil ? 8 : 10)

                Text(q.text)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.inkRead)
                    .lineSpacing(10)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 10)

                answerButton(q).padding(.top, 12)

                progressBar(qs).padding(.top, 12).frame(maxWidth: .infinity)
            }
        }
        .padding(EdgeInsets(top: 14, leading: 18, bottom: 16, trailing: 18))
        .background(Theme.fuCardBG, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.fuBorder, lineWidth: 1))
        .shadow(color: Color(.sRGB, red: 60/255, green: 48/255, blue: 30/255, opacity: 0.14), radius: 15, x: 0, y: 10)
        .padding(.horizontal, 12)
        .offset(y: max(dragOffset, 0))
        .gesture(
            DragGesture()
                .onChanged { v in dragOffset = v.translation.height }
                .onEnded { v in
                    if v.translation.height > 40 { dragOffset = 0; onCollapse() }
                    else { withAnimation(.spring(duration: 0.3)) { dragOffset = 0 } }
                }
        )
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    /// 3c 确认行：绿勾 + 「第 1 题已回答 · 补进了第 2 段」。
    private func confirmRow(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark")
                .font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.fuGreen)
            Text(text).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.fuGreen)
        }
    }

    private func failureRow(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(Color(hex: "C0392B"))
            Text(text).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color(hex: "C0392B"))
        }
    }

    /// 「按住 说话 回答」：与主说话条同交互（按住录音、松开提交、上滑取消）。
    /// 录音中显示实时转写；提交后 spinner + 「正在补进文章…」。
    private func answerButton(_ q: FollowupQuestion) -> some View {
        let recording = dictation.isRecording
        return VStack(spacing: 8) {
            if recording && !dictation.transcript.isEmpty {
                Text(dictation.transcript)
                    .font(.system(size: 14)).foregroundStyle(Theme.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(3)
            }
            HStack(spacing: 8) {
                if state.answering {
                    ProgressView().tint(Theme.secondary).scaleEffect(0.8)
                    Text("正在补进文章…").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.secondary)
                } else if recording {
                    Text(willCancel ? "上滑取消 · 松开放弃" : "松开 提交 · 上滑取消")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.accent)
                } else {
                    Image(systemName: "mic")
                        .font(.system(size: 17)).foregroundStyle(Theme.secondary)
                    Text("按住 说话 回答").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.borderRead, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .gesture(holdGesture(q))
        }
        .animation(.easeInOut(duration: 0.15), value: recording)
    }

    private func holdGesture(_ q: FollowupQuestion) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                guard !state.answering, dictation.authorized == true else { return }
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
                    guard !text.isEmpty else { return }
                    onSubmit(q, text)
                }
            }
    }

    /// 分段进度条：每题一段 16×4；绿=已答，橙=当前，灰=未答/跳过。
    private func progressBar(_ qs: [FollowupQuestion]) -> some View {
        HStack(spacing: 5) {
            ForEach(qs) { q in
                RoundedRectangle(cornerRadius: 2)
                    .fill(q.status == "answered" ? Theme.fuGreen
                          : (q.id == state.current(for: articleIndex)?.id ? Theme.accent : Theme.fuBorder))
                    .frame(width: 16, height: 4)
            }
        }
    }
}

// ── 3b：说话条右端的星标按钮（收起态）──────────────────────────────────────────

struct FollowupStarButton: View {
    let remaining: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.white)
                RoundedRectangle(cornerRadius: 8).stroke(Theme.fuStarBorder, lineWidth: 1)
                FourPointStar()
                    .stroke(Theme.fuStarStroke, style: StrokeStyle(lineWidth: 1.8, lineJoin: .round))
                    .frame(width: 20, height: 20)
            }
            .frame(width: 52, height: 52)
            .overlay(alignment: .topTrailing) {
                if remaining > 0 {
                    Text("\(remaining)")
                        .font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(Theme.accent, in: Capsule())
                        .offset(x: 6, y: -6)
                }
            }
        }
        .buttonStyle(.plain)
        .shadow(color: .black.opacity(0.10), radius: 12, x: 0, y: 5)
    }
}

/// 四角星（sparkle 形）：四段二次贝塞尔往中心收腰。
struct FourPointStar: Shape {
    func path(in r: CGRect) -> Path {
        let c = CGPoint(x: r.midX, y: r.midY)
        let top = CGPoint(x: r.midX, y: r.minY)
        let right = CGPoint(x: r.maxX, y: r.midY)
        let bottom = CGPoint(x: r.midX, y: r.maxY)
        let left = CGPoint(x: r.minX, y: r.midY)
        var p = Path()
        p.move(to: top)
        p.addQuadCurve(to: right, control: c)
        p.addQuadCurve(to: bottom, control: c)
        p.addQuadCurve(to: left, control: c)
        p.addQuadCurve(to: top, control: c)
        p.closeSubpath()
        return p
    }
}
