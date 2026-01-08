import SwiftUI
import AVFoundation

struct QRScannerView: View {
    @Environment(\.dismiss) private var dismiss
    let onScan: (PairingInfo) -> Void

    @State private var isAuthorized = false
    @State private var showingPermissionDenied = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            ZStack {
                if isAuthorized {
                    QRScannerRepresentable(onScan: handleScan, onError: handleError)
                        .ignoresSafeArea()

                    // Overlay with scanning frame
                    VStack {
                        Spacer()

                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.white, lineWidth: 3)
                            .frame(width: 250, height: 250)
                            .background(Color.clear)

                        Text("Point camera at QR code")
                            .font(.headline)
                            .foregroundColor(.white)
                            .padding(.top, 24)

                        Text("Shown in the Personal Agent desktop app")
                            .font(.subheadline)
                            .foregroundColor(.white.opacity(0.7))
                            .padding(.top, 4)

                        Spacer()
                    }

                    if let error = errorMessage {
                        VStack {
                            Spacer()
                            Text(error)
                                .font(.subheadline)
                                .foregroundColor(.white)
                                .padding()
                                .background(Color.red.opacity(0.8))
                                .cornerRadius(8)
                                .padding(.bottom, 100)
                        }
                    }
                } else {
                    VStack(spacing: 16) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)

                        Text("Camera Access Required")
                            .font(.headline)

                        Text("Allow camera access to scan QR codes")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)

                        if showingPermissionDenied {
                            Button("Open Settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    UIApplication.shared.open(url)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding()
                }
            }
            .navigationTitle("Scan QR Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task {
                await checkCameraPermission()
            }
        }
    }

    private func checkCameraPermission() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            isAuthorized = true
        case .notDetermined:
            isAuthorized = await AVCaptureDevice.requestAccess(for: .video)
            if !isAuthorized {
                showingPermissionDenied = true
            }
        case .denied, .restricted:
            showingPermissionDenied = true
        @unknown default:
            showingPermissionDenied = true
        }
    }

    private func handleScan(_ code: String) {
        // Parse the QR code JSON
        guard let data = code.data(using: .utf8),
              let pairingInfo = try? JSONDecoder().decode(PairingInfo.self, from: data) else {
            errorMessage = "Invalid QR code format"
            return
        }

        // Success - call the callback and dismiss
        onScan(pairingInfo)
        dismiss()
    }

    private func handleError(_ error: String) {
        errorMessage = error
    }
}

// MARK: - Pairing Info Model

struct PairingInfo: Codable {
    let host: String
    let port: Int
    let token: String
    let certFingerprint: String?  // SHA-256 fingerprint for TLS pinning
}

// MARK: - QR Scanner UIKit Wrapper

struct QRScannerRepresentable: UIViewControllerRepresentable {
    let onScan: (String) -> Void
    let onError: (String) -> Void

    func makeUIViewController(context: Context) -> QRScannerViewController {
        let controller = QRScannerViewController()
        controller.onScan = onScan
        controller.onError = onError
        return controller
    }

    func updateUIViewController(_ uiViewController: QRScannerViewController, context: Context) {}
}

class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onScan: ((String) -> Void)?
    var onError: ((String) -> Void)?

    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var hasScanned = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupCamera()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        startScanning()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopScanning()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    private func setupCamera() {
        let session = AVCaptureSession()

        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else {
            onError?("Failed to access camera")
            return
        }

        if session.canAddInput(input) {
            session.addInput(input)
        }

        let output = AVCaptureMetadataOutput()
        if session.canAddOutput(output) {
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]
        }

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        preview.frame = view.bounds
        view.layer.addSublayer(preview)

        captureSession = session
        previewLayer = preview
    }

    private func startScanning() {
        hasScanned = false
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.captureSession?.startRunning()
        }
    }

    private func stopScanning() {
        captureSession?.stopRunning()
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !hasScanned,
              let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let code = object.stringValue else {
            return
        }

        hasScanned = true

        // Haptic feedback
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)

        stopScanning()
        onScan?(code)
    }
}

#Preview {
    QRScannerView { info in
        print("Scanned: \(info)")
    }
}
