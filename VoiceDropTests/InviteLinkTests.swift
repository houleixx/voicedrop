import XCTest
@testable import VoiceDrop

// 邀请好友：邀请链接的两处纯解析——剪贴板兜底（ReferralManager.shareToken）
// 与 universal link 路由（AppRouter.universalLink）。
@MainActor
final class InviteLinkTests: XCTestCase {

    // MARK: - 剪贴板文本 → 归因 token

    func testShareTokenParsesInviteLink() {
        XCTAssertEqual(ReferralManager.shareToken(in: "来 https://voicedrop.cn/i/7F3A9C 下载"), "7F3A9C")
        XCTAssertEqual(ReferralManager.shareToken(in: "https://jianshuo.dev/voicedrop/i/ABCDEF0123"), "ABCDEF0123")
    }

    func testShareTokenStillParsesArticleShareLinks() {
        XCTAssertEqual(ReferralManager.shareToken(in: "https://voicedrop.cn/Ab3xK9_p2Q"), "Ab3xK9_p2Q")
        XCTAssertEqual(ReferralManager.shareToken(in: "https://jianshuo.dev/voicedrop/Ab3xK9_p2Q"), "Ab3xK9_p2Q")
    }

    func testShareTokenIgnoresStaticPathsAndJunk() {
        XCTAssertNil(ReferralManager.shareToken(in: "https://voicedrop.cn/privacy"))
        XCTAssertNil(ReferralManager.shareToken(in: "随便一段没有链接的话"))
    }

    // MARK: - universal link → DeepLink

    func testUniversalLinkInviteRoutes() {
        XCTAssertEqual(AppRouter.universalLink(URL(string: "https://voicedrop.cn/i/7F3A9C")!),
                       .invite(code: "7F3A9C"))
        XCTAssertEqual(AppRouter.universalLink(URL(string: "https://www.voicedrop.cn/i/7F3A9C")!),
                       .invite(code: "7F3A9C"))
        XCTAssertEqual(AppRouter.universalLink(URL(string: "https://jianshuo.dev/voicedrop/i/7F3A9C")!),
                       .invite(code: "7F3A9C"))
    }

    func testUniversalLinkInviteMalformedFallsBackToWeb() {
        // 码太短 / 非法字符 → .web 兜底，不误吞。
        let short = URL(string: "https://voicedrop.cn/i/AB")!
        XCTAssertEqual(AppRouter.universalLink(short), .web(short))
    }

    func testUniversalLinkExistingRoutesUntouched() {
        XCTAssertEqual(AppRouter.universalLink(URL(string: "https://voicedrop.cn/1234567")!),
                       .promptImport(code: "1234567"))
        XCTAssertEqual(AppRouter.universalLink(URL(string: "https://voicedrop.cn/")!), .recordings)
        if case .shareLink(let id, _)? = AppRouter.universalLink(URL(string: "https://voicedrop.cn/Ab3xK9_p2Q")!) {
            XCTAssertEqual(id, "Ab3xK9_p2Q")
        } else {
            XCTFail("share id 应路由到 .shareLink")
        }
    }
}
