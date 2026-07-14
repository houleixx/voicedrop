import SwiftUI
import Observation
import AVFoundation

// MARK: - Color(hex:)

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

// MARK: - Design tokens ("暖纸 · Warm Paper（硬朗）")

enum Theme {
    // Backgrounds
    static let appBG          = Color(hex: "FAF6EF")   // 录音 / 列表 / 设置 chrome
    static let readBG         = Color(hex: "F0EDE7")   // 成文阅读专用暖灰
    static let card           = Color.white

    // Borders / dividers
    static let borderChrome   = Color(hex: "ECE3D5")
    static let borderRead     = Color(hex: "E5DFD5")
    static let dividerInCard  = Color(hex: "F0E8DA")
    static let inputBorder    = Color(hex: "E2D8C8")   // 1.5px

    // Text
    static let ink            = Color(hex: "2A2521")   // 标题（米色底）
    static let inkRead        = Color(hex: "2B2823")   // 标题（暖灰底）
    static let bodyInk        = Color(hex: "4A443C")   // 正文（米色）
    static let bodyRead       = Color(hex: "494339")   // 正文（暖灰）
    static let secondary      = Color(hex: "8A8175")
    static let faint          = Color(hex: "B8AE9E")
    static let metaChrome     = Color(hex: "A89E8E")
    static let metaRead       = Color(hex: "9A9387")
    static let sectionLabel   = Color(hex: "A79F93")
    static let chevron        = Color(hex: "CFC6B6")

    // Accent / status
    static let accent         = Color(hex: "D8593B")   // 赭红（发布 / chip / 设置）
    static let accentSoft     = Color(hex: "F6E4DC")
    static let recordRed      = Color(hex: "E5392E")   // 纯红：录音键 / 声波 / 列表波形
    static let recordRedSoft  = Color(hex: "FBEAE7")   // 列表波形块底
    static let greenDone      = Color(hex: "5E8A6A")
    static let amberPending   = Color(hex: "C98A3C")
    static let amber          = Color(hex: "C98A2E")   // 算力（lightning / 数字）
    static let amberSoft      = Color(hex: "FBEAD2")   // 算力 tile / chip 底
    static let inkHeroTop     = Color(hex: "2A2521")   // 算力余额 hero 渐变
    static let inkHeroBot     = Color(hex: "3A332A")

    // WeChat connected banner
    static let okBannerBG     = Color(hex: "EAF1EC")
    static let okBannerBorder = Color(hex: "D5E3D9")
    static let okBannerTitle  = Color(hex: "3C5A47")
    static let okBannerSub    = Color(hex: "6E8576")

    // Icon tiles
    static let tileNeutral    = Color(hex: "F1ECE3")
    static let inkTile        = Color(hex: "2A2521")
    static let tileWarm       = Color(hex: "F6EFE3")   // waveform tile bg

    // 追问（follow-up questions）— 琥珀身份色系，设计稿 design_handoff_follow_up_questions
    static let fuCardBG       = Color(hex: "FAF7F1")   // 卡片底
    static let fuBorder       = Color(hex: "E5DCCB")   // 卡片边框 / 未答进度段
    static let fuHandle       = Color(hex: "DDD5C7")   // 拖动把手
    static let fuAmber        = Color(hex: "D8A25B")   // 「追问 N/M」标签
    static let fuStarStroke   = Color(hex: "B98A3E")   // 星标线条
    static let fuStarBorder   = Color(hex: "EBD9B8")   // 星标按钮琥珀边框
    static let fuGreen        = Color(hex: "5B8A63")   // 已答进度段 / 确认行
    static let fuHighlight    = Color(hex: "D8A25B").opacity(0.28)   // 正文荧光笔

    // Radii
    enum R {
        static let card: CGFloat = 5
        static let player: CGFloat = 6
        static let chip: CGFloat = 4
        static let input: CGFloat = 4
        static let nav: CGFloat = 10
        static let recordOuter: CGFloat = 10
        static let recordInner: CGFloat = 6
        static let primary: CGFloat = 8
        static let tile: CGFloat = 8
        /// Prompt Manager 编辑态（第 6 轮拖拽）行内图标块专属半径——正常态仍用 `tile`(8)；
        /// 编辑态顶层行（30×30）用 7、组内子行（26×26）用 6，对齐设计稿，见
        /// PromptManagerView 的 editGroupRow/editActionRow/editChildRow。
        static let promptEditTile: CGFloat = 7
        static let promptEditChildTile: CGFloat = 6
    }
}

// MARK: - Shadows (CSS blur ≈ SwiftUI radius / 2)

extension View {
    func cardChromeShadow() -> some View {
        shadow(color: Color(.sRGB, red: 180/255, green: 140/255, blue: 100/255, opacity: 0.09), radius: 4, x: 0, y: 2)
    }
    func cardReadShadow() -> some View {
        shadow(color: Color(.sRGB, red: 120/255, green: 110/255, blue: 90/255, opacity: 0.07), radius: 4, x: 0, y: 2)
    }
    func navButtonShadow() -> some View {
        shadow(color: .black.opacity(0.04), radius: 3, x: 0, y: 2)
    }
    func accentButtonShadow() -> some View {
        shadow(color: Color(.sRGB, red: 216/255, green: 89/255, blue: 59/255, opacity: 0.28), radius: 6, x: 0, y: 4)
    }
}

