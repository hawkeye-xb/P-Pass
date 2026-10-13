import AVFoundation
import SwiftUI

/// 扫码页（对位 Android ScanScreen.kt）：深色底，「✕ + 扫码连接」，圆角取景框 + 提示，底部「手动输入」。
/// 只接受以 `ppf://pair` 开头的二维码内容。没有相机（模拟器）或相机权限被拒时，取景框位置换成说明。
struct ScanScreen: View {
    let onCode: (String) -> Void
    let onManual: () -> Void
    let onClose: () -> Void
    @State private var cameraState: CameraState = .checking

    enum CameraState { case checking, ready, unavailable }

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.body.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .background(.regularMaterial, in: Circle())
                }
                .accessibilityLabel(L.s("back"))
                Text(L.s("scan_header_title")).font(.headline)
                Spacer()
            }
            Spacer()
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(.white.opacity(0.7), lineWidth: 2)
                switch cameraState {
                case .ready: QRScannerView { code in if let c = PairCode.normalized(code) { Haptics.success(); onCode(c) } }
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                case .checking: ProgressView()
                case .unavailable:
                    Text(L.s("scan_camera_unavailable")).font(.body).multilineTextAlignment(.center).padding(20)
                }
            }
            .frame(width: 260, height: 260)
            Text(L.s("scan_hint")).font(.body).multilineTextAlignment(.center).foregroundStyle(.secondary)
            Spacer()
            Button(L.s("scan_manual_link"), action: onManual)
                .font(.body.weight(.medium)).frame(minHeight: 48)
                .accessibilityIdentifier("manualLink")
        }
        .padding(20)
        // 相机取景天然是深色界面：固定深色外观 + 黑底，不跟随系统浅色。
        .preferredColorScheme(.dark)
        .foregroundStyle(.primary)
        .tint(.white)
        .background(Color(uiColor: .black).ignoresSafeArea())
        .task { cameraState = await Self.cameraAvailable() ? .ready : .unavailable }
    }

    static func cameraAvailable() async -> Bool {
        guard AVCaptureDevice.default(for: .video) != nil else { return false }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }
}

/// AVFoundation 的二维码识别，读到第一串就停。
struct QRScannerView: UIViewRepresentable {
    let onCode: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        let session = AVCaptureSession()
        if let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
            let output = AVCaptureMetadataOutput()
            if session.canAddOutput(output) {
                session.addOutput(output)
                output.setMetadataObjectsDelegate(context.coordinator, queue: .main)
                output.metadataObjectTypes = [.qr]
            }
        }
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        context.coordinator.session = session
        DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    static func dismantleUIView(_ uiView: PreviewView, coordinator: Coordinator) { coordinator.session?.stopRunning() }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        let onCode: (String) -> Void
        var session: AVCaptureSession?
        private var done = false
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
            guard !done, let value = (objects.first as? AVMetadataMachineReadableCodeObject)?.stringValue,
                  PairCode.normalized(value) != nil else { return }
            done = true
            session?.stopRunning()
            onCode(value)
        }
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
