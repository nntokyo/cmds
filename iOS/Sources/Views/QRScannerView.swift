import AVFoundation
import CmdsCore
import SwiftUI
import VisionKit

/// Camera sheet that reads the pairing QR code shown in cmds on the Mac ("Pair iPhone/iPad…").
/// Only `cmds-pair:v2` payloads are accepted; anything else is reported and scanning continues.
struct PairingCodeScanner: View {
    var onPayload: (SyncPairingPayload) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var access = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var message: String?
    @State private var done = false

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Scan Pairing Code")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
        }
    }

    @ViewBuilder private var content: some View {
        if AVCaptureDevice.default(for: .video) == nil {
            ContentUnavailableView("No Camera", systemImage: "camera",
                                   description: Text("Pair without the camera: pick the Mac and compare its identity."))
        } else {
            switch access {
            case .authorized:
                QRScannerView(onCode: handle)
                    .ignoresSafeArea(edges: .bottom)
                    .overlay(alignment: .bottom) {
                        Text(message ?? "Point the camera at the QR code in cmds › Pair iPhone/iPad… on your Mac.")
                            .font(.callout)
                            .multilineTextAlignment(.center)
                            .padding(12)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                            .padding()
                    }
            case .notDetermined:
                ProgressView()
                    .task {
                        _ = await AVCaptureDevice.requestAccess(for: .video)
                        access = AVCaptureDevice.authorizationStatus(for: .video)
                    }
            default:
                ContentUnavailableView("Camera Access Is Off", systemImage: "camera.fill",
                                       description: Text("Allow camera access for cmds in Settings, or pair without the camera."))
            }
        }
    }

    private func handle(_ text: String) {
        guard !done else { return }
        do {
            let payload = try SyncPairingPayload.parse(text)
            done = true
            dismiss()
            onPayload(payload)
        } catch SyncPairingPayload.ParseError.notPairingPayload {
            message = String(localized: "That is not a cmds pairing code.")
        } catch SyncPairingPayload.ParseError.unsupportedVersion {
            message = String(localized: "This pairing code is from another version of cmds. Update cmds on the Mac and on this device.")
        } catch {
            message = String(localized: "This pairing code could not be read.")
        }
    }
}

/// Live camera QR reader: VisionKit's DataScannerViewController where supported, else AVFoundation
/// (iPads with an A10/A11 chip run iPadOS 17 without DataScanner support).
struct QRScannerView: UIViewControllerRepresentable {
    var onCode: (String) -> Void

    func makeUIViewController(context: Context) -> UIViewController {
        if DataScannerViewController.isSupported, DataScannerViewController.isAvailable {
            return DataScannerHost(onCode: onCode)
        }
        return CaptureQRController(onCode: onCode)
    }

    func updateUIViewController(_ controller: UIViewController, context: Context) {
        (controller as? DataScannerHost)?.onCode = onCode
        (controller as? CaptureQRController)?.onCode = onCode
    }
}

/// Hosts a DataScannerViewController and starts it once on screen.
private final class DataScannerHost: UIViewController, DataScannerViewControllerDelegate {
    var onCode: (String) -> Void
    private let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                                    qualityLevel: .balanced, recognizesMultipleItems: false,
                                                    isHighFrameRateTrackingEnabled: false, isPinchToZoomEnabled: true,
                                                    isGuidanceEnabled: true, isHighlightingEnabled: true)

    init(onCode: @escaping (String) -> Void) {
        self.onCode = onCode
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        scanner.delegate = self
        addChild(scanner)
        scanner.view.frame = view.bounds
        scanner.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(scanner.view)
        scanner.didMove(toParent: self)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        try? scanner.startScanning()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        scanner.stopScanning()
    }

    func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
        for item in addedItems {
            if case .barcode(let barcode) = item, let text = barcode.payloadStringValue { onCode(text) }
        }
    }
}

/// AVFoundation fallback: preview layer plus a QR metadata output.
private final class CaptureQRController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: (String) -> Void
    private let session = AVCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?

    init(onCode: @escaping (String) -> Void) {
        self.onCode = onCode
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)
        self.preview = preview
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        let session = session
        DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        let session = session
        DispatchQueue.global(qos: .userInitiated).async { session.stopRunning() }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        for case let code as AVMetadataMachineReadableCodeObject in metadataObjects {
            if let text = code.stringValue { onCode(text) }
        }
    }
}
