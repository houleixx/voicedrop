import Foundation
import StoreKit

/// 苹果自动续期订阅（¥19.9/月 → 每月 200 算力）。StoreKit 2。
///
/// 到账链路是双保险：App Store 服务器通知（服务端 /agent/iap/notifications）是主路，
/// 这里的 claim（购买回调 + Transaction.updates + 启动时 currentEntitlements 逐笔回传）
/// 是兜底路——服务端按 transaction_id 幂等，重复 claim 不会重复发钱。
@MainActor
final class StoreService: ObservableObject {
    static let shared = StoreService()
    static let monthlyID = "com.wangjianshuo.VoiceDrop.sub.monthly"

    @Published var product: Product?
    @Published var active = false
    @Published var expiresDate: Date?
    @Published var purchasing = false
    @Published var lastError: String?

    private var updatesTask: Task<Void, Never>?

    /// App 启动时调一次：挂 Transaction.updates 监听（续费/别台设备购买都从这来），
    /// 并把当前有效订阅逐笔 claim 一遍（服务端幂等，漏发的月份在这里补上）。
    func start() {
        guard updatesTask == nil else { return }
        updatesTask = Task {
            for await update in Transaction.updates {
                await handle(update)
            }
        }
        Task { await refresh() }
    }

    func refresh() async {
        if product == nil {
            product = try? await Product.products(for: [Self.monthlyID]).first
        }
        await syncEntitlements()
        await loadStatus()
    }

    func purchase() async {
        guard !purchasing else { return }
        purchasing = true
        lastError = nil
        defer { purchasing = false }
        do {
            if product == nil {
                product = try await Product.products(for: [Self.monthlyID]).first
            }
            guard let product else {
                lastError = String(localized: "商品加载失败，请稍后再试"); return
            }
            switch try await product.purchase() {
            case .success(let verification):
                if case .verified(let txn) = verification {
                    await claim(txn)
                    await txn.finish()
                    Analytics.capture("订阅购买完成")
                }
            case .userCancelled:
                break
            case .pending:
                lastError = String(localized: "购买待确认，完成后算力自动到账")
            @unknown default:
                break
            }
        } catch {
            lastError = String(localized: "购买失败，请稍后再试")
        }
        await loadStatus()
    }

    /// 「恢复购买」：换机/重装后把 Apple ID 名下的订阅同步回来再逐笔 claim。
    func restore() async {
        try? await AppStore.sync()
        await syncEntitlements()
        await loadStatus()
    }

    private func syncEntitlements() async {
        for await result in Transaction.currentEntitlements {
            if case .verified(let txn) = result, txn.productID == Self.monthlyID {
                await claim(txn)
            }
        }
    }

    private func handle(_ result: VerificationResult<Transaction>) async {
        guard case .verified(let txn) = result, txn.productID == Self.monthlyID else { return }
        await claim(txn)
        await txn.finish()
        await loadStatus()
    }

    private struct ClaimResp: Decodable { let ok: Bool?; let granted: Bool?; let suanli: Int? }

    private func claim(_ txn: Transaction) async {
        var req = URLRequest(url: API.agentBase.appending(path: "iap/claim"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setBearer(AuthStore.shared.bearer)
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["transaction_id": String(txn.id)])
        guard let (data, resp) = try? await URLSession.shared.data(for: req), resp.isOK,
              let r = try? JSONDecoder().decode(ClaimResp.self, from: data) else { return }
        if r.granted == true { Analytics.capture("订阅算力到账", ["算力": r.suanli ?? 0]) }
    }

    private struct Status: Decodable { let active: Bool; let expires_date: Int? }

    func loadStatus() async {
        var req = URLRequest(url: API.agentBase.appending(path: "iap/status"))
        req.setBearer(AuthStore.shared.bearer)
        guard let (data, resp) = try? await URLSession.shared.data(for: req), resp.isOK,
              let s = try? JSONDecoder().decode(Status.self, from: data) else { return }
        active = s.active
        expiresDate = s.expires_date.map { Date(timeIntervalSince1970: Double($0) / 1000) }
    }
}
