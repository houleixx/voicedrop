import SwiftUI

private struct Balance: Decodable { let suanli: Double; let spent_suanli: Double }
private struct LedgerResp: Decodable { let entries: [Entry]; let has_more: Bool?; let next: String? }
private struct Entry: Decodable, Identifiable {
    let id: Int   // ledger 行号（服务端返回，稳定唯一——ts 同毫秒会撞，翻页拼接后不能再当 id）
    let ts: Int; let kind: String; let reason: String; let suanli: Double; let balance_suanli: Double
}
/// /usage/summary 的一组（来源或花费）：服务端全量 ledger 聚合，reason 已是中文。
private struct SummaryRow: Decodable, Identifiable {
    let reason_code: String; let reason: String; let suanli: Double; let count: Int
    var id: String { reason_code + reason }
}
private struct SummaryResp: Decodable { let granted: [SummaryRow]; let spent: [SummaryRow] }

/// 算力 ↔ 篇 estimate — single source so the 设置 list row and this page agree.
/// A mine costs ~9 算力 (see the 明细 −9.1 / −8.4 entries), so 612 ≈ 68 篇.
enum Suanli {
    static let perArticle = 9.0
    static func articles(_ balance: Double) -> Int { max(0, Int((balance / perArticle).rounded(.down))) }
}

// MARK: - 算力 (per Settings.dc.html「算力 · 点开后看明细」)

struct UsageView: View {
    @State private var balance: Double = 0
    @State private var spent: Double = 0
    @State private var entries: [Entry] = []
    @State private var sources: [SummaryRow] = []       // 算力来源（全量聚合）
    @State private var spendSummary: [SummaryRow] = []  // 花费总结（全量聚合）
    @State private var nextCursor: String? = nil        // 明细翻页游标；nil = 没有更早的了
    @State private var loadingMore = false
    @State private var loaded = false
    @State private var showManageSubs = false
    @ObservedObject private var store = StoreService.shared
    private var token: String { AuthStore.shared.bearer }

