import SwiftUI
import AVFoundation

struct QRScannerView: UIViewControllerRepresentable {
    let onCodeScanned: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> QRScannerViewController {
        let controller = QRScannerViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: QRScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCodeScanned: onCodeScanned, dismiss: dismiss)
    }

    final class Coordinator: NSObject, QRScannerDelegate, @unchecked Sendable {
        let onCodeScanned: (String) -> Void
        let dismiss: DismissAction

        init(onCodeScanned: @escaping (String) -> Void, dismiss: DismissAction) {
            self.onCodeScanned = onCodeScanned
            self.dismiss = dismiss
        }

        func didScanCode(_ code: String) {
            onCodeScanned(code)
            dismiss()
        }
    }
}

protocol QRScannerDelegate: AnyObject {
    func didScanCode(_ code: String)
}

final class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    weak var delegate: QRScannerDelegate?
    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var hasScanned = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupCamera()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if let session = captureSession, !session.isRunning {
            DispatchQueue.global(qos: .background).async {
                session.startRunning()
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if let session = captureSession, session.isRunning {
            session.stopRunning()
        }
    }

    private func setupCamera() {
        let session = AVCaptureSession()
        captureSession = session

        guard let videoCaptureDevice = AVCaptureDevice.default(for: .video),
              let videoInput = try? AVCaptureDeviceInput(device: videoCaptureDevice) else {
            showNoCameraUI()
            return
        }

        guard session.canAddInput(videoInput) else {
            showNoCameraUI()
            return
        }
        session.addInput(videoInput)

        let metadataOutput = AVCaptureMetadataOutput()
        guard session.canAddOutput(metadataOutput) else {
            showNoCameraUI()
            return
        }
        session.addOutput(metadataOutput)
        metadataOutput.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
        metadataOutput.metadataObjectTypes = [.qr]

        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.frame = view.bounds
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)
        self.previewLayer = previewLayer

        // Add scan overlay
        addScanOverlay()

        DispatchQueue.global(qos: .background).async {
            session.startRunning()
        }
    }

    private func addScanOverlay() {
        let overlayView = UIView(frame: view.bounds)
        overlayView.backgroundColor = .clear
        overlayView.isUserInteractionEnabled = false
        view.addSubview(overlayView)

        // Scanning frame
        let frameSize: CGFloat = 250
        let frameX = (view.bounds.width - frameSize) / 2
        let frameY = (view.bounds.height - frameSize) / 2 - 40

        let frameView = UIView(frame: CGRect(x: frameX, y: frameY, width: frameSize, height: frameSize))
        frameView.layer.borderColor = UIColor(red: 0.906, green: 0.298, blue: 0.235, alpha: 1.0).cgColor
        frameView.layer.borderWidth = 2
        frameView.layer.cornerRadius = 12
        overlayView.addSubview(frameView)

        // Instruction label
        let label = UILabel()
        label.text = "Scan BlueClaw QR Code"
        label.textColor = .white
        label.font = .systemFont(ofSize: 16, weight: .semibold)
        label.textAlignment = .center
        label.frame = CGRect(x: 0, y: frameY + frameSize + 24, width: view.bounds.width, height: 30)
        overlayView.addSubview(label)

        let sublabel = UILabel()
        sublabel.text = "Generate a QR code from your gateway"
        sublabel.textColor = UIColor.white.withAlphaComponent(0.6)
        sublabel.font = .systemFont(ofSize: 13)
        sublabel.textAlignment = .center
        sublabel.frame = CGRect(x: 0, y: frameY + frameSize + 52, width: view.bounds.width, height: 20)
        overlayView.addSubview(sublabel)
    }

    private func showNoCameraUI() {
        let label = UILabel()
        label.text = "Camera not available"
        label.textColor = .white
        label.font = .systemFont(ofSize: 16, weight: .medium)
        label.textAlignment = .center
        label.frame = view.bounds
        view.addSubview(label)
    }

    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        MainActor.assumeIsolated {
            guard !hasScanned,
                  let metadataObject = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  let stringValue = metadataObject.stringValue else { return }

            hasScanned = true

            // Haptic feedback
            let generator = UINotificationFeedbackGenerator()
            generator.notificationOccurred(.success)

            captureSession?.stopRunning()
            delegate?.didScanCode(stringValue)
        }
    }
}
