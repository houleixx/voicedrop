import SwiftUI
import UIKit
import ImageIO

/// The 「看图写一篇」sheet — the Share Extension's landing page for **image**
/// shares (`ShareRouter`/`ShareRootView` route images here). There is no
/// dedicated mockup for this sheet in the design handoff; it reuses
/// `AudioComposeView`'s shell/tokens/footer button, swapping the audio card
/// for a thumbnail grid. Like the audio flow this uploads immediately and
/// kicks the miner rather than collecting a 写作风格 corpus item — sharing
/// photos means "一步看图成文". The server has no vision-only mining path, so
/// this uploads a **silent placeholder `.m4a`** (ASR finds no speech) plus the
/// images under `photos/<sessionTs>/` (keyed off the SAME timestamp as the
/// placeholder's filename) — the miner's vision pass picks them up from there.
struct PhotoComposeView: View {
    let payload: SharePayload
    let close: () -> Void
    /// Called after a successful 生成文章 — opens the host app to 我的录音.
    var openApp: () -> Void = {}

    @State private var uploading = false
    @State private var uploadFailed = false
    /// 写作风格 row value — starts neutral, replaced by `loadStyle()` once the
    /// user's actual style loads (never a fake placeholder; see that func).
    @State private var styleLabel = "未设置"

    /// Rough flat vision-cost estimate (no ASR/duration signal to key off, unlike
    /// audio) — matches the task brief's formula exactly: `max(1, 2 + N images)`.
    private var costEstimate: Int {
        max(1, 2 + payload.images.count)
    }

