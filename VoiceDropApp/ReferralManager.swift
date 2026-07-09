import Foundation
import UIKit
import DeviceCheck

/// 邀请归因（安装后 24h 内，服务端 first-touch 终身一次）：
///   1. universal link 带分享 id 到达 → 立即 claim（source=link，确定归因）
///   2. 首启 hello → 服务端用 IP 指纹静默匹配落地页访问记录（source=hello）
///   3. 都没中 → detectedPatterns 静默探测剪贴板，疑似有 URL 才真正读取（此时才
///      触发系统粘贴提示）→ 解析出分享链接 → claim（source=clipboard）
/// 本地 done 标记只挡重复网络请求；真正的幂等在服务端（mint 唯一索引 + DeviceCheck）。
/// 服务端契约见 voicedrop repo docs/superpowers/specs/2026-07-09-referral-rewards-design.md。
@MainActor
final class ReferralManager {
    static let shared = ReferralManager()
    private let doneKey = "referralClaimDone"
    private let firstLaunchKey = "referralFirstLaunchAt"
    private var running = false

    private var done: Bool {
        get { UserDefaults.standard.bool(forKey: doneKey) }
        set { UserDefaults.standard.set(newValue, forKey: doneKey) }
    }

    /// 本地也限 24h：过窗后不再打服务端（服务端 account.created_at 仍是真判定）。
    private var withinWindow: Bool {
        let d = UserDefaults.standard
        if d.object(forKey: firstLaunchKey) == nil { d.set(Date().timeIntervalSince1970, forKey: firstLaunchKey) }
        return Date().timeIntervalSince1970 - d.double(forKey: firstLaunchKey) < 86400
    }

    /// Universal link 的分享 id 到达（AppRouter 调）。归因是顺手事，绝不影响打开文章。
    func noteShareToken(_ id: String) {
        guard !done, withinWindow else { return }
        Task { await claim(source: "link", token: id) }
    }

    /// 首启序列：hello（IP 静默）→ 未中再剪贴板兜底。RootView 出现时调一次。
    func runOnLaunch() {
        guard !done, withinWindow, !running else { return }
        running = true
        Task {
            defer { running = false }
            if await claim(source: "hello", token: nil) { return }
            guard !done else { return }   // hello 可能已终局否定（not-new 等）
            await clipboardFallback()
        }
    }

    /// 剪贴板兜底：先无感探测（不弹提示），疑似有 URL 才真正读取（读取才弹系统粘贴条）。
    private func clipboardFallback() async {
        let pb = UIPasteboard.general
        guard pb.hasStrings else { return }
        guard let patterns = try? await pb.detectedPatterns(for: [\.probableWebURL]),
              patterns.contains(\.probableWebURL),
              let text = pb.string,
              let id = Self.shareToken(in: text) else { return }
        await claim(source: "clipboard", token: id)
    }

    /// 从任意文本里挖分享短链 id：voicedrop.cn/<id> 或 jianshuo.dev/voicedrop/<id>。
    static func shareToken(in text: String) -> String? {
        let pats = [
            #"jianshuo\.dev/voicedrop/([A-Za-z0-9_-]{6,16})"#,
            #"voicedrop\.cn/([A-Za-z0-9_-]{6,16})"#,
        ]
        for p in pats {
            guard let r = text.range(of: p, options: .regularExpression) else { continue }
            let m = String(text[r])
            if let slash = m.lastIndex(of: "/") {
                let id = String(m[m.index(after: slash)...])
                // 静态页路径不是分享 id，跳过（服务端也会再验，这里少打一次空枪）
                if !["privacy", "welcome", "help"].contains(id) { return id }
            }
        }
        return nil
    }

    @discardableResult
    private func claim(source: String, token: String?) async -> Bool {
        let bearer = AuthStore.shared.bearer
        guard !bearer.isEmpty else { return false }
        var body: [String: Any] = ["source": source]
        if let token { body["token"] = token }
        if let dc = await Self.deviceCheckToken() { body["deviceCheckToken"] = dc }
        var req = URLRequest(url: API.agentBase.appending(path: "referral/claim"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        let attributed = j["attributed"] as? Bool ?? false
        if attributed {
            done = true
            if let s = j["suanli"] as? [String: Any], let you = s["you"] as? Double, you > 0 {
                NotificationCenter.default.post(name: .referralRewarded, object: nil,
                                                userInfo: ["suanli": you])
            }
        }
        // 明确的终局否定也停手，别每次启动都骚扰服务端。
        if let reason = j["reason"] as? String,
           ["not-new", "device-used", "disabled"].contains(reason) { done = true }
        return attributed
    }

    private static func deviceCheckToken() async -> String? {
        guard DCDevice.current.isSupported else { return nil }
        return await withCheckedContinuation { cont in
            DCDevice.current.generateToken { data, _ in
                cont.resume(returning: data?.base64EncodedString())
            }
        }
    }
}

extension Notification.Name {
    static let referralRewarded = Notification.Name("referralRewarded")
}
