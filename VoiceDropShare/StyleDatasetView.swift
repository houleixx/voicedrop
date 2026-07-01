import SwiftUI

// The 风格数据集 sheet — the Share Extension's landing page for **web / document /
// text** shares (audio & image route to `AudioComposeView`/`PhotoComposeView`
// instead). Shows the already-collected 写作风格 corpus (`ShareAPI.fetchDataset`),
// then turns THIS share's `payload` into one or more "本次新增" rows, collecting
// each straight away (`ShareAPI.collectStyle`). A web link gets a 三态 row
// (解析中 → 已收录 / 解析失败，可重试) since it needs a network fetch
// (`Readability.fetch`) before it has any text to collect. Footer lets the user
// either keep sharing (「继续收集」→ just `close()`, the corpus already has the
// new items) or run extraction now (「提取文章风格」→ `ShareAPI.extractStyle`).
struct StyleDatasetView: View {
    let payload: SharePayload
    let close: () -> Void
    /// Called after 提取文章风格 succeeds — opens the host app to 我的录音, where the
    /// 写作风格介绍 article appears once the (async) distill finishes.
    var openApp: () -> Void = {}

    @State private var existing: [DatasetItem] = []
    @State private var newItems: [NewItem] = []
    /// Per-item retry closures, keyed by `NewItem.id`. Kept OUT of `NewItem`
    /// itself (which stays a plain value struct held in @State) so the retry
    /// logic — which needs to recompute from the original text/URL — lives in
    /// one place per item without complicating the row model.
    @State private var retryActions: [UUID: () async -> Void] = [:]
    @State private var clearAfter = true
    @State private var extracting = false
    @State private var extractFailed = false

    private var collectedCount: Int {
        existing.count + newItems.filter { $0.state == .done }.count
    }
    private var collectedChars: Int {
        existing.reduce(0) { $0 + $1.chars } + newItems.filter { $0.state == .done }.reduce(0) { $0 + $1.chars }
    }

