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

/// 版本名 = 文风正文的第一行，用来区分各个版本（比纯 vN 好认）。
/// 取第一行、最多 12 字，超出截断加省略号；界面上再用 lineLimit(1) 兜底自动收尾。
enum StyleNaming {
    static func name(_ style: String, max: Int = 12) -> String {
        let line = style.split(whereSeparator: \.isNewline).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard !line.isEmpty else { return "" }
        return line.count > max ? String(line.prefix(max)) + "…" : line
    }
}

/// One saved 文风 version (from GET /style/history). `savedAt` is epoch ms.
struct StyleVersion: Identifiable, Decodable {
    let v: Int
    let savedAt: Double
    let style: String
    var id: Int { v }
    var charCount: Int { style.count }
    var date: Date { Date(timeIntervalSince1970: savedAt / 1000) }
    /// 版本名：正文首行，最多 12 字（见 StyleNaming）。空文风 → 空串。
    var displayName: String { StyleNaming.name(style) }
}

/// Per-user writing identity, stored on the server as users/<sub>/CLAUDE.md, plus
/// the WeChat config (users/<sub>/WECHAT.json). Logic unchanged from the dark
/// build — only the views around it were restyled.
@MainActor
@Observable
final class SettingsStore {
    var style = ""
    var styleVersions: [StyleVersion] = []   // oldest-first, from /style/history
    var styleHead = 0
    var serverStyles: [Int] = []   // profile.styles (多风格对比 selection) from GET /style
    var suanliBalance: Double = 0  // 算力余额，给设置主列表「算力」行显示
    var suanliLoaded = false
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

    private let base = API.filesBase
    private var token: String { AuthStore.shared.bearer }

    // 文风存在 CLAUDE.json，单独走 /style（版本化）。
    private struct StylePayload: Encodable { let style: String }
    private struct StyleResponse: Decodable { let style: String?; let styles: [Int]? }

    func load() async {
        guard !token.isEmpty else { error = "请先登录"; return }
        loading = true; error = nil
        defer { loading = false }
        // 文风：走 /style（读 CLAUDE.json，404 时服务端回退老 CLAUDE.md 的「# 我的文风」段）。
        var styleReq = URLRequest(url: base.appending(path: "style"))
        styleReq.setBearer(token)
        do {
            let (data, resp) = try await URLSession.shared.data(for: styleReq)
            let code = resp.httpStatusCode
            if (200..<300).contains(code) {
                if let obj = try? JSONDecoder().decode(StyleResponse.self, from: data) {
                    style = obj.style ?? ""
                    serverStyles = obj.styles ?? []
                }
            } else if code != 404 {
                error = "加载失败"
            }
        } catch { self.error = error.localizedDescription }
    }

    /// Fetch 算力余额 for the 设置 list row (best-effort; the 算力 detail page reloads its own).
    func loadBalance() async {
        guard !token.isEmpty else { return }
        struct B: Decodable { let suanli: Double }
        guard let url = URL(string: "\(API.agentBase.absoluteString)/usage/balance") else { return }
        var req = URLRequest(url: url); req.setBearer(token)
        if let (data, resp) = try? await URLSession.shared.data(for: req), resp.isOK,
           let b = try? JSONDecoder().decode(B.self, from: data) {
            suanliBalance = b.suanli; suanliLoaded = true
        }
    }

    /// Fetch the 文风 version history (newest-first after load). Best-effort.
    func loadStyleHistory() async {
        guard !token.isEmpty else { return }
        var req = URLRequest(url: base.appending(path: "style").appending(path: "history"))
        req.setBearer(token)
        struct R: Decodable { let head: Int; let versions: [StyleVersion] }
        if let (data, resp) = try? await URLSession.shared.data(for: req), resp.isOK,
           let r = try? JSONDecoder().decode(R.self, from: data) {
            styleVersions = r.versions
            styleHead = r.head
        }
    }

