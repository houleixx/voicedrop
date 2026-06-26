import SwiftUI
import AVFoundation
import PhotosUI

// MARK: - SwiftUI wrapper

/// A photo kept by the camera, handed back on 完成 for upload.
struct CapturedPhoto: Sendable {
    let date: Date     // capture moment → becomes the R2 filename (per-photo timestamp)
    let data: Data     // square ≤1080px JPEG, <900KB
}

struct PhotoCaptureView: UIViewControllerRepresentable {
    /// The recording's start instant — drives the live "录音中 · MM:SS" label.
    var recordingStart: Date?
    /// Called when the user taps 完成 — delivers all kept photos (in order) for
    /// upload, then the camera closes. Invoked on the main thread.
    var onFinish: ([CapturedPhoto]) -> Void

    func makeUIViewController(context: Context) -> PhotoCaptureVC {
        let vc = PhotoCaptureVC()
        vc.recordingStart = recordingStart
        vc.onFinish = onFinish
        return vc
    }

    func updateUIViewController(_ vc: PhotoCaptureVC, context: Context) {}
}

// MARK: - Delivery payload (Sendable: crosses the capture/decode queue → main)

private struct ShotPayload: Sendable {
    let date: Date
    let full: Data     // upload-quality square JPEG
    let thumb: Data    // tiny square JPEG for the filmstrip
}

/// Forwards an off-main capture/decode result onto the main actor without
/// capturing the (non-Sendable) view controller inside a @Sendable closure.
private final class ShotSink: @unchecked Sendable {
    weak var vc: PhotoCaptureVC?
    func send(_ p: ShotPayload) { DispatchQueue.main.async { self.vc?.addShot(p) } }
}

// MARK: - View Controller

/// 边录边拍 camera (design: "Photo Capture"). Runs an AVCaptureSession with a
/// video-only input (no audio → the ongoing AVAudioRecorder is NOT interrupted).
/// Square viewfinder with a rule-of-thirds grid; shots collect in a filmstrip
/// (delete with ✕); 完成 hands them all back for upload. Photo-library import via
/// PHPicker (no permission prompt); front/back flip.
final class PhotoCaptureVC: UIViewController, PHPickerViewControllerDelegate {
    var recordingStart: Date?
    var onFinish: (([CapturedPhoto]) -> Void)?

