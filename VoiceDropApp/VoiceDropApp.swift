import SwiftUI

@main
struct VoiceDropApp: App {
    @StateObject private var router = AppRouter.shared   // shared so App Intents (开始录音) can reach it

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(router)
                .onOpenURL { router.handle($0) }   // voicedrop://<page> — see AppRouter/DeepLink
        }
    }
}