    /// granted = balance + spent (balance = 累计获赠 − 已用), exact from the two numbers.
    private var granted: Double { balance + spent }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                heroCard
                subscriptionCard
                if !sources.isEmpty {
                    section(String(localized: "算力来源")) { SettingsCard { sourceRows } }
                }
                if !spendSummary.isEmpty {
                    section(String(localized: "花费总结")) { SettingsCard { spendRows } }
                }
                section(String(localized: "明细")) { SettingsCard { ledgerRows } }
            }
            .padding(.horizontal, 16).padding(.top, 10).padding(.bottom, 40)
        }
        .background(Theme.appBG.ignoresSafeArea())
        .navigationTitle("算力")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load(); await store.refresh() }
        .manageSubscriptionsSheet(isPresented: $showManageSubs)
    }

    // MARK: 余额 hero（深色渐变）

    private var heroCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("剩余算力").font(.system(size: 13)).tracking(1).foregroundStyle(Color(hex: "C9BFAE"))
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(Int(balance.rounded()))").font(.system(size: 42, weight: .bold)).foregroundStyle(.white)
                Text("≈ \(Suanli.articles(balance)) 篇").font(.system(size: 14, weight: .semibold)).foregroundStyle(Color(hex: "E2B871"))
            }
            .padding(.top, 6)
            Text(loaded ? String(localized: "累计获赠 \(Int(granted.rounded())) · 已用 \(Int(spent.rounded()))") : String(localized: "加载中…"))
                .font(.system(size: 12.5)).foregroundStyle(Color(hex: "C9BFAE")).padding(.top, 14)
        }
        .padding(.horizontal, 20).padding(.vertical, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LinearGradient(colors: [Theme.inkHeroTop, Theme.inkHeroBot], startPoint: .topLeading, endPoint: .bottomTrailing))
        .overlay(alignment: .topTrailing) {
            Circle()
                .fill(RadialGradient(colors: [Theme.amber.opacity(0.45), .clear], center: .center, startRadius: 0, endRadius: 66))
                .frame(width: 132, height: 132).offset(x: 22, y: -32)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: 包月订阅卡（StoreKit 2，¥19.9/月 → 每月 200 算力）

    private var subscriptionCard: some View {
        VStack(spacing: 13) {
            HStack(spacing: 10) {
                settingsTile(Theme.amberSoft, "bolt.fill", Theme.amber)
                VStack(alignment: .leading, spacing: 2) {
                    Text("包月算力").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                    Text(store.active ? String(localized: "订阅中 · 每月自动充入 200 算力") : String(localized: "每月 200 算力 · 月底清零 · 随时可取消"))
                        .font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
                }
                Spacer(minLength: 8)
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(store.product?.displayPrice ?? "¥19.9").font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.ink)
                    Text("/月").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
            }
            if store.active {
                if let d = store.expiresDate {
                    Text("将于 \(DateFormatter.zh("M月d日").string(from: d)) 续费，可随时取消")
                        .font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Button { showManageSubs = true } label: {
                    Text("管理订阅")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(Theme.amberSoft, in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
            } else {
                Button {
                    Task { await store.purchase(); await load() }
                } label: {
                    HStack(spacing: 8) {
                        if store.purchasing { ProgressView().controlSize(.small).tint(.white) }
                        Text(store.purchasing ? String(localized: "购买中…") : String(localized: "订阅包月算力"))
                    }
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(Theme.amber, in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .disabled(store.purchasing)
                if let err = store.lastError {
                    Text(err).font(.system(size: 12.5)).foregroundStyle(Theme.accent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                subscriptionFootnote
            }
        }
        .padding(16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color(hex: "EBD9B8"), lineWidth: 1))
    }

    /// 审核要求的自动续期披露 + 恢复购买 + 协议/隐私链接。
    private var subscriptionFootnote: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("订阅按月自动续费，到期前 24 小时自动从 Apple ID 扣款，可随时在系统「订阅」设置中取消。")
                .font(.system(size: 11.5)).foregroundStyle(Theme.faint)
            HStack(spacing: 14) {
                Button { Task { await store.restore(); await load() } } label: {
                    Text("恢复购买").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.plain)
                Link(String(localized: "隐私政策"), destination: URL(string: "https://jianshuo.dev/voicedrop/privacy/")!)
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                Link(String(localized: "用户协议"), destination: URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!)
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 算力来源 / 花费总结（/usage/summary 全量聚合——以前在拉到的 50 条明细里
    // 现算来源是错的：注册赠送等老 grant 早被挤出窗口，永远缺项）

    @ViewBuilder private var sourceRows: some View {
        ForEach(Array(sources.enumerated()), id: \.element.id) { i, r in
            summaryRow(r, sign: "+", amountColor: Theme.ink)
            if i < sources.count - 1 { settingsRowDivider }
        }
    }

    @ViewBuilder private var spendRows: some View {
        ForEach(Array(spendSummary.enumerated()), id: \.element.id) { i, r in
            summaryRow(r, sign: "−", amountColor: Theme.accent)
            if i < spendSummary.count - 1 { settingsRowDivider }
        }
    }

    private func summaryRow(_ r: SummaryRow, sign: String, amountColor: Color) -> some View {
        HStack(spacing: 6) {
            Text(r.reason).font(.system(size: 15)).foregroundStyle(Theme.ink)
            if r.count > 1 {
                Text("\(r.count) 笔").font(.system(size: 12)).foregroundStyle(Theme.faint)
            }
            Spacer()
            Text("\(sign)\(Int(r.suanli.rounded()))")
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(amountColor)
        }
        .padding(.vertical, 14).padding(.horizontal, 15)
    }

    // MARK: 明细

    @ViewBuilder private var ledgerRows: some View {
        if entries.isEmpty {
            Text(loaded ? String(localized: "暂无记录") : String(localized: "加载中…"))
                .font(.system(size: 14)).foregroundStyle(Theme.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 16).padding(.horizontal, 15)
        } else {
            ForEach(Array(entries.enumerated()), id: \.element.id) { i, e in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(label(e)).font(.system(size: 15)).foregroundStyle(Theme.ink)
                        Text(timeText(e)).font(.system(size: 12)).foregroundStyle(Theme.faint)
                    }
                    Spacer()
                    Text("\(e.kind == "grant" ? "+" : "−")\(fmt(e.suanli))")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(e.kind == "grant" ? Theme.greenDone : Theme.accent)
                }
                .padding(.vertical, 13).padding(.horizontal, 15)
                if i < entries.count - 1 { settingsRowDivider }
            }
            // 更早的记录：滚到底自动翻页（keyset 游标）；失败时留着按钮可手动重试。
            if nextCursor != nil {
                settingsRowDivider
                Button { Task { await loadMore() } } label: {
                    HStack {
                        Spacer()
                        if loadingMore {
                            ProgressView().controlSize(.small).tint(Theme.secondary)
                        } else {
                            Text("加载更早的记录").font(.system(size: 14)).foregroundStyle(Theme.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 13)
                }
                .buttonStyle(.plain)
                .onAppear { Task { await loadMore() } }
            }
        }
    }

    // MARK: helpers

    @ViewBuilder private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            settingsSectionLabel(title)
            content()
        }
    }

    private func label(_ e: Entry) -> String {
        switch e.reason {
        case "signup": return String(localized: "注册赠送")
        case "asr": return String(localized: "语音转写")
        case "mine": return String(localized: "挖文章")
        case "edit": return String(localized: "语音修改")
        default: return e.reason.hasPrefix("campaign:") ? String(localized: "活动赠送") : e.reason
        }
    }
    private func fmt(_ s: Double) -> String { s < 10 ? String(format: "%.1f", s) : String(Int(s.rounded())) }

    private func timeText(_ e: Entry) -> String {
        // ledger ts is epoch milliseconds (server writes Date.now())
        DateFormatter.zh("yyyy年M月d日 HH:mm").string(from: Date(timeIntervalSince1970: Double(e.ts) / 1000))
    }

    private func load() async {
        async let b: Balance? = fetch("\(API.agentBase.absoluteString)/usage/balance")
        async let s: SummaryResp? = fetch("\(API.agentBase.absoluteString)/usage/summary")
        async let l: LedgerResp? = fetch("\(API.agentBase.absoluteString)/usage/ledger?limit=50")
        if let b = await b { balance = b.suanli; spent = b.spent_suanli }
        if let s = await s { sources = s.granted; spendSummary = s.spent }
        if let l = await l { entries = l.entries; nextCursor = (l.has_more ?? false) ? l.next : nil }
        loaded = true
    }

    private func loadMore() async {
        guard !loadingMore, let cur = nextCursor else { return }
        loadingMore = true
        defer { loadingMore = false }
        guard let l: LedgerResp = await fetch("\(API.agentBase.absoluteString)/usage/ledger?limit=50&before=\(cur)") else { return }
        entries += l.entries
        nextCursor = (l.has_more ?? false) ? l.next : nil
    }
    private func fetch<T: Decodable>(_ urlStr: String) async -> T? {
        guard let url = URL(string: urlStr) else { return nil }
        var req = URLRequest(url: url); req.setBearer(token)
        guard let (data, resp) = try? await URLSession.shared.data(for: req), resp.isOK else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