    // Capture
    private let captureSession = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "com.vd.photo.session")
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var currentInput: AVCaptureDeviceInput?
    private var cameraPosition: AVCaptureDevice.Position = .back
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var previewRotationObservation: NSKeyValueObservation?
    private var currentDelegate: PhotoDelegate?
    private let sink = ShotSink()

    // Model
    private struct Shot { let id = UUID(); let date: Date; let data: Data; let thumb: UIImage }
    private var shots: [Shot] = []

    // Chrome
    private let gridLayer = CAShapeLayer()
    private let emptyHint = UIView()
    private let leftPill = UILabel()
    private let doneButton = UIButton(type: .system)
    private let filmstrip = UIScrollView()
    private let filmRow = UIStackView()
    private let filmCaption = UILabel()
    private var bottomBar: UIView!
    private var timer: Timer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0x0E/255, green: 0x0D/255, blue: 0x0C/255, alpha: 1)
        sink.vc = self
        setupCapture()
        setupChrome()
        refreshState()
        startTimer()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let f = squareFrame
        previewLayer?.frame = f
        emptyHint.frame = f
        layoutGrid(in: f)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        timer?.invalidate()
        sessionQueue.async { self.captureSession.stopRunning() }
    }

    /// The viewfinder square: full content-width minus 18px insets, vertically
    /// centered in the gap between the top bar and the filmstrip/controls.
    private var squareFrame: CGRect {
        let inset: CGFloat = 18
        let side = min(view.bounds.width - inset * 2,
                       max(0, view.bounds.height - topInset - bottomReserve))
        let x = (view.bounds.width - side) / 2
        let y = topInset + max(0, (view.bounds.height - topInset - bottomReserve - side) / 2)
        return CGRect(x: x, y: y, width: side, height: side)
    }
    private var topInset: CGFloat { view.safeAreaInsets.top + 52 }
    private var bottomReserve: CGFloat { view.safeAreaInsets.bottom + 230 }

    // MARK: Capture setup

    private func setupCapture() {
        guard
            let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
            let input = try? AVCaptureDeviceInput(device: device),
            captureSession.canAddInput(input),
            captureSession.canAddOutput(photoOutput)
        else { return }

        captureSession.beginConfiguration()
        captureSession.sessionPreset = .photo
        captureSession.addInput(input)
        captureSession.addOutput(photoOutput)
        captureSession.commitConfiguration()
        currentInput = input

        let preview = AVCaptureVideoPreviewLayer(session: captureSession)
        preview.videoGravity = .resizeAspectFill   // fills the square; center-crops sensor
        view.layer.insertSublayer(preview, at: 0)
        previewLayer = preview

        // Rule-of-thirds grid + 1px border, drawn over the preview.
        gridLayer.fillColor = nil
        gridLayer.strokeColor = UIColor(white: 1, alpha: 0.10).cgColor
        gridLayer.lineWidth = 1
        view.layer.addSublayer(gridLayer)

        applyConnectionGeometry()
        sessionQueue.async { self.captureSession.startRunning() }
    }

    /// Bind a `RotationCoordinator` to the current camera so the preview + captured
    /// stills follow the device's PHYSICAL orientation (horizon-level), correct for
    /// both front and back. Recreated whenever the input device changes (flip).
    ///
    /// We OBSERVE the preview angle via KVO instead of reading it once: the
    /// coordinator resolves device orientation asynchronously (CoreMotion) and the
    /// user can rotate the phone at any moment, so a single synchronous read would
    /// be stale. Front-camera mirroring on the PREVIEW is left to the system
    /// (`automaticallyAdjustsVideoMirroring`), which composes correctly with the
    /// coordinator's angle — manually mirroring the preview reverses the rotation
    /// sense and is what previously scrambled the front camera.
    private func applyConnectionGeometry() {
        guard let device = currentInput?.device else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotationCoordinator = coordinator
        previewRotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview,
                                                         options: [.initial, .new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.updatePreviewRotation() }
        }
        configurePhotoConnection()
    }

    /// Apply the coordinator's current horizon-level angle to the live preview.
    private func updatePreviewRotation() {
        guard let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelPreview,
              let pc = previewLayer?.connection else { return }
        if pc.isVideoRotationAngleSupported(angle) { pc.videoRotationAngle = angle }
    }

    /// Horizon-level rotation + (front → mirrored) on the PHOTO-OUTPUT connection.
    /// Flipping the camera removes/re-adds the session input, which tears down and
    /// recreates this connection with default geometry. We call this immediately
    /// before each capture so every still uses the coordinator's CURRENT capture
    /// angle (matching how the phone is physically held at that instant) and is
    /// mirrored to match the (system-mirrored) front preview.
    private func configurePhotoConnection() {
        guard let oc = photoOutput.connection(with: .video) else { return }
        if let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture,
           oc.isVideoRotationAngleSupported(angle) {
            oc.videoRotationAngle = angle
        }
        if oc.isVideoMirroringSupported {
            oc.automaticallyAdjustsVideoMirroring = false
            oc.isVideoMirrored = (cameraPosition == .front)
        }
    }

    private func layoutGrid(in r: CGRect) {
        guard r.width > 0 else { gridLayer.path = nil; return }
        let p = UIBezierPath(roundedRect: r, cornerRadius: 4)
        for i in 1...2 {
            let x = r.minX + r.width * CGFloat(i) / 3
            p.move(to: CGPoint(x: x, y: r.minY)); p.addLine(to: CGPoint(x: x, y: r.maxY))
            let y = r.minY + r.height * CGFloat(i) / 3
            p.move(to: CGPoint(x: r.minX, y: y)); p.addLine(to: CGPoint(x: r.maxX, y: y))
        }
        gridLayer.path = p.cgPath
        // Brighter border ring (separate, since grid is faint).
        gridLayer.strokeColor = UIColor(white: 1, alpha: 0.10).cgColor
    }

    // MARK: Chrome

    private func setupChrome() {
        let safe = view.safeAreaLayoutGuide

        // — top-left status pill (timer / 已拍 N 张) —
        leftPill.font = .systemFont(ofSize: 14, weight: .semibold)
        leftPill.textColor = .white
        leftPill.textAlignment = .center
        leftPill.backgroundColor = UIColor(white: 1, alpha: 0.14)
        leftPill.layer.cornerRadius = 14
        leftPill.layer.masksToBounds = true
        leftPill.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(leftPill)

        // — top-right 完成 —
        doneButton.setTitle("完成", for: .normal)
        doneButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .semibold)
        doneButton.layer.cornerRadius = 8
        doneButton.translatesAutoresizingMaskIntoConstraints = false
        doneButton.contentEdgeInsets = UIEdgeInsets(top: 9, left: 18, bottom: 9, right: 18)
        doneButton.addTarget(self, action: #selector(finishTapped), for: .touchUpInside)
        view.addSubview(doneButton)

        // — empty-state hint over the viewfinder —
        buildEmptyHint()
        view.addSubview(emptyHint)

        // — filmstrip (hidden until first shot) —
        filmstrip.showsHorizontalScrollIndicator = false
        filmstrip.translatesAutoresizingMaskIntoConstraints = false
        filmstrip.clipsToBounds = false
        filmRow.axis = .horizontal
        filmRow.spacing = 10
        filmRow.alignment = .center
        filmRow.translatesAutoresizingMaskIntoConstraints = false
        filmstrip.addSubview(filmRow)
        view.addSubview(filmstrip)

        filmCaption.text = "点照片右上角 ✕ 删除"
        filmCaption.font = .systemFont(ofSize: 12)
        filmCaption.textColor = UIColor(white: 1, alpha: 0.4)
        filmCaption.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(filmCaption)

        // — bottom controls —
        let shutter = UIButton(type: .custom)
        shutter.backgroundColor = .white
        shutter.layer.cornerRadius = 36
        shutter.layer.borderWidth = 4
        shutter.layer.borderColor = UIColor(white: 1, alpha: 0.5).cgColor
        shutter.layer.shadowColor = UIColor.black.cgColor
        shutter.layer.shadowOpacity = 0.2
        shutter.layer.shadowRadius = 0
        shutter.layer.shadowOffset = .zero
        shutter.addTarget(self, action: #selector(takePhoto), for: .touchUpInside)

        let library = squareIconButton(systemSymbols: ["photo.on.rectangle"], action: #selector(openLibrary))
        let flip = squareIconButton(systemSymbols: ["arrow.triangle.2.circlepath.camera", "camera.rotate"], action: #selector(flipCamera))

        let bar = UIView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bottomBar = bar
        view.addSubview(bar)
        for v in [library, shutter, flip] { v.translatesAutoresizingMaskIntoConstraints = false; bar.addSubview(v) }

        NSLayoutConstraint.activate([
            leftPill.topAnchor.constraint(equalTo: safe.topAnchor, constant: 6),
            leftPill.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            leftPill.heightAnchor.constraint(equalToConstant: 28),
            leftPill.widthAnchor.constraint(greaterThanOrEqualToConstant: 96),

            doneButton.centerYAnchor.constraint(equalTo: leftPill.centerYAnchor),
            doneButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),

            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: safe.bottomAnchor, constant: -24),
            bar.heightAnchor.constraint(equalToConstant: 72),

            shutter.widthAnchor.constraint(equalToConstant: 72),
            shutter.heightAnchor.constraint(equalToConstant: 72),
            shutter.centerXAnchor.constraint(equalTo: bar.centerXAnchor),
            shutter.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            library.widthAnchor.constraint(equalToConstant: 48),
            library.heightAnchor.constraint(equalToConstant: 48),
            library.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            library.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 32),

            flip.widthAnchor.constraint(equalToConstant: 48),
            flip.heightAnchor.constraint(equalToConstant: 48),
            flip.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            flip.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -32),

            filmCaption.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -10),
            filmCaption.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),

            filmstrip.bottomAnchor.constraint(equalTo: filmCaption.topAnchor, constant: -8),
            filmstrip.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            filmstrip.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -18),
            filmstrip.heightAnchor.constraint(equalToConstant: 73),

            filmRow.topAnchor.constraint(equalTo: filmstrip.topAnchor),
            filmRow.bottomAnchor.constraint(equalTo: filmstrip.bottomAnchor),
            filmRow.leadingAnchor.constraint(equalTo: filmstrip.contentLayoutGuide.leadingAnchor),
            filmRow.trailingAnchor.constraint(equalTo: filmstrip.contentLayoutGuide.trailingAnchor),
            filmRow.heightAnchor.constraint(equalTo: filmstrip.heightAnchor),
        ])
    }

    private func squareIconButton(systemSymbols: [String], action: Selector) -> UIButton {
        let b = UIButton(type: .system)
        let img = systemSymbols.lazy.compactMap { UIImage(systemName: $0) }.first
        b.setImage(img, for: .normal)
        b.tintColor = .white
        b.backgroundColor = UIColor(white: 1, alpha: 0.12)
        b.layer.cornerRadius = 11
        b.addTarget(self, action: action, for: .touchUpInside)
        b.imageView?.contentMode = .scaleAspectFit
        b.contentEdgeInsets = UIEdgeInsets(top: 13, left: 13, bottom: 13, right: 13)
        return b
    }

    private func buildEmptyHint() {
        emptyHint.isUserInteractionEnabled = false
        let icon = UIImageView(image: UIImage(systemName: "camera"))
        icon.tintColor = UIColor(white: 1, alpha: 0.5)
        icon.contentMode = .scaleAspectFit
        let title = UILabel()
        title.text = "边录边拍"
        title.font = .systemFont(ofSize: 14)
        title.textColor = UIColor(white: 1, alpha: 0.45)
        let sub = UILabel()
        sub.text = "照片会附在这条录音里"
        sub.font = .systemFont(ofSize: 12.5)
        sub.textColor = UIColor(white: 1, alpha: 0.35)
        let stack = UIStackView(arrangedSubviews: [icon, title, sub])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        emptyHint.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: emptyHint.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: emptyHint.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 38),
            icon.heightAnchor.constraint(equalToConstant: 38),
        ])
    }

    // MARK: State refresh

    private func refreshState() {
        emptyHint.isHidden = !shots.isEmpty
        filmstrip.isHidden = shots.isEmpty
        filmCaption.isHidden = shots.isEmpty

        if shots.isEmpty {
            leftPill.layer.cornerRadius = 14
            updateTimerLabel()
            doneButton.setTitleColor(UIColor(white: 1, alpha: 0.5), for: .normal)
            doneButton.backgroundColor = UIColor(white: 1, alpha: 0.14)
            doneButton.layer.shadowOpacity = 0
        } else {
            leftPill.attributedText = nil
            leftPill.text = " 已拍 \(shots.count) 张 "
            doneButton.setTitleColor(.white, for: .normal)
            doneButton.backgroundColor = UIColor(red: 0xD8/255, green: 0x59/255, blue: 0x3B/255, alpha: 1)
            doneButton.layer.shadowColor = UIColor(red: 0xD8/255, green: 0x59/255, blue: 0x3B/255, alpha: 1).cgColor
            doneButton.layer.shadowOpacity = 0.4
            doneButton.layer.shadowRadius = 12
            doneButton.layer.shadowOffset = CGSize(width: 0, height: 4)
        }
        rebuildFilmstrip()
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.shots.isEmpty else { return }
            self.updateTimerLabel()
        }
    }

    /// "● 录音中 · MM:SS" — red dot via an attributed leading glyph.
    private func updateTimerLabel() {
        let elapsed = recordingStart.map { Int(Date().timeIntervalSince($0)) } ?? 0
        let mmss = String(format: "%02d:%02d", max(0, elapsed) / 60, max(0, elapsed) % 60)
        let dot = NSTextAttachment()
        let r: CGFloat = 7
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: r, height: r))
        let dotImg = renderer.image { ctx in
            ctx.cgContext.setFillColor(UIColor(red: 0xE5/255, green: 0x39/255, blue: 0x2E/255, alpha: 1).cgColor)
            ctx.cgContext.fillEllipse(in: CGRect(x: 0, y: 0, width: r, height: r))
        }
        dot.image = dotImg
        dot.bounds = CGRect(x: 0, y: -0.5, width: r, height: r)
        let s = NSMutableAttributedString(attachment: dot)
        s.append(NSAttributedString(string: "  录音中 · \(mmss)  ",
                                    attributes: [.foregroundColor: UIColor(white: 1, alpha: 0.85),
                                                 .font: UIFont.systemFont(ofSize: 13)]))
        leftPill.attributedText = s
    }

    private func rebuildFilmstrip() {
        filmRow.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for shot in shots {
            let cell = UIView()
            cell.translatesAutoresizingMaskIntoConstraints = false
            cell.clipsToBounds = false

            let iv = UIImageView(image: shot.thumb)
            iv.contentMode = .scaleAspectFill
            iv.clipsToBounds = true
            iv.layer.cornerRadius = 9
            iv.layer.borderWidth = 1
            iv.layer.borderColor = UIColor(white: 1, alpha: 0.18).cgColor
            iv.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(iv)

            let del = UIButton(type: .custom)
            del.translatesAutoresizingMaskIntoConstraints = false
            del.backgroundColor = UIColor(red: 0x1A/255, green: 0x18/255, blue: 0x16/255, alpha: 1)
            del.layer.cornerRadius = 11
            del.layer.borderWidth = 1.5
            del.layer.borderColor = UIColor(white: 1, alpha: 0.6).cgColor
            del.setImage(UIImage(systemName: "xmark",
                                 withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .bold)), for: .normal)
            del.tintColor = .white
            let id = shot.id
            del.addAction(UIAction { [weak self] _ in self?.deleteShot(id) }, for: .touchUpInside)
            cell.addSubview(del)

            NSLayoutConstraint.activate([
                cell.widthAnchor.constraint(equalToConstant: 73),
                cell.heightAnchor.constraint(equalToConstant: 73),
                iv.widthAnchor.constraint(equalToConstant: 66),
                iv.heightAnchor.constraint(equalToConstant: 66),
                iv.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                iv.bottomAnchor.constraint(equalTo: cell.bottomAnchor),
                del.widthAnchor.constraint(equalToConstant: 22),
                del.heightAnchor.constraint(equalToConstant: 22),
                del.topAnchor.constraint(equalTo: cell.topAnchor),
                del.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            ])
            filmRow.addArrangedSubview(cell)
        }
    }

    // MARK: Actions

    @objc private func takePhoto() {
        // Re-assert geometry on the photo-output connection right before capture:
        // a prior flip may have recreated this connection with stale/default
        // rotation+mirroring, which would otherwise make the still come out wrong.
        configurePhotoConnection()
        let sink = self.sink
        let delegate = PhotoDelegate { payload in sink.send(payload) }
        currentDelegate = delegate
        photoOutput.capturePhoto(with: AVCapturePhotoSettings(), delegate: delegate)
    }

    @objc private func finishTapped() {
        onFinish?(shots.map { CapturedPhoto(date: $0.date, data: $0.data) })
    }

    @objc private func flipCamera() {
        cameraPosition = (cameraPosition == .back) ? .front : .back
        sessionQueue.async {
            self.captureSession.beginConfiguration()
            if let cur = self.currentInput { self.captureSession.removeInput(cur) }
            if let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: self.cameraPosition),
               let input = try? AVCaptureDeviceInput(device: dev),
               self.captureSession.canAddInput(input) {
                self.captureSession.addInput(input)
                self.currentInput = input
            } else if let cur = self.currentInput {
                self.captureSession.addInput(cur)   // revert if the new camera is unavailable
            }
            self.captureSession.commitConfiguration()
            DispatchQueue.main.async { self.applyConnectionGeometry() }
        }
    }

    @objc private func openLibrary() {
        guard presentedViewController == nil else { return }
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 9          // cap multi-select so we don't decode a huge batch at once
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        let sink = self.sink                // Sendable; do NOT capture self in the @Sendable callback
        for r in results {
            let provider = r.itemProvider
            guard provider.canLoadObject(ofClass: UIImage.self) else { continue }
            provider.loadObject(ofClass: UIImage.self) { obj, _ in
                guard let img = obj as? UIImage,
                      let full = SquareImage.jpeg(img),
                      let thumb = SquareImage.jpeg(img, maxSide: 264, maxBytes: 80_000) else { return }
                sink.send(ShotPayload(date: Date(), full: full, thumb: thumb))
            }
        }
    }

    // MARK: Shot list (main actor)

    fileprivate func addShot(_ p: ShotPayload) {
        let thumb = UIImage(data: p.thumb) ?? UIImage()
        shots.append(Shot(date: p.date, data: p.full, thumb: thumb))
        flash()
        refreshState()
    }

    private func deleteShot(_ id: UUID) {
        shots.removeAll { $0.id == id }
        refreshState()
    }

    private func flash() {
        let f = UIView(frame: view.bounds)
        f.backgroundColor = .white
        f.alpha = 0.7
        f.isUserInteractionEnabled = false
        view.addSubview(f)
        UIView.animate(withDuration: 0.35, animations: { f.alpha = 0 }) { _ in f.removeFromSuperview() }
    }
}

