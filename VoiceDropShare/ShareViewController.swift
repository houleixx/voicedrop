import UIKit
import SwiftUI

/// The system share-sheet entry point. Accepts links / text / images / files
/// shared from any app (WeChat article links, Safari pages, Files documents,
/// Photos) and hands off to a custom SwiftUI UI (`ShareRootView`) hosted in a
/// plain `UIHostingController` — no more `SLComposeServiceViewController`
/// single-row 用途 picker. `ShareRouter.classify` decides which of the three
/// sheets (音频 / 图片 / 风格语料) to show; the sheet itself drives the upload.
final class ShareViewController: UIViewController {

    /// completeRequest must run exactly once — a second call crashes the extension.
    private var didFinish = false

    override func viewDidLoad() {
        super.viewDidLoad()
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let kind = ShareRouter.classify(items)

        let root = ShareRootView(
            items: items,
            kind: kind,
            close: { [weak self] in self?.finish() },
            openApp: { [weak self] in self?.openHostApp() }
        )
        let host = UIHostingController(rootView: root)
        host.view.backgroundColor = .clear
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
    }

    /// Dismiss the share sheet. Idempotent — safe to call from every path.
    private func finish() {
        guard !didFinish else { return }
        didFinish = true
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }

    /// After 生成文章 / 提取风格, foreground the host app to 我的录音 so the user can
    /// watch mining progress. A share extension can't use `UIApplication.shared`, and
    /// `NSExtensionContext.open` is officially only honored for Today (widget) extensions —
    /// for share extensions it silently no-ops on most iOS versions (why the old build
    /// never actually opened the app). So we best-effort THREE paths and let whichever the
    /// running iOS allows win, then always close the sheet:
    ///   1. Walk the responder chain for an object that still responds to `openURL:`
    ///      (that's a live UIApplication) — the standard share-extension workaround.
    ///   2. Reach UIApplication via the `sharedApplication` selector (unavailable to call
    ///      directly, reachable by selector) and send it `openURL:`.
    ///   3. `NSExtensionContext.open` — the official API, kept as a last resort.
    private func openHostApp() {
        guard let url = URL(string: "voicedrop://recordings") else { finish(); return }

        // 1 + 2: legacy openURL: on whatever UIApplication we can reach.
        let openSel = NSSelectorFromString("openURL:")
        var responder: UIResponder? = self
        var sentViaResponder = false
        while let r = responder {
            if r.responds(to: openSel) {
                r.perform(openSel, with: url)
                sentViaResponder = true
                break
            }
            responder = r.next
        }
        if !sentViaResponder,
           let appClass = NSClassFromString("UIApplication") as AnyObject as? NSObjectProtocol {
            let sharedSel = NSSelectorFromString("sharedApplication")
            if appClass.responds(to: sharedSel),
               let app = appClass.perform(sharedSel)?.takeUnretainedValue() as? NSObjectProtocol,
               app.responds(to: openSel) {
                app.perform(openSel, with: url)
            }
        }

        // 3: official path (Today-only in practice, harmless elsewhere), then close.
        extensionContext?.open(url) { [weak self] _ in self?.finish() }
        // Safety net: if open()'s completion never fires on this iOS version, still close
        // so the sheet can never hang half-open.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.finish() }
    }
}
