import SwiftUI
import Observation
import UIKit

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

    // WeChat public account credentials — stored as users/<sub>/WECHAT.json
    var wechatAppId = ""
    var wechatSecret = ""
    var savingWechat = false
    var savedWechat = false
    var wechatError: String?

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

    func articlesPageURL() async -> URL? {
        guard !token.isEmpty else { return nil }
        var req = URLRequest(url: base.appending(path: "token").appending(path: "articles"))
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true,
              let obj = try? JSONDecoder().decode([String: String].self, from: data),
              let urlStr = obj["url"] else { return nil }
        return URL(string: urlStr)
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

    func loadWechat() async {
        guard !token.isEmpty else { return }
        var req = URLRequest(url: base.appending(path: "download").appending(path: "WECHAT.json"))
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 404 { return }
            guard (200..<300).contains(code) else { return }
            if let obj = try? JSONDecoder().decode([String: String].self, from: data) {
                wechatAppId = obj["appid"] ?? ""
                wechatSecret = obj["secret"] ?? ""
            }
        } catch {}
    }

    func saveWechat() async {
        guard !token.isEmpty else { wechatError = "请先登录"; return }
        savingWechat = true; savedWechat = false; wechatError = nil
        defer { savingWechat = false }
        let payload = ["appid": wechatAppId.trimmingCharacters(in: .whitespacesAndNewlines),
                       "secret": wechatSecret.trimmingCharacters(in: .whitespacesAndNewlines)]
        guard let body = try? JSONEncoder().encode(payload) else { wechatError = "编码失败"; return }
        var req = URLRequest(url: base.appending(path: "upload").appending(path: "WECHAT.json"))
        req.httpMethod = "PUT"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        do {
            let (_, resp) = try await URLSession.shared.upload(for: req, from: body)
            guard (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true else {
                wechatError = "保存失败"; return
            }
            savedWechat = true
        } catch { wechatError = error.localizedDescription }
    }
}

struct SettingsView: View {
    var active: Bool = true
    @State private var store = SettingsStore()
    @State private var editingStyle = false
    @State private var draftStyle = ""
    @State private var idCopied = false
    @State private var tokenCopied = false
    @State private var fetchingArticlesLink = false
    @State private var articlesLinkError = false

    private var anonId: String { AuthStore.shared.anonId }
    private var anonToken: String { AuthStore.shared.anonToken }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    field(title: "名字") {
                        TextField("你的名字", text: $store.name)
                            .textFieldStyle(.plain)
                            .submitLabel(.done)
                            .foregroundStyle(.white)
                            .padding(12)
                            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                    }

                    field(title: "文风") {
                        VStack(alignment: .leading, spacing: 6) {
                            // Tap to edit in a full-screen sheet — the keyboard can't
                            // cover the tab bar there, and 完成 sits above it.
                            Button { draftStyle = store.style; store.error = nil; editingStyle = true } label: {
                                HStack(alignment: .top) {
                                    Text(store.style.isEmpty ? "点这里编辑你的文风" : store.style)
                                        .foregroundStyle(store.style.isEmpty ? .white.opacity(0.35) : .white.opacity(0.85))
                                        .font(.callout).lineLimit(3)
                                        .multilineTextAlignment(.leading)
                                    Spacer()
                                    Image(systemName: "square.and.pencil").foregroundStyle(.white.opacity(0.4))
                                }
                                .padding(12)
                                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                            }
                            Text("把蒸馏出来的文风文本贴进来。服务器挖文章时会带上它，让文章更像你。")
                                .font(.caption).foregroundStyle(.white.opacity(0.4))
                        }
                    }

                    Divider().overlay(Color.white.opacity(0.08)).padding(.vertical, 6)

