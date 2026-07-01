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

        // After 生成文章 / 提取风格 the sheet just closes and returns the user to the source
        // app; the uploaded work mines in the background and the user opens VoiceDrop
        // themselves to watch 我的录音. We deliberately do NOT try to foreground the host
        // app: iOS doesn't allow it reliably from a share extension — NSExtensionContext.open
        // is honored only for Today (widget) extensions, and the `openURL:` / `sharedApplication`
        // selector walk is a private-API path that risks App Store rejection. Not worth it.
        let root = ShareRootView(
            items: items,
            kind: kind,
            close: { [weak self] in self?.finish() },
            openApp: { [weak self] in self?.finish() }   // no jump — just close
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
}