    func articlesPageURL() async throws -> URL {
        guard !token.isEmpty else { throw ArticlesLinkError.unauthenticated }
        var req = URLRequest(url: base.appending(path: "token").appending(path: "articles"))
        req.setBearer(token)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = resp.httpStatusCode
        guard (200..<300).contains(code) else {
            let body = String(String(decoding: data, as: UTF8.self).prefix(80))
            throw ArticlesLinkError.http(code, body)
        }
        struct Resp: Decodable { let url: String }
        guard let obj = try? JSONDecoder().decode(Resp.self, from: data),
              let url = URL(string: obj.url) else { throw ArticlesLinkError.badResponse }
        return url
    }

    /// Save ONLY the 文风 (versioned /style). No name write — the name field is gone
    /// from the sheet, and the caller only invokes this on a real change, so each save
    /// creates at most one new version.
    /// Move the head pointer to an existing version (PATCH /style/head) — no new
    /// version. Used when the user just switched to a saved version without editing.
    func setStyleHead(_ head: Int) async {
        guard !token.isEmpty else { error = "请先登录"; return }
        saving = true; saved = false; error = nil
        defer { saving = false }
        var req = URLRequest(url: base.appending(path: "style").appending(path: "head"))
        req.httpMethod = "PATCH"
        req.setBearer(token)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = (try? JSONEncoder().encode(["head": head])) ?? Data()
        do {
            let (_, resp) = try await URLSession.shared.upload(for: req, from: body)
            guard resp.isOK else { error = "保存失败"; return }
            styleHead = head
            saved = true
        } catch { self.error = error.localizedDescription }
    }

    /// Persist the 多风格对比 selection to profile.styles (PUT /style {styles}) — the
    /// miner reads it. No 文风 version is created. Empty array = single-style.
    func saveStyles(_ styles: [Int]) async {
        guard !token.isEmpty else { return }
        var req = URLRequest(url: base.appending(path: "style"))
        req.httpMethod = "PUT"
        req.setBearer(token)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = (try? JSONEncoder().encode(["styles": styles])) ?? Data()
        _ = try? await URLSession.shared.upload(for: req, from: body)
        serverStyles = styles
    }

    func saveStyle() async {
        guard !token.isEmpty else { error = "请先登录"; return }
        let trimmed = style.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        saving = true; saved = false; error = nil
        defer { saving = false }
        do {
            var req = URLRequest(url: base.appending(path: "style"))
            req.httpMethod = "PUT"
            req.setBearer(token)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let payload = try JSONEncoder().encode(StylePayload(style: trimmed))
            let (_, resp) = try await URLSession.shared.upload(for: req, from: payload)
            guard resp.isOK else { error = "保存失败"; return }
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
        req.setBearer(token)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = resp.httpStatusCode
            if code == 404 { return }
            guard (200..<300).contains(code) else { return }
            guard let cfg = try? JSONDecoder().decode(WechatConfig.self, from: data) else { return }
            wechatAppId = cfg.appid
            wechatSecret = cfg.secret
            wechatEnabled = cfg.enabled ?? true
            wechatThumbMediaId = cfg.thumb_media_id ?? ""
        } catch {}
    }

    var autoShareCommunity = false

    private struct AppConfig: Codable { var autoShareCommunity: Bool? }