                    field(title: "微信公众号") {
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("AppID（wx...）", text: $store.wechatAppId)
                                .textFieldStyle(.plain)
                                .submitLabel(.next)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .foregroundStyle(.white)
                                .padding(12)
                                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                            SecureField("AppSecret", text: $store.wechatSecret)
                                .textFieldStyle(.plain)
                                .submitLabel(.done)
                                .foregroundStyle(.white)
                                .padding(12)
                                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                            Button {
                                Task { await store.saveWechat() }
                            } label: {
                                HStack {
                                    if store.savingWechat {
                                        ProgressView().tint(.white).scaleEffect(0.8)
                                    } else if store.savedWechat {
                                        Image(systemName: "checkmark").font(.caption)
                                    }
                                    Text(store.savedWechat ? "已保存" : "保存公众号凭据")
                                }
                                .font(.callout).foregroundStyle(.white.opacity(0.85))
                                .padding(12)
                                .frame(maxWidth: .infinity)
                                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                            }
                            .disabled(store.savingWechat || store.wechatAppId.isEmpty || store.wechatSecret.isEmpty)
                            if let e = store.wechatError {
                                Text(e).font(.caption).foregroundStyle(.orange)
                            } else {
                                Text("设置后，每次挖出新文章都会自动推送微信公众号草稿。")
                                    .font(.caption).foregroundStyle(.white.opacity(0.4))
                            }
                        }
                    }

                    Divider().overlay(Color.white.opacity(0.08)).padding(.vertical, 6)

                    field(title: "账户") {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 10) {
                                copyButton(idCopied ? "已复制 ✓" : "复制 ID", "doc.on.doc") {
                                    UIPasteboard.general.string = anonId; idCopied = true; tokenCopied = false
                                }
                                copyButton(tokenCopied ? "已复制 ✓" : "复制访问令牌", "key") {
                                    UIPasteboard.general.string = anonToken; tokenCopied = true; idCopied = false
                                }
                            }
                            Text("ID 是你在服务器上的文件夹名（可分享）；访问令牌是私密的，用于 jianshuo.dev/files 或 curl。")
                                .font(.caption).foregroundStyle(.white.opacity(0.4))
                        }
                    }

                    Divider().overlay(Color.white.opacity(0.08)).padding(.vertical, 6)

                    field(title: "我的文章") {
                        VStack(alignment: .leading, spacing: 8) {
                            Button {
                                guard !fetchingArticlesLink else { return }
                                articlesLinkError = false
                                Task {
                                    fetchingArticlesLink = true
                                    defer { fetchingArticlesLink = false }
                                    if let url = await store.articlesPageURL() {
                                        await UIApplication.shared.open(url)
                                    } else {
                                        articlesLinkError = true
                                    }
                                }
                            } label: {
                                HStack {
                                    Image(systemName: "doc.text")
                                    Text("查看全部文章")
                                    Spacer()
                                    if fetchingArticlesLink {
                                        ProgressView().tint(.white.opacity(0.6)).scaleEffect(0.8)
                                    } else {
                                        Image(systemName: "arrow.up.right").font(.footnote)
                                    }
                                }
                                .font(.callout).foregroundStyle(.white.opacity(0.85))
                                .padding(12)
                                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                            }
                            if articlesLinkError {
                                Text("生成链接失败，请检查网络后重试。")
                                    .font(.caption).foregroundStyle(.orange)
                            } else {
                                Text("生成一个 24 小时有效的临时链接，在浏览器里浏览你所有成文的录音。")
                                    .font(.caption).foregroundStyle(.white.opacity(0.4))
                            }
                        }
                    }

                    Divider().overlay(Color.white.opacity(0.08)).padding(.vertical, 6)

                    field(title: "给 Agent 用") {
                        VStack(alignment: .leading, spacing: 8) {
                            Link(destination: URL(string: "https://jianshuo.dev/voicedrop/agent")!) {
                                HStack {
                                    Image(systemName: "terminal")
                                    Text("在 Claude Code / Codex 里用 VoiceDrop")
                                    Spacer()
                                    Image(systemName: "arrow.up.right").font(.footnote)
                                }
                                .font(.callout).foregroundStyle(.white.opacity(0.85))
                                .padding(12)
                                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                            }
                            Text("VoiceDrop 为 Agent 而生 —— 你的录音和文章都能通过开放 API 直接被 agent 读写。")
                                .font(.caption).foregroundStyle(.white.opacity(0.4))
                        }
                    }
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
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
        .task { await store.load(); await store.loadWechat() }
        .onChange(of: active) { _, now in if now { Task { await store.load(); await store.loadWechat() } } }
        .sheet(isPresented: $editingStyle) { styleEditor }
    }

    // Full-screen 文风 editor. Edits a draft so 取消 truly reverts. 保存 commits
    // the draft and writes CLAUDE.md (name + style). Both buttons sit in the nav
    // bar above the keyboard, so nothing is ever covered.
    private var styleEditor: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextEditor(text: $draftStyle)
                    .foregroundStyle(.white)
                    .scrollContentBackground(.hidden)
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let e = store.error {
                    Text(e).font(.footnote).foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16).padding(.bottom, 8)
                }
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("文风")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { editingStyle = false }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task {
                            store.style = draftStyle
                            await store.save()
                            if store.error == nil { editingStyle = false }
                        }
                    } label: {
                        if store.saving { ProgressView().tint(.white) } else { Text("保存").bold() }
                    }
                    .disabled(store.saving)
                }
            }
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(store.saving)
    }

    private func copyButton(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.caption).foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color.white.opacity(0.08), in: Capsule())
        }
    }

    private func field<Content: View>(title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline).foregroundStyle(.white.opacity(0.85))
            content()
        }
    }
}