    var body: some View {
        VStack(spacing: 0) {
            grabber
            header
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    thumbnailGrid
                    settingsSection
                    costLine
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 8)
            }
            footer
        }
        .frame(maxWidth: .infinity)
        .frame(maxHeight: UIScreen.main.bounds.height * 0.85)
        .background(ShareTheme.sheetBG)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 18, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 18, style: .continuous))
        .shadow(color: Color(hex: "3C301E").opacity(0.16), radius: 20, x: 0, y: -6)
        .ignoresSafeArea(edges: .bottom)
        .task { await loadStyle() }
    }

    // MARK: - Header / grabber

    private var grabber: some View {
        Capsule()
            .fill(Color(hex: "DDD3C2"))
            .frame(width: 38, height: 5)
            .padding(.top, 10)
            .padding(.bottom, 2)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("看图写一篇")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(ShareTheme.ink)
                Text("\(payload.images.count) 张图片 · 已就绪")
                    .font(.system(size: 13))
                    .foregroundStyle(ShareTheme.secondary)
            }
            Spacer(minLength: 0)
            Button(action: close) {
                Text("关闭")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(ShareTheme.secondary)
            }
            .buttonStyle(.plain)
            .disabled(uploading)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    // MARK: - Thumbnail grid (audio card's replacement)

    private var thumbnailGrid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 3)
        return LazyVGrid(columns: columns, spacing: 8) {
            ForEach(Array(payload.images.enumerated()), id: \.offset) { _, url in
                ThumbnailCell(url: url)
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color(hex: "E8DFD0"), lineWidth: 1))
    }

    // MARK: - 生成设置

    /// Only 写作风格 — unlike the audio sheet there's no 识别语言 row (images
    /// carry no speech to recognize), per the task brief.
    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("生成设置")
                .font(.system(size: 13, weight: .semibold))
                .tracking(1)
                .foregroundStyle(Color(hex: "a79f93"))
                .padding(.top, 20)
                .padding(.bottom, 8)
                .padding(.horizontal, 6)

            settingsRow(title: "写作风格", value: styleLabel)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.white))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).stroke(Color(hex: "ECE3D5"), lineWidth: 1))
        }
    }

    /// Read-only display row — a static label + chevron, no picker (mirrors
    /// `AudioComposeView`). `value` is the user's real style label, fetched by
    /// `loadStyle()`.
    private func settingsRow(title: String, value: String) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 15))
                .foregroundStyle(Color(hex: "2A2521"))
            Spacer(minLength: 0)
            Text(value)
                .font(.system(size: 13.5))
                .foregroundStyle(Color(hex: "8A8175"))
                .lineLimit(1)
                .truncationMode(.tail)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(hex: "CFC6B6"))
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 14)
    }

    // MARK: - Cost line

    private var costLine: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 12))
                .foregroundStyle(Color(hex: "C98A2E"))
                .padding(.top, 1)
            (
                Text("预计消耗约 ")
                    .foregroundStyle(Color(hex: "a79f93"))
                + Text("\(costEstimate) 算力")
                    .fontWeight(.semibold)
                    .foregroundStyle(Color(hex: "C98A2E"))
                + Text(" · 看图成文")
                    .foregroundStyle(Color(hex: "a79f93"))
            )
            .font(.system(size: 12.5))
        }
        .padding(.top, 12)
        .padding(.horizontal, 6)
        .padding(.bottom, 4)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 0) {
            if uploadFailed {
                Text("上传失败，请重试")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color(hex: "C0682E"))
                    .padding(.bottom, 8)
            }
            Button(action: { Task { await generate() } }) {
                HStack(spacing: 8) {
                    if uploading {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "doc.text")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    Text("开始生成文章")
                        .font(.system(size: 16.5, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color(hex: "D8593B")))
                .shadow(color: Color(hex: "D8593B").opacity(0.28), radius: 10, x: 0, y: 4)
            }
            .buttonStyle(.plain)
            .disabled(uploading || payload.images.isEmpty)
            .opacity((uploading || payload.images.isEmpty) ? 0.7 : 1)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 30)
        .background(ShareTheme.sheetBG)
        .overlay(alignment: .top) { Rectangle().fill(Color(hex: "EFE7D9")).frame(height: 1) }
    }

    // MARK: - Actions

    /// Fetch the user's current 写作风格 and derive the 写作风格 row's label —
    /// identical logic to `AudioComposeView.loadStyle()` (first non-empty line,
    /// truncated to ~12 characters + `…`; not shared into a common helper since
    /// each sheet file is intentionally self-contained, matching this target's
    /// existing pattern). Leaves `styleLabel` at its neutral "未设置" default —
    /// never a fake placeholder — when there's no style yet or the fetch fails.
    private func loadStyle() async {
        guard let text = await ShareAPI.fetchStyleText() else { return }
        let line = text.split(whereSeparator: \.isNewline).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard !line.isEmpty else { return }
        styleLabel = line.count > 12 ? String(line.prefix(12)) + "…" : line
    }

    /// 「开始生成文章」— upload every shared image under `photos/<sessionTs>/`
    /// FIRST, then a silent placeholder `.m4a` LAST (so the miner's ASR finds
    /// no speech and falls through to its vision pass), then kick the miner
    /// and close.
    ///
    /// **Correlation contract:** the miner gathers photos living under
    /// `photos/<ts>/` where `<ts>` is the audio placeholder's OWN embedded
    /// timestamp (`RecordingName.make` folds `RecordingName.timestamp(date)`
    /// into the filename). Both the placeholder name and every photo key are
    /// derived from ONE `date` captured once at the top of this function — two
    /// separate `Date()` calls could drift across a second boundary and break
    /// the correlation, silently hiding every photo from the vision pass.
    ///
    /// **Ordering contract (photos before audio):** the server's upload
    /// endpoint auto-dispatches the miner the instant ANY `VoiceDrop-*.m4a`
    /// lands, independent of the explicit `triggerMine()` below. If the silent
    /// placeholder uploaded first, the mine could start before any photo has
    /// landed — ASR on the 1-second silent clip finds no speech, the miner
    /// sees zero photos (still uploading), and writes `.empty(no-speech)`,
    /// orphaning the photos and losing the share. Uploading all photos before
    /// the audio matches the in-app recorder's own invariant (photos are in R2
    /// before the audio triggers the mine) and makes the race impossible.
    /// Never closes on failure (no false success); the button re-enables with
    /// an inline error so the user can retry.
    private func generate() async {
        guard !uploading, !payload.images.isEmpty else { return }
        uploading = true
        uploadFailed = false

        let date = Date()
        let sessionTs = RecordingName.timestamp(date)
        let audioName = RecordingName.make(start: date, duration: 1, place: nil)

        // Encode + upload each photo FIRST. Square-crop/JPEG-encode runs
        // `Task.detached` per image (like Task 8's off-main doc-parse fix) so
        // decoding/encoding N full-resolution shared photos never blocks the
        // main actor.
        var uploadedPhotos = 0
        for (i, imgURL) in payload.images.enumerated() {
            let jpeg = await Task.detached(priority: .userInitiated) {
                SquareCrop.jpeg(fromFile: imgURL)
            }.value
            guard let jpeg else { continue }
            let key = RecordingName.photoKey(sessionTs: sessionTs, offset: i)
            if await ShareAPI.putData(jpeg, name: key, contentType: "image/jpeg") {
                uploadedPhotos += 1
            }
        }

        // If every photo failed to encode/upload there is nothing for the miner
        // to see (silent audio + no photos == 无语音) — surface that as a
        // failure rather than a false "generating…" success. A partial success
        // (some but not all photos landed) still proceeds; the article will
        // just reflect the photos that made it.
        guard uploadedPhotos > 0 else {
            uploading = false
            uploadFailed = true
            return
        }

        // Silent placeholder LAST — see "Ordering contract" above. The bytes are
        // embedded in code (`SilentAudio.data`), NOT a bundled resource, so this
        // can't silently fail on a missing/unbundled asset in a release build —
        // the old `Bundle.main.url(forResource:"silent")` could return nil and
        // orphan every shared photo.
        guard await ShareAPI.putData(SilentAudio.data, name: audioName, contentType: "audio/mp4") else {
            uploading = false
            uploadFailed = true
            return
        }

        await ShareAPI.triggerMine()
        openApp()   // finish + jump to 我的录音 to watch progress
    }
}

