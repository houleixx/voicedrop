import Foundation
import UIKit
import DeviceCheck
import os

/// 邀请归因（安装后 24h 内，服务端 first-touch 终身一次）：
///   1. universal link 带分享 id 到达 → 立即 claim（source=link，确定归因）
///   2. 首启 hello → 服务端用 IP 指纹静默匹配落地页访问记录（source=hello）
///   3. 都没中 → detectedPatterns 静默探测剪贴板，疑似有 URL 才真正读取（此时才
///      触发系统粘贴提示）→ 解析出分享链接 → claim（source=clipboard）
/// 本地 done 标记只挡重复网络请求；真正的幂等在服务端（mint 唯一索引 + DeviceCheck）。
/// 服务端契约见 voicedrop repo docs/superpowers/specs/2026-07-09-referral-rewards-design.md。
/// 日志：subsystem app.voicedrop / category referral —— Xcode console 直接可见，
/// 模拟器排查时每个分叉点都有一条（guard 拦截 / hello 结果 / 剪贴板探测 / claim 响应）。
@MainActor
final class ReferralManager {
    static let shared = ReferralManager()
    private static let log = Logger(subsystem: "app.voicedrop", category: "referral")
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
        Self.log.info("noteShareToken: 收到分享 id=\(id, privacy: .public) done=\(self.done) withinWindow=\(self.withinWindow)")
        guard !done, withinWindow else {
            Self.log.info("noteShareToken: 跳过（\(self.done ? "已终局 done=true" : "超出首启 24h 窗口", privacy: .public)）")
            return
        }
        Task { await claim(source: "link", token: id) }
    }

    /// 首启序列：hello（IP 静默）→ 未中再剪贴板兜底。RootView 出现时调一次。
    func runOnLaunch() {
        let ageH = (Date().timeIntervalSince1970 - UserDefaults.standard.double(forKey: firstLaunchKey)) / 3600
        Self.log.info("runOnLaunch: done=\(self.done) withinWindow=\(self.withinWindow)（首启距今 \(String(format: "%.1f", ageH), privacy: .public)h）running=\(self.running)")
        guard !done, withinWindow, !running else {
            Self.log.info("runOnLaunch: 跳过（\(self.done ? "已终局 done=true——重测请抹掉模拟器" : self.running ? "已在跑" : "超出首启 24h 窗口", privacy: .public)）")
            return
        }
        running = true
        Task {
            defer { running = false }
            Self.log.info("runOnLaunch: 第 1 层 hello（IP 指纹）开始…")
            if await claim(source: "hello", token: nil) { Self.log.info("runOnLaunch: hello 归因成功，结束"); return }
            guard !done else {   // hello 可能已终局否定（not-new 等）
                Self.log.info("runOnLaunch: hello 被服务端终局否定（见上一条日志的 reason），不再探测剪贴板")
                return
            }
            Self.log.info("runOnLaunch: hello 未命中 → 第 3 层剪贴板兜底…")
            await clipboardFallback()
        }
    }

    /// 剪贴板兜底：先无感探测（不弹提示），疑似有 URL 才真正读取（读取才弹系统粘贴条）。
    private func clipboardFallback() async {
        let pb = UIPasteboard.general
        guard pb.hasStrings else {
            Self.log.info("clipboard: 剪贴板没有文本（hasStrings=false）——模拟器请先 simctl pbcopy 再启动")
            return
        }
        guard let patterns = try? await pb.detectedPatterns(for: [\.probableWebURL]) else {
            Self.log.error("clipboard: detectedPatterns 探测失败")
            return
        }
        guard patterns.contains(\.probableWebURL) else {
            Self.log.info("clipboard: 有文本但不像 URL（probableWebURL 未命中），不读取、不弹粘贴提示")
            return
        }
        Self.log.info("clipboard: 疑似 URL → 真正读取（此刻应弹「允许粘贴」系统提示）")
        guard let text = pb.string else {
            Self.log.info("clipboard: 读取被拒或为空（用户点了不允许？）")
            return
        }
        guard let id = Self.shareToken(in: text) else {
            Self.log.info("clipboard: 文本里解析不出分享 id（只认 voicedrop.cn/<id> 或 jianshuo.dev/voicedrop/<id>）：\(String(text.prefix(80)), privacy: .public)")
            return
        }
        Self.log.info("clipboard: 解析出分享 id=\(id, privacy: .public) → claim")
        await claim(source: "clipboard", token: id)
    }

    /// 从任意文本里挖分享短链 id 或邀请码：voicedrop.cn/i/<码>、voicedrop.cn/<id>
    /// 或 jianshuo.dev/voicedrop[/i]/<id>。邀请码模式在前（更窄先判）。
    static func shareToken(in text: String) -> String? {
        let pats = [
            #"voicedrop\.cn/i/([A-Za-z0-9]{6,16})"#,
            #"jianshuo\.dev/voicedrop/i/([A-Za-z0-9]{6,16})"#,
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
        guard !bearer.isEmpty else {
            Self.log.error("claim(\(source, privacy: .public)): bearer 为空——匿名身份还没建好，本次放弃（不置 done，下次启动重试）")
            return false
        }
        var body: [String: Any] = ["source": source]
        if let token { body["token"] = token }
        if let dc = await Self.deviceCheckToken() {
            body["deviceCheckToken"] = dc
            Self.log.info("claim(\(source, privacy: .public)): 带 DeviceCheck token")
        } else {
            Self.log.info("claim(\(source, privacy: .public)): 无 DeviceCheck token（模拟器 isSupported=false 属正常）")
        }
        Self.log.info("claim(\(source, privacy: .public)): POST referral/claim token=\(token ?? "nil", privacy: .public)")
        var req = URLRequest(url: API.agentBase.appending(path: "referral/claim"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, resp) = try? await URLSession.shared.data(for: req) else {
            Self.log.error("claim(\(source, privacy: .public)): 网络请求失败（不置 done，下次启动重试）")
            return false
        }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
        let bodyText = String(data: data, encoding: .utf8) ?? ""
        Self.log.info("claim(\(source, privacy: .public)): HTTP \(status) 响应=\(String(bodyText.prefix(200)), privacy: .public)")
        guard status == 200,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        let attributed = j["attributed"] as? Bool ?? false
        if attributed {
            done = true
            Self.log.info("claim(\(source, privacy: .public)): ✅ 归因成功，done=true")
            Analytics.capture("邀请归因成功", ["层": source])
            if let s = j["suanli"] as? [String: Any], let you = s["you"] as? Double, you > 0 {
                Self.log.info("claim: 新人侧入账 \(you, privacy: .public) 算力")
                NotificationCenter.default.post(name: .referralRewarded, object: nil,
                                                userInfo: ["suanli": you])
            }
        }
        // 明确的终局否定也停手，别每次启动都骚扰服务端。
        if let reason = j["reason"] as? String,
           ["not-new", "device-used", "disabled"].contains(reason) {
            done = true
            Self.log.info("claim(\(source, privacy: .public)): 服务端终局否定 reason=\(reason, privacy: .public) → done=true（重测请抹掉模拟器：删 App 不清 Keychain 里的匿名身份）")
        }
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