// MARK: - Reusable bits

/// Five ochre rounded bars — the VoiceDrop motif (brand mark, list tile).
struct WaveformBars: View {
    var color: Color = Theme.accent
    var heights: [CGFloat] = [11, 20, 26, 16, 9]
    var barWidth: CGFloat = 3
    var spacing: CGFloat = 2.5

    var body: some View {
        HStack(alignment: .center, spacing: spacing) {
            ForEach(Array(heights.enumerated()), id: \.offset) { _, h in
                RoundedRectangle(cornerRadius: barWidth / 2)
                    .fill(color)
                    .frame(width: barWidth, height: h)
            }
        }
    }
}

/// A 38×38 (configurable) white rounded-square chrome button (back, gear, share).
struct NavSquare: View {
    var systemName: String
    var size: CGFloat = 38
    var stroke: Color = Color(hex: "6F685D")
    var border: Color = Theme.borderChrome
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: Theme.R.nav)
                .fill(Theme.card)
                .overlay(RoundedRectangle(cornerRadius: Theme.R.nav).stroke(border, lineWidth: 1))
                .overlay(Image(systemName: systemName).font(.system(size: size * 0.42, weight: .regular)).foregroundStyle(stroke))
                .frame(width: size, height: size)
                .navButtonShadow()
        }
        .buttonStyle(.plain)
    }
}

// MARK: - User preferences (wired to real behavior)

/// Lightweight UserDefaults-backed prefs surfaced in Settings. These do change
/// behavior (the one deliberate logic touch): iCloud backup, keep-local-after-
/// upload, and recording quality.
@MainActor
@Observable
final class Prefs {
    static let shared = Prefs()
    private let d = UserDefaults.standard

    var iCloudBackup: Bool { didSet { d.set(iCloudBackup, forKey: "pref.iCloudBackup") } }
    var deleteLocalAfterUpload: Bool { didSet { d.set(deleteLocalAfterUpload, forKey: "pref.deleteLocal") } }
    var highQuality: Bool { didSet { d.set(highQuality, forKey: "pref.highQuality") } }
    /// 逃生门：录音统一切到 AVAudioEngine 后端（支持随时开 AI 采访旁路）后，
    /// 万一 engine 路径在某些设备/路由上出问题，打开此开关回到久经考验的
    /// AVAudioRecorder 经典路径（无 AI 采访）。稳定一两个版本后可删。
    var classicRecorder: Bool { didSet { d.set(classicRecorder, forKey: "pref.classicRecorder") } }

    // 多风格对比：multiStyle = 开关（本地 UI）；styles = 选中的文风版本号（最多 3 个，
    // 同步进 profile.styles 供 miner 读）。
    var multiStyle: Bool { didSet { d.set(multiStyle, forKey: "pref.multiStyle") } }
    var styles: [Int] { didSet { d.set(styles, forKey: "pref.styles") } }

    private init() {
        iCloudBackup = d.object(forKey: "pref.iCloudBackup") as? Bool ?? true
        deleteLocalAfterUpload = d.object(forKey: "pref.deleteLocal") as? Bool ?? true
        highQuality = d.object(forKey: "pref.highQuality") as? Bool ?? false
        classicRecorder = d.object(forKey: "pref.classicRecorder") as? Bool ?? false
        multiStyle = d.object(forKey: "pref.multiStyle") as? Bool ?? false
        styles = (d.array(forKey: "pref.styles") as? [Int]) ?? []
    }

    /// AVAudioRecorder settings, tuned for SPEECH → ASR (not music). The audio is only
    /// ever (a) played back in-app and (b) fed to Volcano ASR, which works at 16 kHz —
    /// so the old 44.1 kHz / 64 kbps was pure waste (the encoder spent bits on a band
    /// nothing consumes). 16 kHz mono + a low AAC bitrate **halves the file and the
    /// upload time** with no loss of ASR accuracy. 标准 = 16 kHz / 32 kbps (≈1.2 MB per
    /// 5 min, was ~2.4 MB); 高 = 24 kHz / 64 kbps for fuller playback (≈2.4 MB, was ~3.6 MB).
    nonisolated var recorderSettings: [String: Any] {
        let high = UserDefaults.standard.object(forKey: "pref.highQuality") as? Bool ?? false
        return [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: high ? 24_000 : 16_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: (high ? AVAudioQuality.high : .medium).rawValue,
            AVEncoderBitRateKey: high ? 64_000 : 32_000,
        ]
    }

    var qualityLabel: String { highQuality ? String(localized: "高 · AAC") : String(localized: "标准 · AAC") }

    /// "1.0 (42)" — marketing version + build number for the Settings 版本 row.
    static var versionBuild: String {
        let v = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
        let b = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "1"
        return "\(v) (\(b))"
    }
}
