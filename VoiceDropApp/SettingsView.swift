import SwiftUI
import Observation
import UIKit

private enum ArticlesLinkError: LocalizedError {
    case unauthenticated, http(Int, String), badResponse
    var errorDescription: String? {
        switch self {
        case .unauthenticated: return "未登录"
        case .http(let code, let body): return "HTTP \(code): \(body)"
        case .badResponse: return "响应格式错误"
        }
    }
}

/// Per-user writing identity, stored on the server as users/<sub>/CLAUDE.md, plus
/// the WeChat config (users/<sub>/WECHAT.json). Logic unchanged from the dark
/// build — only the views around it were restyled.
@MainActor
@Observable
final class SettingsStore {
    var name = ""
    var style = ""
    var loading = false
    var saving = false
    var saved = false
    var error: String?

    var wechatEnabled = false
    var wechatAppId = ""
    var wechatSecret = ""
    var wechatConfigured: Bool { !wechatAppId.isEmpty && !wechatSecret.isEmpty }
    var savingWechat = false
    var savedWechat = false
    var wechatError: String?
    private(set) var wechatThumbMediaId = ""

    private let base = URL(string: "https://jianshuo.dev/files/api")!
    private var token: String { AuthStore.shared.bearer }

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
            if code == 404 { return }
            guard (200..<300).contains(code) else { error = "加载失败"; return }
            let parsed = Self.parse(String(decoding: data, as: UTF8.self))
            name = parsed.name; style = parsed.style
        } catch { self.error = error.localizedDescription }
    }

    func articlesPageURL() async throws -> URL {
        guard !token.isEmpty else { throw ArticlesLinkError.unauthenticated }
        var req = URLRequest(url: base.appending(path: "token").appending(path: "articles"))
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            let body = String(String(decoding: data, as: UTF8.self).prefix(80))
            throw ArticlesLinkError.http(code, body)
        }
        struct Resp: Decodable { let url: String }
        guard let obj = try? JSONDecoder().decode(Resp.self, from: data),
              let url = URL(string: obj.url) else { throw ArticlesLinkError.badResponse }
        return url
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

    private struct WechatConfig: Codable {
        var appid: String
        var secret: String
        var enabled: Bool?
        var thumb_media_id: String?
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
            guard let cfg = try? JSONDecoder().decode(WechatConfig.self, from: data) else { return }
            wechatAppId = cfg.appid
            wechatSecret = cfg.secret
            wechatEnabled = cfg.enabled ?? true
            wechatThumbMediaId = cfg.thumb_media_id ?? ""
        } catch {}
    }

    /// Validate the WeChat credentials before saving. WeChat checks
    /// appid → IP whitelist → secret, so from the app we can format-check both and
    /// catch a non-existent appid (40013); a well-formed secret can only be fully
    /// verified from the whitelisted server (we get 40164 here), so it's accepted
    /// and confirmed at publish time. Returns nil if OK, else an error message.
    func validateWechatCreds() async -> String? {
        let appid = wechatAppId.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = wechatSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard appid.range(of: "^wx[0-9A-Za-z]{16}$", options: .regularExpression) != nil else {
            return "AppID 格式不对（应为 wx 开头、共 18 位）"
        }
        guard secret.range(of: "^[0-9a-f]{32}$", options: .regularExpression) != nil else {
            return "AppSecret 格式不对（应为 32 位小写十六进制，别把 AppID 填进来）"
        }
        var c = URLComponents(string: "https://api.weixin.qq.com/cgi-bin/token")!
        c.queryItems = [
            .init(name: "grant_type", value: "client_credential"),
            .init(name: "appid", value: appid),
            .init(name: "secret", value: secret),
        ]
        guard let url = c.url else { return nil }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if obj?["access_token"] != nil { return nil }
            switch obj?["errcode"] as? Int ?? -1 {
            case 0, 40164: return nil                                   // appid OK; IP not whitelisted (expected from the phone)
            case 40013:    return "AppID 无效，找不到这个公众号"
            case 40125:    return "AppSecret 无效"
            case 41002:    return "缺少 AppID"
            case 41004:    return "缺少 AppSecret"
            default:
                let msg = obj?["errmsg"] as? String ?? "未知错误"
                return "验证失败：\(msg)"
            }
        } catch {
            return nil   // can't reach WeChat — format already checked; don't block the save
        }
    }

    func saveWechat() async {
        guard !token.isEmpty else { wechatError = "请先登录"; return }
        savingWechat = true; savedWechat = false; wechatError = nil
        defer { savingWechat = false }
        if let err = await validateWechatCreds() { wechatError = err; return }   // don't save invalid creds
        await persistWechat()
    }

    func disconnectWechat() async {
        wechatAppId = ""; wechatSecret = ""; wechatEnabled = false
        savingWechat = true; savedWechat = false; wechatError = nil
        defer { savingWechat = false }
        await persistWechat()
    }

    /// PUT the current config to users/<sub>/WECHAT.json (no validation — used by
    /// both save-after-validate and disconnect).
    private func persistWechat() async {
        let cfg = WechatConfig(
            appid: wechatAppId.trimmingCharacters(in: .whitespacesAndNewlines),
            secret: wechatSecret.trimmingCharacters(in: .whitespacesAndNewlines),
            enabled: wechatEnabled,
            thumb_media_id: wechatThumbMediaId.isEmpty ? nil : wechatThumbMediaId
        )
        guard let body = try? JSONEncoder().encode(cfg) else { wechatError = "编码失败"; return }
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

// MARK: - Shared building blocks

func settingsTile(_ bg: Color, _ symbol: String, _ fg: Color) -> some View {
    RoundedRectangle(cornerRadius: Theme.R.tile).fill(bg).frame(width: 42, height: 42)
        .overlay(Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(fg))
}

var settingsChevron: some View {
    Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.chevron)
}

struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.R.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.R.card).stroke(Theme.borderChrome, lineWidth: 1))
            .cardChromeShadow()
    }
}

struct SettingsRow<Trailing: View>: View {
    var tileBG: Color, symbol: String, tileFG: Color
    var title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            settingsTile(tileBG, symbol, tileFG)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 16)).foregroundStyle(Theme.ink)
                if let s = subtitle { Text(s).font(.system(size: 12.5)).foregroundStyle(Theme.secondary) }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.vertical, 12).padding(.horizontal, 15)
        .contentShape(Rectangle())
    }
}

var settingsRowDivider: some View {
    Rectangle().fill(Theme.dividerInCard).frame(height: 1).padding(.leading, 69)
}

func settingsSectionLabel(_ t: String) -> some View {
    Text(t).font(.system(size: 13, weight: .semibold)).tracking(1)
        .foregroundStyle(Theme.sectionLabel)
        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4)
}

// MARK: - Settings

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store = SettingsStore()
    @State private var prefs = Prefs.shared
    @State private var showWechat = false
    @State private var showStyle = false
    @State private var showPrivacy = false

    private var shortTag: String {
        let id = AuthStore.shared.anonId          // "anon-7f3a…"
        let hex = id.hasPrefix("anon-") ? String(id.dropFirst(5)) : id
        return "VD·" + hex.prefix(4).uppercased()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                NavSquare(systemName: "chevron.left", size: 36) { dismiss() }
                Text("设置").font(.system(size: 26, weight: .semibold)).foregroundStyle(Theme.ink)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 6)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    // 账户
                    SettingsCard {
                        NavigationLink { AccountView() } label: {
                            SettingsRow(tileBG: Theme.inkTile, symbol: "checkmark.shield.fill", tileFG: .white,
                                        title: "账户", subtitle: "无需登录 · ID 已随 iCloud 钥匙串备份") {
                                HStack(spacing: 8) {
                                    Text(shortTag).font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.faint)
                                    settingsChevron
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }

                    group("发布") {
                        SettingsCard {
                            Button { showWechat = true } label: {
                                SettingsRow(tileBG: Theme.accentSoft, symbol: "paperplane.fill", tileFG: Theme.accent,
                                            title: "微信公众号", subtitle: "成文一键推送到草稿箱") {
                                    HStack(spacing: 8) { wechatBadge; settingsChevron }
                                }
                            }.buttonStyle(.plain)
                            settingsRowDivider
                            Button { showStyle = true } label: {
                                SettingsRow(tileBG: Theme.tileNeutral, symbol: "pencil", tileFG: Theme.secondary,
                                            title: "写作风格", subtitle: "名字与文风，决定挖文章的语气") { settingsChevron }
                            }.buttonStyle(.plain)
                        }
                    }

                    group("同步与存储") {
                        SettingsCard {
                            SettingsRow(tileBG: Theme.tileNeutral, symbol: "icloud", tileFG: Theme.secondary,
                                        title: "备份到 iCloud", subtitle: "云端留底，换机不丢") {
                                Toggle("", isOn: Binding(get: { prefs.iCloudBackup }, set: { prefs.iCloudBackup = $0 }))
                                    .labelsHidden().tint(Theme.accent)
                            }
                        }
                    }

                    group("其他") {
                        SettingsCard {
                            Button { showPrivacy = true } label: {
                                SettingsRow(tileBG: Theme.tileNeutral, symbol: "hand.raised", tileFG: Theme.secondary,
                                            title: "隐私说明") { settingsChevron }
                            }.buttonStyle(.plain)
                            settingsRowDivider
                            SettingsRow(tileBG: Theme.tileNeutral, symbol: "info.circle", tileFG: Theme.secondary,
                                        title: "版本") {
                                Text(Prefs.versionBuild).font(.system(size: 14)).foregroundStyle(Theme.faint)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 40)
            }
        }
        .background(Theme.appBG.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task { await store.load(); await store.loadWechat() }
        .sheet(isPresented: $showWechat) { WechatSettingsSheet(store: store) }
        .sheet(isPresented: $showStyle) { WritingStyleSheet(store: store) }
        .alert("隐私说明", isPresented: $showPrivacy) {
            Button("好") {}
        } message: {
            Text("录音只上传到你自己的云端空间；麦克风仅在录音和语音修改时使用；身份是本机生成的匿名 ID，随 iCloud 钥匙串备份。")
        }
    }

    @ViewBuilder private func group<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            settingsSectionLabel(label)
            content()
        }
    }

    @ViewBuilder private var wechatBadge: some View {
        if store.wechatConfigured {
            HStack(spacing: 5) {
                Circle().fill(Theme.greenDone).frame(width: 6, height: 6)
                Text("已连接").font(.system(size: 12.5)).foregroundStyle(Theme.greenDone)
            }
        } else {
            Text("未配置").font(.system(size: 12.5)).foregroundStyle(Theme.faint)
        }
    }
}