    func loadConfig() async {
        guard !token.isEmpty else { return }
        var req = URLRequest(url: base.appending(path: "download").appending(path: "CONFIG.json"))
        req.setBearer(token)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = resp.httpStatusCode
            if code == 404 { return }
            guard (200..<300).contains(code) else { return }
            guard let cfg = try? JSONDecoder().decode(AppConfig.self, from: data) else { return }
            autoShareCommunity = cfg.autoShareCommunity ?? false
        } catch {}
    }

    func saveConfig() async {
        guard !token.isEmpty else { return }
        let cfg = AppConfig(autoShareCommunity: autoShareCommunity)
        guard let body = try? JSONEncoder().encode(cfg) else { return }
        var req = URLRequest(url: base.appending(path: "upload").appending(path: "CONFIG.json"))
        req.httpMethod = "PUT"
        req.setBearer(token)
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        do { _ = try await URLSession.shared.upload(for: req, from: body) } catch {}
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
        req.setBearer(token)
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        do {
            let (_, resp) = try await URLSession.shared.upload(for: req, from: body)
            guard resp.isOK else {
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
    let libraryStore: LibraryStore

    @Environment(\.dismiss) private var dismiss
    @State private var store = SettingsStore()
    @State private var prefs = Prefs.shared
    @State private var showWechat = false
    @State private var showStyle = false
    @State private var showingExport = false
    @State private var exportManager = ExportManager()

    private var shortTag: String {
        let id = AuthStore.shared.anonId          // "anon-7f3a…"
        let hex = id.hasPrefix("anon-") ? String(id.dropFirst(5)) : id
        return hex.prefix(6).uppercased()
    }

    private var autoShareBinding: Binding<Bool> {
        Binding(
            get: { store.autoShareCommunity },
            set: { newValue in
                if newValue {
                    if AuthStore.shared.isAuthenticated {
                        store.autoShareCommunity = true
                        Task { await store.saveConfig() }
                    } else {
                        Task {
                            await AuthStore.shared.signInWithApple()
                            if AuthStore.shared.isAuthenticated {
                                store.autoShareCommunity = true
                                await store.saveConfig()
                            }
                        }
                    }
                } else {
                    store.autoShareCommunity = false
                    Task { await store.saveConfig() }
                }
            }
        )
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
                    // 账户 + 写作风格 — 同一张卡，连在一起
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
                        settingsRowDivider
                        NavigationLink { UsageView() } label: {
                            SettingsRow(tileBG: Theme.amberSoft, symbol: "bolt.fill", tileFG: Theme.amber,
                                        title: "算力",
                                        subtitle: store.suanliLoaded
                                            ? "约可成文 \(Suanli.articles(store.suanliBalance)) 篇"
                                            : "余额与消耗明细") {
                                HStack(spacing: 8) {
                                    if store.suanliLoaded {
                                        Text("\(Int(store.suanliBalance.rounded()))")
                                            .font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.amber)
                                    }
                                    settingsChevron
                                }
                            }
                        }.buttonStyle(.plain)
                        settingsRowDivider
                        Button { showStyle = true } label: {
                            SettingsRow(tileBG: Theme.tileNeutral, symbol: "pencil", tileFG: Theme.secondary,
                                        title: "写作风格", subtitle: "成文时模仿这套语气") { settingsChevron }
                        }.buttonStyle(.plain)
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
                            SettingsRow(tileBG: Theme.okBannerBG, symbol: "person.2.fill", tileFG: Theme.greenDone,
                                        title: "自动分享到 VD社区", subtitle: "挖出新文章后自动发到社区") {
                                Toggle("", isOn: autoShareBinding).labelsHidden().tint(Theme.accent)
                            }
                        }
                    }

                    group("同步与存储") {
                        SettingsCard {
                            SettingsRow(tileBG: Theme.tileNeutral, symbol: "icloud", tileFG: Theme.secondary,
                                        title: "备份到 iCloud", subtitle: "云端留底，换机不丢") {
                                Toggle("", isOn: Binding(get: { prefs.iCloudBackup }, set: { prefs.iCloudBackup = $0 }))
                                    .labelsHidden().tint(Theme.accent)
                            }
                            settingsRowDivider
                            Button { showingExport = true } label: {
                                SettingsRow(tileBG: Theme.tileNeutral, symbol: "square.and.arrow.down",
                                            tileFG: Theme.secondary, title: "导出数据",
                                            subtitle: "所有录音和文章打包下载") { settingsChevron }
                            }.buttonStyle(.plain)
                        }
                    }

                    group("其他") {
                        SettingsCard {
                            NavigationLink { AboutView() } label: {
                                SettingsRow(tileBG: Theme.tileNeutral, symbol: "info.circle", tileFG: Theme.secondary,
                                            title: "关于") { settingsChevron }
                            }
                            settingsRowDivider
                            SettingsRow(tileBG: Theme.tileNeutral, symbol: "number", tileFG: Theme.secondary,
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
        .task { await store.load(); await store.loadWechat(); await store.loadConfig(); await store.loadBalance() }
        .sheet(isPresented: $showWechat) { WechatSettingsSheet(store: store) }
        .sheet(isPresented: $showStyle) { WritingStyleSheet(store: store) }
        .sheet(isPresented: $showingExport, onDismiss: { exportManager.reset() }) {
            ExportSheet(manager: exportManager, recordings: libraryStore.recordings, store: libraryStore)
                .presentationDetents([.medium])
                .presentationDragIndicator(.hidden)
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

// MARK: - 关于 (隐私 / 公约 / 屏蔽 / 联系) — moved out of 设置「其他」behind one entry

/// The four secondary items (隐私说明 / 社区公约 / 已屏蔽用户 / 联系我们) live here, one
/// tap into 设置「其他」→「关于」. 版本 stays on the 其他 card.
struct AboutView: View {
    @State private var showPrivacy = false
    @State private var showGuidelines = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                SettingsCard {
                    Button { showPrivacy = true } label: {
                        SettingsRow(tileBG: Theme.tileNeutral, symbol: "hand.raised", tileFG: Theme.secondary,
                                    title: "隐私说明") { settingsChevron }
                    }.buttonStyle(.plain)
                    settingsRowDivider
                    Button { showGuidelines = true } label: {
                        SettingsRow(tileBG: Theme.tileNeutral, symbol: "doc.text", tileFG: Theme.secondary,
                                    title: "社区公约") { settingsChevron }
                    }.buttonStyle(.plain)
                    settingsRowDivider
                    NavigationLink { BlockedUsersView() } label: {
                        SettingsRow(tileBG: Theme.tileNeutral, symbol: "hand.raised.slash", tileFG: Theme.secondary,
                                    title: "已屏蔽用户") { settingsChevron }
                    }
                    settingsRowDivider
                    Link(destination: URL(string: "mailto:\(CommunityTerms.supportEmail)?subject=VoiceDrop%20反馈与投诉")!) {
                        SettingsRow(tileBG: Theme.tileNeutral, symbol: "envelope", tileFG: Theme.secondary,
                                    title: "联系我们 / 内容投诉") { settingsChevron }
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 40)
        }
        .background(Theme.appBG.ignoresSafeArea())
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
        .alert("隐私说明", isPresented: $showPrivacy) {
            Button("好") {}
        } message: {
            Text("录音只上传到你自己的云端空间；麦克风仅在录音和语音修改时使用；身份是本机生成的匿名 ID，随 iCloud 钥匙串备份。")
        }
        .alert("社区公约", isPresented: $showGuidelines) {
            Button("好") {}
        } message: {
            Text(CommunityTerms.body)
        }
    }
}

// MARK: - Writing style (文风 + 版本历史) — full-page editor per Settings.dc.html

struct WritingStyleSheet: View {
    @Bindable var store: SettingsStore
    @Environment(\.dismiss) private var dismiss
    @State private var showVersions = false
    @State private var selectedV: Int?     // version loaded in the editor; nil → head
    @State private var originalStyle = ""  // baseline at open; 保存 enables only on a real diff
    @State private var prefs = Prefs.shared

    private var currentV: Int { selectedV ?? store.styleHead }
    private var versionsDesc: [StyleVersion] { store.styleVersions.reversed() }
    private var currentDate: Date? { store.styleVersions.first { $0.v == currentV }?.date }
    private var loadedVersionStyle: String? { store.styleVersions.first { $0.v == currentV }?.style }
    private func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The editor text is UNCHANGED from the version it was loaded from (no manual edit).
    private var textUnchangedFromLoaded: Bool {
        guard let loaded = loadedVersionStyle else { return false }
        return trimmed(store.style) == trimmed(loaded)
    }
    private var canSave: Bool {
        let now = trimmed(store.style)
        guard !now.isEmpty else { return false }
        if loadedVersionStyle != nil {
            // Switched to a saved version without editing → only actionable (move head)
            // when it's not already the head. Edited text → always saveable (new version).
            return textUnchangedFromLoaded ? (currentV != store.styleHead) : true
        }
        // Legacy / no versions yet: compare to the open-time baseline (edit-then-revert = no change).
        return now != trimmed(originalStyle)
    }
    /// 保存 should only MOVE the head (no new version) when the user merely switched to a
    /// different saved version and didn't touch the text.
    private var saveJustMovesHead: Bool { textUnchangedFromLoaded && currentV != store.styleHead }

    // 多风格对比（设置侧 UI；选择存 Prefs。挖矿/阅读页暂未接入——本版只做选择）。
    private var compareOn: Bool { prefs.multiStyle }
    private var selectedVersions: [Int] { prefs.styles.sorted(by: >) }
    private func toggleCompareSelect(_ v: Int) {
        if let idx = prefs.styles.firstIndex(of: v) {
            prefs.styles.remove(at: idx)
        } else if prefs.styles.count < 3 {
            prefs.styles.append(v)
        }
    }
    private var compareFooter: String {
        let vs = selectedVersions
        let head = vs.isEmpty ? "勾选 2–3 个版本" : "完成后将分别用 " + vs.map { "v\($0)" }.joined(separator: "、")
        return head + "，成文时各生成一篇，在阅读页顶部切换对比。最多选 3 个。"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !store.styleVersions.isEmpty {
                    versionBar.padding(.horizontal, 16).padding(.top, 10)
                }
                if let e = store.error {
                    Text(e).font(.system(size: 13)).foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).padding(.top, 8)
                }

                // 整页编辑框 + 版本下拉浮层
                ZStack(alignment: .top) {
                    TextEditor(text: $store.style)
                        .scrollContentBackground(.hidden)
                        .foregroundStyle(Theme.ink).font(.system(size: 15.5)).lineSpacing(5)
                        .padding(.horizontal, 14).padding(.top, 12)
                        .background(Theme.appBG)
                        .overlay(alignment: .topLeading) {
                            // TextEditor has no placeholder — show an empty-state hint so a
                            // first-time account (no CLAUDE.json yet) isn't a blank page.
                            if store.style.isEmpty && !store.loading {
                                Text("还没有写作风格。\n\n把蒸馏好的文风贴进来，挖文章时会带上它、让文章更像你；或者让 Claude 用「蒸馏文风」从你已发的文章里提炼一份。")
                                    .font(.system(size: 15.5)).foregroundStyle(Theme.faint).lineSpacing(5)
                                    .padding(.horizontal, 19).padding(.top, 20)
                                    .allowsHitTesting(false)
                            }
                        }
                    if showVersions {
                        Color.black.opacity(0.04).ignoresSafeArea()
                            .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { showVersions = false } }
                        versionDropdown.padding(.horizontal, 16).padding(.top, 4)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Theme.appBG.ignoresSafeArea())
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("写作风格")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    if compareOn {
                        // 对比模式：「完成」把选择写进 profile.styles（miner 读它）。
                        Button("完成") {
                            Task { await store.saveStyles(prefs.styles); dismiss() }
                        }.bold()
                    } else {
                        Button {
                            Task {
                                // Switched version, no edit → just move the head pointer.
                                // Actually edited → write a new version.
                                if saveJustMovesHead { await store.setStyleHead(currentV) }
                                else { await store.saveStyle() }
                                if store.error == nil { dismiss() }
                            }
                        } label: {
                            if store.saving { ProgressView() } else { Text("保存").bold() }
                        }
                        .disabled(!canSave || store.saving)
                    }
                }
            }
            .task {
                await store.loadStyleHistory()
                if selectedV == nil { selectedV = store.styleHead }
                originalStyle = store.styleVersions.first { $0.v == store.styleHead }?.style ?? store.style
                // Seed the compare selection from the server (profile.styles is the source of truth).
                if !store.serverStyles.isEmpty { prefs.styles = store.serverStyles; prefs.multiStyle = true }
            }
        }
    }

    private var versionBar: some View {
        Button { withAnimation(.easeOut(duration: 0.15)) { showVersions.toggle() } } label: {
            HStack(spacing: 10) {
                if compareOn {
                    HStack(spacing: 6) {
                        Image(systemName: "rectangle.split.2x1").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                        Text("对比").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                        Image(systemName: showVersions ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 6))
                    Text(selectedVersions.isEmpty ? "未选版本" : "已选 " + selectedVersions.map { "v\($0)" }.joined(separator: "、"))
                        .font(.system(size: 13)).foregroundStyle(Theme.secondary).lineLimit(1)
                    Spacer(minLength: 8)
                    Text("\(prefs.styles.count) / 3").font(.system(size: 13)).foregroundStyle(Theme.faint)
                } else {
                    HStack(spacing: 6) {
                        Text("v\(currentV)").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                            .lineLimit(1).fixedSize(horizontal: true, vertical: false)   // 「v10」不折行
                        Image(systemName: showVersions ? "chevron.up" : "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Theme.ink, in: RoundedRectangle(cornerRadius: 6))
                    Text(StyleNaming.name(store.style)).font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.ink).lineLimit(1)
                    Text("\(store.style.count) 字").font(.system(size: 13)).foregroundStyle(Theme.secondary).layoutPriority(1)
                    if let d = currentDate {
                        Circle().fill(Theme.chevron).frame(width: 3, height: 3)
                        Text(DateFormatter.zh("M月d日 HH:mm").string(from: d)).font(.system(size: 13)).foregroundStyle(Theme.secondary)
                    }
                    Spacer(minLength: 8)
                    Text("共 \(store.styleVersions.count) 版").font(.system(size: 13)).foregroundStyle(Theme.faint)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke((showVersions || compareOn) ? Theme.ink : Theme.inputBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var versionDropdown: some View {
        VStack(spacing: 0) {
            // 多风格对比 开关
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("多风格对比").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
                    Text("勾选多个版本，成文时各生成一篇并排挑").font(.system(size: 12)).foregroundStyle(Theme.faint)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: Binding(get: { prefs.multiStyle }, set: { on in
                    prefs.multiStyle = on
                    if !on { prefs.styles = []; Task { await store.saveStyles([]) } }   // 关 → 清空 profile.styles，miner 回到单篇
                })).labelsHidden().tint(Theme.accent)
            }
            .padding(.horizontal, 15).padding(.vertical, 11).background(Theme.appBG)
            Rectangle().fill(Theme.dividerInCard).frame(height: 1)

            ForEach(Array(versionsDesc.enumerated()), id: \.element.id) { i, ver in
                let sel = compareOn ? prefs.styles.contains(ver.v) : (ver.v == currentV)
                Button {
                    if compareOn { toggleCompareSelect(ver.v) }
                    else {
                        store.style = ver.style; selectedV = ver.v
                        withAnimation(.easeOut(duration: 0.15)) { showVersions = false }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Text("v\(ver.v)").font(.system(size: 15, weight: .bold))
                            .foregroundStyle(sel ? Theme.accent : Theme.ink).frame(width: 40, alignment: .leading)
                        Text(ver.displayName).font(.system(size: 14, weight: sel ? .semibold : .regular))
                            .foregroundStyle(sel ? Theme.accent : Theme.ink).lineLimit(1)
                        Spacer(minLength: 8)
                        Text("\(ver.charCount) 字 · \(DateFormatter.zh("M月d日").string(from: ver.date))")
                            .font(.system(size: 12)).foregroundStyle(Theme.faint).lineLimit(1)
                        if compareOn {
                            RoundedRectangle(cornerRadius: 5).fill(sel ? Theme.accent : Color.clear).frame(width: 20, height: 20)
                                .overlay(RoundedRectangle(cornerRadius: 5).stroke(sel ? Theme.accent : Theme.inputBorder, lineWidth: 1.5))
                                .overlay(sel ? Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white) : nil)
                        } else if sel {
                            Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.accent)
                        }
                    }
                    .padding(.horizontal, 15).padding(.vertical, 12)
                    .background(sel ? Theme.accentSoft : Theme.card)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if i < versionsDesc.count - 1 { Rectangle().fill(Theme.dividerInCard).frame(height: 1) }
            }

            if compareOn {
                Rectangle().fill(Theme.dividerInCard).frame(height: 1)
                Text(compareFooter).font(.system(size: 12)).foregroundStyle(Theme.faint).lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 15).padding(.vertical, 11).background(Theme.appBG)
            }
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.inputBorder, lineWidth: 1))
        .shadow(color: .black.opacity(0.12), radius: 14, y: 8)
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