    var body: some View {
        VStack(spacing: 0) {
            grabber
            header
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(existing) { ExistingRow(item: $0) }
                    if !newItems.isEmpty {
                        newSectionHeader
                        ForEach(newItems) { item in
                            NewItemRow(item: item, onRetry: {
                                guard let action = retryActions[item.id] else { return }
                                Task { await action() }
                            })
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 2)
                .padding(.bottom, 8)
            }
            footer
        }
        .frame(maxWidth: .infinity)
        .frame(maxHeight: UIScreen.main.bounds.height * 0.85)
        .background(ShareTheme.sheetBG)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 18, style: .continuous))
        .shadow(color: Color(hex: "3C301E").opacity(0.16), radius: 20, x: 0, y: -6)
        .ignoresSafeArea(edges: .bottom)
        .task { await load() }
    }

    // MARK: - Header / grabber

    private var grabber: some View {
        Capsule()
            .fill(Color(hex: "DDD3C2"))
            .frame(width: 38, height: 5)
            .padding(.top, 10)
            .padding(.bottom, 2)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("风格数据集")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(ShareTheme.ink)
                Text("已收集 \(collectedCount) 项 · \(formatTotalChars(collectedChars))")
                    .font(.system(size: 13))
                    .foregroundStyle(ShareTheme.secondary)
            }
            Spacer(minLength: 0)
            Button(action: close) {
                Text("关闭")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(ShareTheme.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 12)
    }

    private var newSectionHeader: some View {
        HStack(spacing: 8) {
            Text("本次新增")
                .font(.system(size: 11, weight: .bold))
                .tracking(2)
                .foregroundStyle(Color(hex: "C0682E"))
            LinearGradient(colors: [Color(hex: "E8C9B8"), Color(hex: "E8C9B8").opacity(0)], startPoint: .leading, endPoint: .trailing)
                .frame(height: 1)
        }
        .padding(.top, 16)
        .padding(.bottom, 6)
        .padding(.horizontal, 4)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 0) {
            Button(action: { clearAfter.toggle() }) {
                HStack(spacing: 9) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(clearAfter ? Color(hex: "D8593B") : Color.white)
                        .frame(width: 20, height: 20)
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(clearAfter ? Color.clear : Color(hex: "E2D8C8"), lineWidth: 1))
                        .overlay {
                            if clearAfter {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                        }
                    Text("提取后清空数据集")
                        .font(.system(size: 13.5))
                        .foregroundStyle(Color(hex: "6B6357"))
                    Spacer(minLength: 0)
                    Text("下次从零开始")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(hex: "a79f93"))
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 4)
            .padding(.bottom, 12)

            if extractFailed {
                Text("提取失败，请稍后重试")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color(hex: "C0682E"))
                    .padding(.bottom, 8)
            }

            HStack(spacing: 10) {
                Button(action: close) {
                    Text("继续收集")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color(hex: "2A2521"))
                        .padding(.horizontal, 20)
                        .frame(height: 50)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color(hex: "E2D8C8"), lineWidth: 1))
                }
                .buttonStyle(.plain)

                Button(action: { extractFailed = false; Task { await extract() } }) {
                    HStack(spacing: 8) {
                        if extracting {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: "square.and.arrow.down")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        Text("提取文章风格")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(hex: "D8593B")))
                    .shadow(color: Color(hex: "D8593B").opacity(0.28), radius: 10, x: 0, y: 4)
                }
                .buttonStyle(.plain)
                .disabled(collectedCount == 0 || extracting)
                .opacity((collectedCount == 0 || extracting) ? 0.6 : 1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 30)
        .background(ShareTheme.sheetBG)
        .overlay(alignment: .top) { Rectangle().fill(Color(hex: "EFE7D9")).frame(height: 1) }
    }

    // MARK: - Loading / collecting

    /// Runs once on appear: pull the already-collected corpus, then fold this
    /// share's payload into 本次新增 rows (each collected as soon as its text is
    /// ready). All three payload fields are handled independently — a share can
    /// legitimately carry more than one (e.g. Safari hands over both a URL and a
    /// short text/title attachment).
    private func load() async {
        existing = await ShareAPI.fetchDataset()
        if let text = payload.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            await collectText(text)
        }
        for doc in payload.docs {
            await collectDoc(doc)
        }
        if let webURL = payload.webURL {
            await collectWeb(webURL)
        }
    }

    private func mutate(_ id: UUID, _ change: (inout NewItem) -> Void) {
        guard let i = newItems.firstIndex(where: { $0.id == id }) else { return }
        change(&newItems[i])
    }

    private func collectText(_ raw: String) async {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = firstLineTitle(text, fallback: "分享的文字")
        let item = NewItem(iconKind: .text, typeLabel: "文字", title: "正在保存…", meta: formatChars(text.count), state: .parsing, chars: text.count)
        newItems.append(item)
        let id = item.id
        let attempt: () async -> Void = { await self.saveText(id: id, title: title, text: text) }
        retryActions[id] = attempt
        await attempt()
    }

    private func saveText(id: UUID, title: String, text: String) async {
        mutate(id) { $0.state = .parsing; $0.title = "正在保存…" }
        let ok = await ShareAPI.collectStyle(type: "text", title: title, text: text, source: "分享文本")
        mutate(id) {
            if ok { $0.state = .done; $0.title = title } else { $0.state = .failed; $0.title = "保存失败 · 可重试" }
        }
    }

    private func collectDoc(_ url: URL) async {
        let filename = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        // PDFKit's `.string` and `NSAttributedString(url:)` (docx/rtf) are safe off-main
        // (not HTML), but a large file can take real time/memory — run detached so parsing
        // never blocks the main actor (the sheet would otherwise freeze: no spinner, no
        // taps, and Share Extensions have tight watchdogs).
        let extracted = await Task.detached(priority: .userInitiated) { () -> String? in
            ext == "pdf" ? extractPDF(url) : extractRichDocument(url)
        }.value
        guard let text = extracted?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            // Nothing to retry — the local extraction itself produced no text
            // (unsupported/corrupt file), a fresh attempt would fail the same way.
            newItems.append(NewItem(iconKind: .doc, typeLabel: "文档", title: "无法读取内容", meta: filename, state: .failed, chars: 0, canRetry: false))
            return
        }
        let title = firstLineTitle(text, fallback: filename)
        let item = NewItem(iconKind: .doc, typeLabel: "文档", title: "正在保存…", meta: formatChars(text.count), state: .parsing, chars: text.count)
        newItems.append(item)
        let id = item.id
        let attempt: () async -> Void = { await self.saveDoc(id: id, title: title, text: text, source: filename) }
        retryActions[id] = attempt
        await attempt()
    }

    private func saveDoc(id: UUID, title: String, text: String, source: String) async {
        mutate(id) { $0.state = .parsing; $0.title = "正在保存…" }
        let ok = await ShareAPI.collectStyle(type: "doc", title: title, text: text, source: source)
        mutate(id) {
            if ok { $0.state = .done; $0.title = title } else { $0.state = .failed; $0.title = "保存失败 · 可重试" }
        }
    }

    private func collectWeb(_ url: URL) async {
        let host = url.host ?? url.absoluteString
        let item = NewItem(iconKind: .web, typeLabel: "网页", title: "正在解析网页…", meta: host, state: .parsing, chars: 0)
        newItems.append(item)
        let id = item.id
        let attempt: () async -> Void = { await self.fetchAndSaveWeb(id: id, url: url) }
        retryActions[id] = attempt
        await attempt()
    }

    private func fetchAndSaveWeb(id: UUID, url: URL) async {
        let host = url.host ?? url.absoluteString
        mutate(id) { $0.state = .parsing; $0.title = "正在解析网页…"; $0.meta = host }
        // `Readability.fetch` collapses "no article body" into nil (see its own
        // doc comment); ShareAPI's `collectStyle` collapses any failure into
        // `false` with no reason either. Both funnel into the same 「解析失败 ·
        // 仅存链接」 failed state below — the user always gets a clear retry
        // path, never a false success.
        guard let fetched = await Readability.fetch(url) else {
            mutate(id) { $0.state = .failed; $0.title = "解析失败 · 仅存链接"; $0.meta = truncatedLink(url) }
            return
        }
        let title = fetched.title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? fetched.title! : host
        let ok = await ShareAPI.collectStyle(type: "web", title: title, text: fetched.text, source: host)
        if ok {
            mutate(id) { $0.state = .done; $0.title = title; $0.meta = host; $0.chars = fetched.text.count }
        } else {
            mutate(id) { $0.state = .failed; $0.title = "解析失败 · 仅存链接"; $0.meta = truncatedLink(url) }
        }
    }

    private func extract() async {
        guard collectedCount > 0, !extracting else { return }
        extracting = true
        let ok = await ShareAPI.extractStyle(clearAfter: clearAfter)
        extracting = false
        if ok { openApp() } else { extractFailed = true }   // 成功 → 跳「我的录音」看进度
    }
}

