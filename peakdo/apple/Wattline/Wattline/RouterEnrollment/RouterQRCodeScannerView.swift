@preconcurrency import AVFoundation
import SwiftUI
import UIKit

struct RouterQRCodeScannerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var authorization: CameraAuthorizationStatus = .notDetermined
    let onPayload: (String) -> Bool

    var body: some View {
        NavigationStack {
            Group {
                switch authorization {
                case .authorized:
                    CameraQRCodePreview { payload in
                        if onPayload(payload) { dismiss() }
                    }
                    .ignoresSafeArea(edges: .bottom)
                case .denied:
                    ContentUnavailableView(
                        "Camera access unavailable",
                        systemImage: "camera.fill",
                        description: Text("Allow camera access in Settings, or paste/import a pairing code.")
                    )
                case .notDetermined:
                    ProgressView("Requesting camera access…")
                }
            }
            .navigationTitle("Scan Router QR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .task {
            let access = RouterCameraAccessController(adapter: SystemCameraAuthorizationAdapter())
            authorization = await access.authorizeForScan() ? .authorized : .denied
        }
    }
}

private struct CameraQRCodePreview: UIViewControllerRepresentable {
    let onPayload: (String) -> Void

    func makeUIViewController(context: Context) -> QRCodeCameraViewController {
        QRCodeCameraViewController(onPayload: onPayload)
    }

    func updateUIViewController(_ uiViewController: QRCodeCameraViewController, context: Context) {}
}

private final class QRCodeCameraViewController: UIViewController, @MainActor AVCaptureMetadataOutputObjectsDelegate {
    private let session = AVCaptureSession()
    private let onPayload: (String) -> Void
    private var didDeliverPayload = false
    private var previewLayer: AVCaptureVideoPreviewLayer?

    init(onPayload: @escaping (String) -> Void) {
        self.onPayload = onPayload
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input)
        else { return }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.addSublayer(preview)
        previewLayer = preview

        DispatchQueue.global(qos: .userInitiated).async { [session] in
            session.startRunning()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        DispatchQueue.global(qos: .userInitiated).async { [session] in
            session.stopRunning()
        }
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard !didDeliverPayload,
              let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let payload = object.stringValue
        else { return }
        didDeliverPayload = true
        onPayload(payload)
    }
}