// MARK: - Writing style (名字 + 文风) — kept from the original, restyled

struct WritingStyleSheet: View {
    @Bindable var store: SettingsStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    field("名字") {
                        TextField("你的名字", text: $store.name)
                            .textFieldStyle(.plain).foregroundStyle(Theme.ink)
                            .padding(13)
                            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.R.input))
                            .overlay(RoundedRectangle(cornerRadius: Theme.R.input).stroke(Theme.inputBorder, lineWidth: 1.5))
                    }
                    field("文风") {
                        VStack(alignment: .leading, spacing: 6) {
                            TextEditor(text: $store.style)
                                .scrollContentBackground(.hidden)
                                .foregroundStyle(Theme.ink).font(.system(size: 15))
                                .frame(minHeight: 220)
                                .padding(10)
                                .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.R.input))
                                .overlay(RoundedRectangle(cornerRadius: Theme.R.input).stroke(Theme.inputBorder, lineWidth: 1.5))
                            Text("把蒸馏出来的文风贴进来。服务器挖文章时会带上它，让文章更像你。")
                                .font(.system(size: 12.5)).foregroundStyle(Theme.faint)
                        }
                    }
                    if let e = store.error {
                        Text(e).font(.system(size: 13)).foregroundStyle(.orange)
                    }
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.appBG.ignoresSafeArea())
            .navigationTitle("写作风格")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await store.save(); if store.error == nil { dismiss() } }
                    } label: {
                        if store.saving { ProgressView() } else { Text("保存").bold() }
                    }
                    .disabled(store.saving)
                }
            }
        }
    }

    @ViewBuilder private func field<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.ink)
            content()
        }
    }
}

// MARK: - WeChat config — logic unchanged, restyled to light

struct WechatSettingsSheet: View {
    @Bindable var store: SettingsStore
    @Environment(\.dismiss) private var dismiss
    @State private var ipCopied = false
    @State private var showSecret = false

    private let whitelistIP = "66.42.45.128"

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    banner