// MARK: - Row model

private enum RowState { case parsing, done, failed }

private enum IconKind {
    case doc, web, text
    var apiType: String {
        switch self {
        case .doc: return "doc"
        case .web: return "web"
        case .text: return "text"
        }
    }
}

/// One row under 「本次新增」— built from `payload` and collected right away.
private struct NewItem: Identifiable {
    let id = UUID()
    var iconKind: IconKind
    var typeLabel: String
    var title: String
    var meta: String
    var state: RowState = .parsing
    var chars: Int = 0
    /// `false` only for a doc whose LOCAL extraction produced no text — retrying
    /// would read the same bytes and fail identically, so no retry button.
    var canRetry: Bool = true
    var apiType: String { iconKind.apiType }
}

// MARK: - Rows

private struct ExistingRow: View {
    let item: DatasetItem

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            IconBadge(type: item.type)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 15))
                    .foregroundStyle(Color(hex: "2A2521"))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Color(hex: "a79f93"))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 13)
        .padding(.horizontal, 4)
        .overlay(alignment: .bottom) { Rectangle().fill(Color(hex: "EFE7D9")).frame(height: 1) }
    }

    private var subtitle: String {
        let label = chineseTypeLabel(item.type)
        let meta = (item.type == "doc" || item.type == "text") ? formatChars(item.chars) : item.source
        let date = chineseDate(item.collectedAt)
        return [label, meta, date].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

private struct NewItemRow: View {
    let item: NewItem
    let onRetry: () -> Void

    var body: some View {
        switch item.state {
        case .parsing: parsingBody
        case .done: doneBody
        case .failed: failedBody
        }
    }

    private var parsingBody: some View {
        HStack(spacing: 12) {
            IconBadge(type: item.apiType)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 15))
                    .foregroundStyle(Color(hex: "6B6357"))
                    .lineLimit(1)
                Text("\(item.typeLabel) · \(item.meta)")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(hex: "a79f93"))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            SpinnerView()
        }
        .rowChrome(fill: Color(hex: "F6F1E8"), stroke: Color(hex: "E8DFD0"))
    }

    private var doneBody: some View {
        HStack(spacing: 12) {
            IconBadge(type: item.apiType, highlighted: true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color(hex: "9A4A30"))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("\(item.typeLabel) · \(item.meta) · 刚刚")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(hex: "C08A6E"))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            Image(systemName: "checkmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color(hex: "D8593B"))
        }
        .rowChrome(fill: Color(hex: "FBF1E9"), stroke: Color(hex: "E8C9B8"))
    }

    private var failedBody: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(hex: "F1EBE2"))
                .frame(width: 38, height: 38)
                .overlay(
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 16))
                        .foregroundStyle(Color(hex: "B0A798"))
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 15))
                    .foregroundStyle(Color(hex: "8A8175"))
                    .lineLimit(1)
                Text("\(item.typeLabel) · \(item.meta)")
                    .font(.system(size: 12))
                    .foregroundStyle(Color(hex: "B0A798"))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            if item.canRetry {
                Button(action: onRetry) {
                    Text("重试")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(hex: "C0682E"))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color(hex: "E8C9B8"), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
        .rowChrome(fill: Color.white, stroke: Color(hex: "E8DFD0"))
    }
}

