import SwiftUI

/// List-first navigation (方案二): 我的录音 is the root. Settings pushes from the
/// gear; the red record key opens a full-screen recording takeover. No tab bar.
struct RootView: View {
    @State private var referralToast: Double?

    var body: some View {
        NavigationStack {
            LibraryView()
        }
        .tint(Theme.accent)
        .preferredColorScheme(.light)
        .task { ReferralManager.shared.runOnLaunch() }   // 邀请归因（首启 24h 内才会真跑）
        .onReceive(NotificationCenter.default.publisher(for: .referralRewarded)) { note in
            referralToast = note.userInfo?["suanli"] as? Double
        }
        .alert("朋友的邀请已到账", isPresented: .init(
            get: { referralToast != nil }, set: { if !$0 { referralToast = nil } })) {
            Button("好") { referralToast = nil }
        } message: {
            Text("获得约 \(Int(referralToast ?? 0)) 算力，可在设置 → 算力明细查看。")
        }
    }
}
