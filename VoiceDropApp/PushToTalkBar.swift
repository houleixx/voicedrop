import SwiftUI
import Foundation

/// A transient one-line reply from the editing agent.
struct AgentReply: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let ok: Bool
}

/// The reusable feedback UI shared by every 语音指令 surface: the live-transcript
/// bubble, the agent's one-line reply, and the stacked queue of pending commands.
/// `PushToTalkBar` (article-level editing) and the library-wide red-button
/// walkie-talkie (`LibraryView.recordButton`) both render this — same bubbles,
/// same styling — so the two surfaces never drift apart visually.
struct VoiceFeedbackStack: View {
    /// Non-nil ⇒ show the dark live-transcript bubble ("在听…" when empty).
    let transcript: String?
    let reply: AgentReply?
    let queue: [ArticleAgentSession.EditRequest]
    /// 第N行/图N 染色，仅文章编辑（RecordingDetailView）开；库级指令没有行号语境，关掉。
    var highlightLocators: Bool = false

    var body: some View {
        let firstId = queue.first?.id
        VStack(spacing: 8) {
            if let reply { replyBubble(reply) }
            // Pending edits pile up here — newest on top, the one in flight sits
            // just above the button and drains first; each builds on the last.
            ForEach(queue.reversed()) { req in
                queueRow(req, inFlight: req.id == firstId)
            }
            if let transcript { darkBubble(transcript) }
        }
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

    /// The agent's one-line reply. Success: neutral light card. Error: muted-red
    /// border + warning glyph. It is NOT transient — it stays put until a newer
    /// reply replaces it or the caller clears `agentReply` (e.g. a tap elsewhere).
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

    /// Transcript text tinted the base off-white for the dark bubble. When
    /// `highlightLocators` is on (article editing), every 第N行 / 图N locator is
    /// additionally tinted accent (#F0B59B) so it's clear which line/image is
    /// meant; off (e.g. library-level commands with no line-number context), the
    /// text is returned plain with no locator tinting.
    private func highlightedTranscript(_ s: String) -> Text {
        var att = AttributedString(s)
        att.foregroundColor = Color(hex: "FBF6EE")
        guard highlightLocators else { return Text(att) }
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
}

/// 微信式「按住说话」条：常驻底部，按住录音、松开把指令交给 `session`。文章编辑
/// （`highlightLocators: true` + 当前 articleIndex）与未来的库级指令（默认值）共用
/// 同一份 UI/手势逻辑，只靠这几个参数区分两处耦合。
struct PushToTalkBar: View {
    let dictation: SpeechDictation
    let session: any VoiceAgentSession
    /// 第N行/图N 染色，仅文章编辑（RecordingDetailView）开；库级指令没有行号语境，关掉。
    var highlightLocators: Bool = false
    /// 文章编辑传当前篇 index；库级传 0（协议 enqueue 需要一个值，库级不使用它）。
    var articleIndex: () -> Int = { 0 }
    /// 悬浮在 bar 上方的一次性回复气泡；由调用方持有其生命周期（何时清除，例如「点击正文空白处」）。
    var agentReply: AgentReply? = nil
    /// 松开发送、真正 enqueue 之前触发的钩子（预留给未来库级场景，如发送前刷新态）。
    var onWillSend: (() -> Void)? = nil

    // 上滑取消的手势态，完全是这条 bar 自己的 UI 细节，不需要外部知道。
    @State private var willCancel = false

    var body: some View {
        let recording = dictation.isRecording
        let working = session.state == .working
        return VStack(spacing: 8) {
            // Only mount the feedback stack when it has something to show, so the
            // idle bar keeps its old zero-gap look (an always-present empty stack
            // would leave the VStack's 8pt spacing above the pill).
            if recording || agentReply != nil || !session.queue.isEmpty {
                VoiceFeedbackStack(transcript: recording ? dictation.transcript : nil,
                                   reply: agentReply, queue: session.queue, highlightLocators: highlightLocators)
            }
            pill(recording: recording, working: working)
                .shadow(color: .black.opacity(0.10), radius: 12, x: 0, y: 5)   // float over the body
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.22), value: session.queue)
        .animation(.easeInOut(duration: 0.18), value: recording)
        .animation(.easeInOut(duration: 0.22), value: agentReply)
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
                    guard !text.isEmpty else { return }
                    onWillSend?()
                    session.enqueue(text, images: [], articleIndex: articleIndex())
                }
            }
    }
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