                    Toggle(isOn: $store.wechatEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("自动推草稿").font(.system(size: 15)).foregroundStyle(Theme.ink)
                            Text("挖出新文章后自动发到公众号草稿箱")
                                .font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
                        }
                    }
                    .tint(Theme.accent)
                    .padding(14)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.R.card))
                    .overlay(RoundedRectangle(cornerRadius: Theme.R.card).stroke(Theme.borderChrome, lineWidth: 1))

                    VStack(alignment: .leading, spacing: 10) {
                        Text("凭据").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.ink)
                        TextField("AppID（wx...）", text: $store.wechatAppId)
                            .textFieldStyle(.plain).autocorrectionDisabled().textInputAutocapitalization(.never)
                            .font(.system(size: 15, design: .monospaced)).foregroundStyle(Theme.ink)
                            .padding(.vertical, 12).padding(.horizontal, 14)
                            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.R.input))
                            .overlay(RoundedRectangle(cornerRadius: Theme.R.input).stroke(Theme.inputBorder, lineWidth: 1.5))

                        HStack {
                            Group {
                                if showSecret { TextField("AppSecret", text: $store.wechatSecret) }
                                else { SecureField("AppSecret", text: $store.wechatSecret) }
                            }
                            .textFieldStyle(.plain).autocorrectionDisabled().textInputAutocapitalization(.never)
                            .font(.system(size: 15, design: .monospaced)).foregroundStyle(Theme.ink)
                            Button { showSecret.toggle() } label: {
                                Image(systemName: showSecret ? "eye.slash" : "eye").foregroundStyle(Theme.secondary)
                            }
                        }
                        .padding(.vertical, 12).padding(.horizontal, 14)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.R.input))
                        .overlay(RoundedRectangle(cornerRadius: Theme.R.input).stroke(Theme.inputBorder, lineWidth: 1.5))

                        VStack(alignment: .leading, spacing: 6) {
                            Text("凭证只保存在你的设备与服务器的加密配置里，不会出现在文章中。")
                                .font(.system(size: 12.5)).foregroundStyle(Theme.faint)
                                .fixedSize(horizontal: false, vertical: true)
                            Link(destination: URL(string: "https://developers.weixin.qq.com/doc/offiaccount/Basic_Information/Get_access_token.html")!) {
                                HStack(spacing: 4) {
                                    Image(systemName: "safari").font(.system(size: 11))
                                    Text("去哪里找 AppID / AppSecret？")
                                        .font(.system(size: 12.5, weight: .semibold))
                                    Image(systemName: "arrow.up.right").font(.system(size: 10))
                                }
                                .foregroundStyle(Theme.accent)
                            }
                        }

                        if let e = store.wechatError { Text(e).font(.system(size: 13)).foregroundStyle(.orange) }
                    }

                    Divider().overlay(Theme.borderChrome)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("IP 白名单").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.ink)
                        Text("在公众号后台 → 开发 → 基本配置 → IP 白名单中加入以下地址，服务器才能正常调用接口推草稿。")
                            .font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button {
                            UIPasteboard.general.string = whitelistIP; ipCopied = true
                        } label: {
                            HStack {
                                Text(whitelistIP).font(.system(size: 15, design: .monospaced)).foregroundStyle(Theme.ink)
                                Spacer()
                                Image(systemName: ipCopied ? "checkmark" : "doc.on.doc").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                            }
                            .padding(13)
                            .background(Theme.appBG, in: RoundedRectangle(cornerRadius: Theme.R.input))
                            .overlay(RoundedRectangle(cornerRadius: Theme.R.input).stroke(Theme.borderChrome, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .onChange(of: ipCopied) { _, c in
                            if c { Task { try? await Task.sleep(nanoseconds: 2_000_000_000); ipCopied = false } }
                        }
                    }

                    VStack(spacing: 10) {
                        Button {
                            Task { await store.saveWechat() }
                        } label: {
                            HStack(spacing: 6) {
                                if store.savingWechat { ProgressView().tint(.white) }
                                else if store.savedWechat { Image(systemName: "checkmark").font(.system(size: 13)) }
                                Text(store.savedWechat ? "已保存" : "保存").font(.system(size: 16, weight: .semibold))
                            }
                            .foregroundStyle(.white).frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.R.primary))
                        }
                        .buttonStyle(.plain)
                        .disabled(store.savingWechat || store.wechatAppId.isEmpty || store.wechatSecret.isEmpty)

                        if store.wechatConfigured {
                            Button { Task { await store.disconnectWechat() } } label: {
                                Text("断开连接").font(.system(size: 15)).foregroundStyle(Theme.secondary)
                                    .frame(maxWidth: .infinity).padding(.vertical, 13)
                                    .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.R.primary))
                                    .overlay(RoundedRectangle(cornerRadius: Theme.R.primary).stroke(Theme.borderChrome, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.appBG.ignoresSafeArea())
            .navigationTitle("微信公众号")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        Task {
                            // Persist before dismissing — typing the credentials and
                            // tapping 完成 must save them (no silent loss).
                            if store.wechatConfigured {
                                await store.saveWechat()
                                if store.wechatError != nil { return }   // keep sheet open on error
                            }
                            dismiss()
                        }
                    }.bold()
                }
            }
        }
    }

    @ViewBuilder private var banner: some View {
        if store.wechatConfigured {
            HStack(spacing: 8) {
                Circle().fill(Theme.greenDone).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text("公众号已连接").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.okBannerTitle)
                    Text("凭据已保存").font(.system(size: 12.5)).foregroundStyle(Theme.okBannerSub)
                }
                Spacer()
            }
            .padding(.vertical, 13).padding(.horizontal, 15)
            .background(Theme.okBannerBG, in: RoundedRectangle(cornerRadius: Theme.R.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.R.card).stroke(Theme.okBannerBorder, lineWidth: 1))
        } else {
            HStack(spacing: 8) {
                Image(systemName: "paperplane").foregroundStyle(Theme.secondary)
                Text("填入公众号 AppID / AppSecret 即可连接。").font(.system(size: 13)).foregroundStyle(Theme.secondary)
                Spacer()
            }
            .padding(.vertical, 13).padding(.horizontal, 15)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.R.card))
            .overlay(RoundedRectangle(cornerRadius: Theme.R.card).stroke(Theme.borderChrome, lineWidth: 1))
        }
    }
}