// MARK: - Thumbnail cell

/// One square grid cell — decodes its image off the main actor (large shared
/// photos can be several MB) and renders `.scaledToFill().clipped()` inside a
/// rounded-corner container, per the task brief.
private struct ThumbnailCell: View {
    let url: URL
    @State private var image: UIImage?

    var body: some View {
        Rectangle()
            .fill(Color(hex: "F0E8DA"))
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .clipped()
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 16))
                        .foregroundStyle(Color(hex: "CFC6B6"))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .clipped()
            .task {
                guard image == nil else { return }
                image = await Task.detached(priority: .utility) {
                    UIImage(contentsOfFile: url.path)
                }.value
            }
    }
}

// MARK: - Square crop (inlined, extension-safe)

/// Minimal, self-contained square-crop + JPEG encode. Mirrors
/// `VoiceDropApp/PhotoCapture.swift`'s `SquareImage.jpeg` algorithm (center-crop
/// to 1:1, downscale to `maxSide`, step down JPEG quality until under
/// `maxBytes`) but is NOT that same type — `PhotoCapture.swift` pulls in
/// `AVFoundation`/`PhotosUI` (camera capture session, `PHPickerViewController`)
/// for its capture UI, which have no place in a Share Extension target and
/// aren't worth adding a `VoiceDropShare.sources` entry to share just this
/// helper. A plain stateless `enum`, so it can run freely inside `Task.detached`
/// off the main actor.
enum SquareCrop {
    // maxSide 640 (was 1080): the shared photo is used BOTH for inline article
    // display and as Claude-vision input; a 640² square is plenty for a phone-width
    // article image and cuts vision cost from ~1500 to ~545 tokens/photo.
    static func jpeg(_ image: UIImage, maxSide: CGFloat = 640, maxBytes: Int = 900_000) -> Data? {
        autoreleasepool {
            let s = image.size
            guard s.width > 0, s.height > 0 else { return nil }
            let cropSide = min(s.width, s.height)
            let origin = CGPoint(x: (s.width - cropSide) / 2, y: (s.height - cropSide) / 2)

            let outSide = min(cropSide * image.scale, maxSide)
            let fmt = UIGraphicsImageRendererFormat.default()
            fmt.scale = 1
            fmt.opaque = true
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: outSide, height: outSide), format: fmt)
            let square = renderer.image { ctx in
                let k = outSide / cropSide
                ctx.cgContext.scaleBy(x: k, y: k)
                image.draw(at: CGPoint(x: -origin.x, y: -origin.y))   // applies EXIF orientation
            }

            var q: CGFloat = 0.8
            var data = square.jpegData(compressionQuality: q)
            while let d = data, d.count > maxBytes, q > 0.4 {
                q -= 0.1
                data = square.jpegData(compressionQuality: q)
            }
            return data
        }
    }

    /// Load a shared image file URL straight to a square JPEG, safe off the main
    /// actor. **Downsamples during decode** via ImageIO so a huge camera photo
    /// (tens of MP) never fully decodes into memory — the old `UIImage(data:)`
    /// path decoded the full-resolution bitmap and OOM-crashed the memory-tight
    /// Share Extension (~120 MB), which silently killed the whole share (nothing
    /// uploaded, sheet vanished). The thumbnail's longest edge is capped at
    /// `maxSide`, so the square crop that follows is ≤ maxSide too.
    static func jpeg(fromFile url: URL, maxSide: CGFloat = 640, maxBytes: Int = 900_000) -> Data? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,     // bake in EXIF orientation
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide,         // long edge ≤ maxSide, decoded small
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return jpeg(UIImage(cgImage: cg), maxSide: maxSide, maxBytes: maxBytes)
    }
}
