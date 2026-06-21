import SwiftUI
import Observation

/// Per-user writing identity, stored on the server as users/<sub>/CLAUDE.md and
/// appended to the article-mining prompt. Single source of truth = that one file.
@MainActor
@Observable
final class SettingsStore {
    var name = ""
    var style = ""
    var loading = false
    var saving = false
    var saved = false
    var error: String?
    var mining = false
    var mineMsg: String?

    private let base = URL(string: "https://jianshuo.dev/files/api")!
    private var token: String { AuthStore.shared.bearer }

    /// CLAUDE.md format — 文风 is the last, greedy section so markdown headings
    /// inside the style text can't break the round-trip.
    func compose() -> String {
        "# 我的名字\n\(name.trimmingCharacters(in: .whitespacesAndNewlines))\n\n# 我的文风\n\(style.trimmingCharacters(in: .whitespacesAndNewlines))\n"
    }

    static func parse(_ md: String) -> (name: String, style: String) {
        guard let s = md.range(of: "# 我的文风") else {
            return ("", md.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let style = String(md[s.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        var name = ""
        let before = String(md[..<s.lowerBound])
        if let n = before.range(of: "# 我的名字") {
            name = String(before[n.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (name, style)
    }

    func load() async {
        guard !token.isEmpty else { error = "请先登录"; return }
        loading = true; error = nil
        defer { loading = false }
        var req = URLRequest(url: base.appending(path: "download").appending(path: "CLAUDE.md"))
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 404 { return }                  // no settings yet — empty fields
            guard (200..<300).contains(code) else { error = "加载失败"; return }
            let parsed = Self.parse(String(decoding: data, as: UTF8.self))
            name = parsed.name; style = parsed.style
        } catch { self.error = error.localizedDescription }
    }

    func save() async {
        guard !token.isEmpty else { error = "请先登录"; return }
        saving = true; saved = false; error = nil
        defer { saving = false }
        var req = URLRequest(url: base.appending(path: "upload").appending(path: "CLAUDE.md"))
        req.httpMethod = "PUT"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("text/markdown; charset=utf-8", forHTTPHeaderField: "Content-Type")
        do {
            let (_, resp) = try await URLSession.shared.upload(for: req, from: Data(compose().utf8))
            guard (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true else {
                error = "保存失败"; return
            }
            saved = true
        } catch { self.error = error.localizedDescription }
    }

    /// Kick the server article-miner now instead of waiting for the hourly cron.
    func triggerMine() async {
        guard !token.isEmpty else { mineMsg = "请先登录"; return }
        mining = true; mineMsg = nil
        defer { mining = false }
        var req = URLRequest(url: base.appending(path: "mine"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            mineMsg = (200..<300).contains(code) ? "已触发，过一会儿回「文章」看" : "触发失败（\(code)）"
        } catch { mineMsg = error.localizedDescription }
    }
}

struct SettingsView: View {
    var active: Bool = true
    @State private var store = SettingsStore()
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    field(title: "名字") {
                        TextField("你的名字", text: $store.name)
                            .textFieldStyle(.plain)
                            .foregroundStyle(.white)
                            .padding(12)
                            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                    }
                    field(title: "文风") {
                        VStack(alignment: .leading, spacing: 6) {
                            TextEditor(text: $store.style)
                                .focused($focused)
                                .foregroundStyle(.white)
                                .scrollContentBackground(.hidden)
                                .frame(height: 200)        // fixed box; long text scrolls inside, never grows the page
                                .padding(8)
                                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                            Text("把蒸馏出来的文风文本贴进来。服务器挖文章时会带上它，让文章更像你。")
                                .font(.caption).foregroundStyle(.white.opacity(0.4))
                        }
                    }
                    Button {
                        focused = false
                        Task { await store.save() }
                    } label: {
                        HStack {
                            if store.saving { ProgressView().tint(.black) }
                            Text(store.saved ? "已保存 ✓" : "保存").bold()
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(.white, in: RoundedRectangle(cornerRadius: 12))
                        .foregroundStyle(.black)
                    }
                    .disabled(store.saving)
                    if let e = store.error {
                        Text(e).font(.footnote).foregroundStyle(.orange)
                    }

                    Divider().overlay(Color.white.opacity(0.08)).padding(.vertical, 6)

                    field(title: "加急处理") {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("不等每小时的自动处理，现在就让服务器立刻挖一遍新录音。")
                                .font(.caption).foregroundStyle(.white.opacity(0.4))
                            Button {
                                Task { await store.triggerMine() }
                            } label: {
                                HStack(spacing: 8) {
                                    if store.mining { ProgressView().tint(.white) }
                                    else { Image(systemName: "bolt.fill") }
                                    Text("立即处理")
                                }
                                .frame(maxWidth: .infinity).padding(.vertical, 12)
                                .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                                .foregroundStyle(.white)
                            }
                            .disabled(store.mining)
                            if let m = store.mineMsg {
                                Text(m).font(.footnote).foregroundStyle(.white.opacity(0.6))
                            }
                        }
                    }

                    Divider().overlay(Color.white.opacity(0.08)).padding(.vertical, 6)

                    TokenSection()
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)   // swipe down to put the keyboard away
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                // A 完成 button above the keyboard — the reliable way to dismiss it
                // and get back to the tab bar after editing 文风.
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { focused = false }
                }
            }
            .onChange(of: store.name) { _, _ in store.saved = false }
            .onChange(of: store.style) { _, _ in store.saved = false }
        }
        .preferredColorScheme(.dark)
        .task { await store.load() }
        .onChange(of: active) { _, now in if now { Task { await store.load() } } }
    }

    private func field<Content: View>(title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline).foregroundStyle(.white.opacity(0.85))
            content()
        }
    }
}

/// Shows the current bearer token so users can paste it into Claude Code's
/// /voicedrop skill (or any other API client).
private struct TokenSection: View {
    @State private var auth = AuthStore.shared
    @State private var copied = false

    private var token: String { auth.bearer }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("访问令牌").font(.headline).foregroundStyle(.white.opacity(0.85))
            Text("把下面的令牌交给 Claude Code，就可以通过 /voicedrop 命令访问你的录音和文章。")
                .font(.caption).foregroundStyle(.white.opacity(0.4))
            HStack(spacing: 10) {
                Text(token)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                Button {
                    UIPasteboard.general.string = token
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        copied = false
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .foregroundStyle(copied ? .green : .white.opacity(0.6))
                        .frame(width: 36, height: 36)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }
}