// MARK: - Square crop (nonisolated — safe to call off the main thread)

/// Image cropping helper that is NOT actor-isolated, so it can run on the camera
/// delegate queue and the PHPicker load callback without a main-actor assertion
/// crash. Center-crops to 1:1 in DISPLAY orientation (matching the square
/// preview), downscales, and JPEG-encodes.
enum SquareImage {
    static func jpeg(_ image: UIImage, maxSide: CGFloat = 1080, maxBytes: Int = 900_000) -> Data? {
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
}

// MARK: - Capture delegate (separate class to avoid @MainActor isolation issues)

private final class PhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let onResult: (ShotPayload) -> Void

    init(onResult: @escaping (ShotPayload) -> Void) { self.onResult = onResult }

    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto,
                     error: Error?) {
        guard error == nil,
              let raw = photo.fileDataRepresentation(),
              let image = UIImage(data: raw),
              let full = SquareImage.jpeg(image),
              let thumb = SquareImage.jpeg(image, maxSide: 264, maxBytes: 80_000)
        else { return }
        // Also save a copy to the user's Photos library — the square WYSIWYG version
        // matching the viewfinder. Camera shots only; PHPicker imports already live there.
        // Needs NSPhotoLibraryAddUsageDescription; a denied permission just no-ops.
        if let square = UIImage(data: full) {
            UIImageWriteToSavedPhotosAlbum(square, nil, nil, nil)
        }
        onResult(ShotPayload(date: Date(), full: full, thumb: thumb))
    }
}
