@preconcurrency import AVFoundation
import SwiftUI

/// Seam over the camera so UI tests can drive check-in deterministically.
protocol ScannerProviding: Sendable {
    @MainActor func cameraPermission() -> CheckInStateMachine.CameraPermission
    func requestCameraAccess() async -> Bool
    @MainActor func makeScannerView(isActive: Bool, onCode: @escaping @MainActor (String) -> Void) -> AnyView
}

struct CameraScannerProvider: ScannerProviding {
    @MainActor func cameraPermission() -> CheckInStateMachine.CameraPermission {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: .authorized
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    func requestCameraAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    @MainActor func makeScannerView(isActive: Bool, onCode: @escaping @MainActor (String) -> Void) -> AnyView {
        AnyView(CameraQRScannerView(isActive: isActive, onCode: onCode))
    }
}

/// Live AVFoundation QR scanner: a preview layer plus a metadata output restricted to QR.
struct CameraQRScannerView: UIViewRepresentable {
    let isActive: Bool
    let onCode: @MainActor (String) -> Void

    func makeUIView(context: Context) -> ScannerPreviewView {
        let view = ScannerPreviewView()
        view.controller.onCode = onCode
        view.controller.configure(previewLayer: view.previewLayer)
        return view
    }

    func updateUIView(_ uiView: ScannerPreviewView, context: Context) {
        uiView.controller.onCode = onCode
        isActive ? uiView.controller.start() : uiView.controller.stop()
    }

    static func dismantleUIView(_ uiView: ScannerPreviewView, coordinator: ()) {
        uiView.controller.stop()
    }
}

final class ScannerPreviewView: UIView {
    let controller = ScannerSessionController()
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

/// Owns the capture session on a private serial queue (AVCaptureSession is not Sendable).
final class ScannerSessionController: NSObject, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "lk.zuno.scanner")
    private var configured = false
    @MainActor var onCode: (@MainActor (String) -> Void)?

    @MainActor func configure(previewLayer: AVCaptureVideoPreviewLayer) {
        previewLayer.session = session
        previewLayer.videoGravity = .resizeAspectFill
        queue.async { [self] in
            guard !configured else { return }
            session.beginConfiguration()
            defer { session.commitConfiguration() }
            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else { return }
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: queue)
            output.metadataObjectTypes = [.qr]
            configured = true
        }
    }

    func start() { queue.async { [self] in if !session.isRunning { session.startRunning() } } }
    func stop() { queue.async { [self] in if session.isRunning { session.stopRunning() } } }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard let code = metadataObjects.compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }).first else { return }
        Task { @MainActor [weak self] in self?.onCode?(code) }
    }
}

#if DEBUG
/// UI-test scanner: no camera; "detects" a fixed code shortly after becoming active.
struct StubScannerProvider: ScannerProviding {
    let code: String
    @MainActor func cameraPermission() -> CheckInStateMachine.CameraPermission { .authorized }
    func requestCameraAccess() async -> Bool { true }
    @MainActor func makeScannerView(isActive: Bool, onCode: @escaping @MainActor (String) -> Void) -> AnyView {
        AnyView(
            ZStack {
                Color.black
                Label("Test scanner", systemImage: "qrcode.viewfinder").foregroundStyle(.white.opacity(0.6))
            }
            .task(id: isActive) {
                guard isActive else { return }
                try? await Task.sleep(for: .seconds(1.2))
                onCode(code)
            }
        )
    }
}
#endif
