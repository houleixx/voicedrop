import SwiftUI

@main
struct VoiceDropApp: App {
    @StateObject private var router = AppRouter.shared   // shared so App Intents (开始录音) can reach it
    // APNs 注册 + device token 上传（「文章已生成」推送 / 运维报警都靠它）。
    @UIApplicationDelegateAdaptor(PushRegistrar.self) private var pushRegistrar

    init() { Analytics.setup() }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(router)
                // 订阅：挂 Transaction.updates 监听 + 把当前有效订阅逐笔 claim
                // （服务端幂等）——续费到账不依赖用户打开算力页。
                .task { StoreService.shared.start() }
                .onOpenURL { router.handle($0) }   // voicedrop://<page> + universal links — see AppRouter/DeepLink
                #if DEBUG
                // Simulator screenshot rig: SIMCTL_CHILD_VD_OPEN_URL=voicedrop://…
                // navigates in-app on launch, skipping the SpringBoard openurl
                // confirmation dialog simctl can't tap. DEBUG-only.
                .task {
                    if let s = ProcessInfo.processInfo.environment["VD_OPEN_URL"],
                       let u = URL(string: s) {
                        try? await Task.sleep(for: .seconds(12))
                        router.handle(u)
                    }
                }
                #endif
                // Universal links (https://voicedrop.cn/…) arrive as an NSUserActivity;
                // some iOS versions deliver ONLY here, not via onOpenURL. Same handler.
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    if let url = activity.webpageURL { router.handle(url) }
                }
        }
    }
}