private extension View {
    /// The shared 「本次新增」row card chrome — padding, rounded background, border, top gap.
    func rowChrome(fill: Color, stroke: Color) -> some View {
        self
            .padding(.vertical, 13)
            .padding(.horizontal, 12)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(stroke, lineWidth: 1))
            .padding(.top, 8)
    }
}

private struct IconBadge: View {
    let type: String
    var highlighted: Bool = false

    var body: some View {
        let c = iconColors(type)
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(highlighted ? Color(hex: "F3DDCB") : c.bg)
            .frame(width: 38, height: 38)
            .overlay(
                Image(systemName: c.symbol)
                    .font(.system(size: 16))
                    .foregroundStyle(highlighted ? Color(hex: "C0682E") : c.stroke)
            )
    }
}

/// The rotating URL-parsing spinner — mirrors the design's CSS `sc-spin`
/// keyframe (a circle with only its top arc colored, spinning continuously).
private struct SpinnerView: View {
    @State private var spin = false

    var body: some View {
        ZStack {
            Circle().stroke(Color(hex: "E0D6C6"), lineWidth: 2)
            Circle()
                .trim(from: 0, to: 0.25)
                .stroke(Color(hex: "C98A2E"), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(spin ? 360 : 0))
        }
        .frame(width: 18, height: 18)
        .onAppear {
            withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) { spin = true }
        }
    }
}

// MARK: - Formatting helpers

private func formatChars(_ n: Int) -> String {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.locale = Locale(identifier: "en_US_POSIX")
    let s = f.string(from: NSNumber(value: n)) ?? "\(n)"
    return "\(s) 字"
}

private func formatTotalChars(_ n: Int) -> String {
    if n >= 10_000 {
        return String(format: "约 %.1f 万字", Double(n) / 10_000)
    }
    return "约 \(n) 字"
}

private func chineseTypeLabel(_ type: String) -> String {
    switch type {
    case "doc": return "文档"
    case "web": return "网页"
    case "text": return "文字"
    case "image": return "图片"
    case "audio": return "音频"
    default: return type
    }
}

private func chineseDate(_ iso: String) -> String {
    guard !iso.isEmpty else { return "" }
    var date: Date?
    let iso8601 = ISO8601DateFormatter()
    iso8601.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    date = iso8601.date(from: iso)
    if date == nil {
        iso8601.formatOptions = [.withInternetDateTime]
        date = iso8601.date(from: iso)
    }
    guard let resolved = date else { return "" }
    let out = DateFormatter()
    out.locale = Locale(identifier: "zh_CN")
    out.dateFormat = "M月d日"
    return out.string(from: resolved)
}

/// A short "host + path" preview for a failed-to-parse link, truncated with an
/// ellipsis (matches the design's "zhihu.com/question/6620…").
private func truncatedLink(_ url: URL, max: Int = 24) -> String {
    let host = url.host ?? ""
    let rest = url.path + (url.query.map { "?\($0)" } ?? "")
    let full = host + rest
    guard full.count > max else { return full }
    let idx = full.index(full.startIndex, offsetBy: max)
    return String(full[..<idx]) + "…"
}

private func iconColors(_ type: String) -> (bg: Color, stroke: Color, symbol: String) {
    switch type {
    case "web": return (Color(hex: "E4EBE6"), Color(hex: "5E8A6A"), "globe")
    case "image": return (Color(hex: "F0E6E2"), Color(hex: "B07A5E"), "photo")
    case "audio": return (Color(hex: "E8E4EF"), Color(hex: "7A6EA0"), "waveform")
    case "text": return (Color(hex: "EDE6D8"), Color(hex: "7A6E5C"), "text.alignleft")
    default: return (Color(hex: "EDE6D8"), Color(hex: "7A6E5C"), "doc.text") // "doc"
    }
}
