import SwiftUI

// MARK: - Color(hex:)

// The Share Extension target does not compile `VoiceDropApp/Theme.swift` (kept
// intentionally light — no AVFoundation/Prefs baggage in the extension), so it
// gets its own tiny hex helper + the handful of design tokens the sheets need.
// Same "暖纸 · Warm Paper" values as the app (`Theme.appBG` / `Theme.ink`).
extension Color {
    init(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        var int: UInt64 = 0
        Scanner(string: h).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xff) / 255
        let g = Double((int >> 8) & 0xff) / 255
        let b = Double(int & 0xff) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}

enum ShareTheme {
    static let sheetBG = Color(hex: "FAF6EF")
    static let ink = Color(hex: "2A2521")
    static let secondary = Color(hex: "8A8175")
    static let border = Color(hex: "ECE3D5")
    static let accent = Color(hex: "D8593B")
}

// MARK: - ShareRootView

/// The Share Extension's whole UI: routes by `ShareKind` to one of three
/// compose sheets over a dimmed scrim, gated on being signed in and on the
/// attachments having finished loading. Replaces `SLComposeServiceViewController`.
struct ShareRootView: View {
    let items: [NSExtensionItem]
    let kind: ShareKind
    let close: () -> Void
    /// Called instead of `close` after a successful 生成文章 on the audio/image
    /// sheets — completes the extension AND opens the host app to 我的录音.
    var openApp: () -> Void = {}
    @State private var payload: SharePayload?

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.18).ignoresSafeArea().onTapGesture(perform: close)
            Group {
                if AppGroup.sharedBearer.isEmpty {
                    NotLoggedInSheet(close: close)
                } else if let p = payload {
                    switch kind {
                    case .audio:
                        AudioComposeView(payload: p, close: close, openApp: openApp)
                    case .image:
                        PhotoComposeView(payload: p, close: close, openApp: openApp)
                    default:
                        StyleDatasetView(payload: p, close: close, openApp: openApp)   // web/document/text
                    }
                } else {
                    LoadingSheet()
                }
            }
        }
        .task { payload = await ShareRouter.loadPayload(items) }
    }
}

// MARK: - Small placeholder sheets owned by this task

/// Shown when the app has never run (no mirrored bearer token in the App
/// Group) — the extension has nothing to upload as.
struct NotLoggedInSheet: View {
    let close: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("请先打开一次 VoiceDrop")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(ShareTheme.ink)
            Text("还没有登录，先打开 App 完成一次登录，再回来分享。")
                .font(.system(size: 14))
                .foregroundStyle(ShareTheme.secondary)
                .multilineTextAlignment(.center)
            Button("关闭", action: close)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(ShareTheme.accent, in: RoundedRectangle(cornerRadius: 10))
        }
        .padding(20)
        .padding(.bottom, 8)
        .background(ShareTheme.sheetBG)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(ShareTheme.border, lineWidth: 1))
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }
}

/// Shown briefly while `ShareRouter.loadPayload` is still copying attachments
/// out of the sharing app's sandbox.
struct LoadingSheet: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("正在读取分享内容…")
                .font(.system(size: 14))
                .foregroundStyle(ShareTheme.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .background(ShareTheme.sheetBG)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(ShareTheme.border, lineWidth: 1))
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }
}
