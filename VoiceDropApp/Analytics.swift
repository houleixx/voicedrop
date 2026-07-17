import Foundation
import PostHog

/// PostHog 产品分析。key 经 Secrets.xcconfig → Info.plist 注入；
/// 拿不到 key（本地没配 / CI secret 缺失）就整体不启用，App 行为不变。
///
/// 隐私红线（隐私政策已对外承诺）：只送行为元数据（事件名/类型/时长/计数），
/// 任何用户内容——录音、转写、文章正文、指令文本——一律不进 PostHog。
enum Analytics {
    static func setup() {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "PostHogAPIKey") as? String,
              key.hasPrefix("phc_") else { return }
        let config = PostHogConfig(apiKey: key, host: "https://us.i.posthog.com")
        // Session replay（截屏式录屏，用于定位 rageclick 等 UX 卡点）。
        // 隐私红线的延伸约定：遮罩全开——文本输入、图片一律打码；
        // SwiftUI 是截屏模式，屏上静态文本（转写/文章）仍可能入镜，
        // 内容型视图需在视图侧加 .postHogMask()（见 ArticleView/TranscriptView）。
        config.sessionReplay = true
        config.sessionReplayConfig.screenshotMode = true      // SwiftUI 必须
        config.sessionReplayConfig.maskAllTextInputs = true
        config.sessionReplayConfig.maskAllImages = true
        #if DEBUG
        config.debug = true   // Xcode console 打印每条事件的捕获/上送日志
        #endif
        PostHogSDK.shared.setup(config)
    }

    /// 把匿名设备事件并到账号名下。sub = /whoami 的数据主体标识
    /// （Apple sub 派生的随机串，非姓名/邮箱）。重复调用同一 sub 无副作用。
    static func identify(_ sub: String) {
        guard !sub.isEmpty else { return }
        PostHogSDK.shared.identify(sub)
    }

    /// 退出登录时切断关联，防止换账号后事件串人。
    static func reset() { PostHogSDK.shared.reset() }

    /// 统一入口：事件名用中文（PostHog 完全支持），属性只放元数据。
    static func capture(_ event: String, _ props: [String: Any] = [:]) {
        PostHogSDK.shared.capture(event, properties: props)
    }

    /// 当前上下文（super properties）：注册后随之后的每条事件自动上送，
    /// 让任何动作都能回答「用户当时在哪个界面、看哪条录音」；同时记一条
    /// 「界面进入」事件形成完整动线。红线同上：界面名是代码里的固定字符串、
    /// stem 是时间戳式文件名，均不含用户内容。
    static func screen(_ name: String, stem: String? = nil) {
        if let stem {
            PostHogSDK.shared.register(["当前界面": name, "当前录音": stem])
        } else {
            PostHogSDK.shared.unregister("当前录音")
            PostHogSDK.shared.register(["当前界面": name])
        }
        capture("界面进入", ["界面": name])
    }
}
