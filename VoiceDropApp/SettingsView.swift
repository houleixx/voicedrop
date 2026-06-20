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
                                .frame(minHeight: 220)
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
                }
                .padding(20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
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
