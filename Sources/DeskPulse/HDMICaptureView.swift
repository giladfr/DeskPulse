@preconcurrency import AVFoundation
import CoreMedia
import SwiftUI

@MainActor
final class HDMICaptureModel: ObservableObject {
    enum State: Equatable {
        case idle
        case requestingPermission
        case connecting
        case live(String, String)
        case unavailable(String)
    }

    let session = AVCaptureSession()
    @Published private(set) var state: State = .idle

    private let queue = DispatchQueue(label: "com.giladfride.DeskPulse.hdmi-capture", qos: .userInteractive)
    private var configuredDeviceID: String?

    func start(targetSize: CGSize) {
        guard state != .requestingPermission else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStart(targetSize: targetSize)
        case .notDetermined:
            state = .requestingPermission
            NSApplication.shared.activate(ignoringOtherApps: true)
            AVCaptureDevice.requestAccess(for: .video) { @Sendable [weak self] allowed in
                Task { @MainActor in
                    guard let self else { return }
                    if allowed {
                        self.configureAndStart(targetSize: targetSize)
                    } else {
                        self.state = .unavailable("Camera access is required for the HDMI capture card.")
                    }
                }
            }
        default:
            state = .unavailable("Camera access is disabled. Enable DeskPulse in System Settings → Privacy & Security → Camera.")
        }
    }

    func stop() {
        let session = session
        queue.async {
            if session.isRunning { session.stopRunning() }
        }
        state = .idle
    }

    private func configureAndStart(targetSize: CGSize) {
        state = .connecting
        let session = session
        let previousID = configuredDeviceID
        queue.async { [weak self] in
            let discovery = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.external], mediaType: .video, position: .unspecified
            )
            let devices = discovery.devices
            guard let device = devices.first(where: {
                let name = $0.localizedName.lowercased()
                return name.contains("ugreen") || name.contains("15389") || name.contains("cm629")
            }) ?? devices.first else {
                Task { @MainActor in self?.state = .unavailable("No USB HDMI capture card was found.") }
                return
            }

            do {
                if previousID != device.uniqueID || session.inputs.isEmpty {
                    session.beginConfiguration()
                    defer { session.commitConfiguration() }
                    session.inputs.forEach(session.removeInput)
                    if session.canSetSessionPreset(.high) {
                        session.sessionPreset = .high
                    }
                    let input = try AVCaptureDeviceInput(device: device)
                    guard session.canAddInput(input) else {
                        throw CaptureError.cannotAddInput
                    }
                    session.addInput(input)
                    let format = Self.bestFormat(for: device, targetSize: targetSize)
                    try device.lockForConfiguration()
                    if let format {
                        device.activeFormat = format
                    }
                    device.unlockForConfiguration()
                }
                if !session.isRunning { session.startRunning() }
                let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
                let fps = Self.preferredFPS(for: device.activeFormat)
                Task { @MainActor in
                    self?.configuredDeviceID = device.uniqueID
                    self?.state = .live(device.localizedName, "\(dimensions.width)×\(dimensions.height) · \(fps) fps")
                }
            } catch {
                Task { @MainActor in self?.state = .unavailable("Could not start \(device.localizedName): \(error.localizedDescription)") }
            }
        }
    }

    nonisolated private static func bestFormat(for device: AVCaptureDevice, targetSize: CGSize) -> AVCaptureDevice.Format? {
        let targetAspect = max(targetSize.width, 1) / max(targetSize.height, 1)
        return device.formats.max { lhs, rhs in
            formatScore(lhs, targetAspect: targetAspect) < formatScore(rhs, targetAspect: targetAspect)
        }
    }

    nonisolated private static func formatScore(_ format: AVCaptureDevice.Format, targetAspect: CGFloat) -> Double {
        let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let aspect = Double(size.width) / Double(max(size.height, 1))
        let aspectPenalty = abs(aspect - Double(targetAspect)) * 12_000_000
        let pixels = Double(size.width * size.height)
        let fps = Double(preferredFPS(for: format))
        return pixels + min(fps, 60) * 100_000 - aspectPenalty
    }

    nonisolated private static func preferredFPS(for format: AVCaptureDevice.Format) -> Int32 {
        let maximum = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 30
        return Int32(maximum >= 60 ? 60 : maximum >= 30 ? 30 : max(1, Int(maximum)))
    }

    private enum CaptureError: LocalizedError {
        case cannotAddInput
        var errorDescription: String? { "The capture input is not supported by this session." }
    }
}

struct HDMICaptureView: View {
    @ObservedObject var model: HDMICaptureModel
    let onExit: () -> Void
    @State private var fillsScreen = false
    @State private var controlsVisible = true

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black
                CapturePreview(session: model.session, fillsScreen: fillsScreen)
                    .ignoresSafeArea()

                if case .unavailable(let message) = model.state {
                    ContentUnavailableView("HDMI input unavailable", systemImage: "video.slash.fill", description: Text(message))
                        .foregroundStyle(.white)
                } else if model.state == .connecting || model.state == .requestingPermission {
                    ProgressView(model.state == .requestingPermission ? "Waiting for camera access…" : "Connecting to HDMI input…")
                        .controlSize(.large)
                        .padding(24)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
                }

                if controlsVisible {
                    controls
                        .transition(.opacity)
                }
            }
            .contentShape(Rectangle())
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.16)) { controlsVisible = hovering }
            }
            .onAppear { model.start(targetSize: proxy.size) }
            .onDisappear { model.stop() }
        }
        .background(Color.black)
    }

    private var controls: some View {
        VStack {
            HStack(spacing: 10) {
                Button(action: onExit) {
                    Label("DeskPulse", systemImage: "square.grid.2x2.fill")
                }
                .keyboardShortcut(.escape, modifiers: [])

                Spacer()

                if case .live(let name, let format) = model.state {
                    Label("LIVE", systemImage: "circle.fill")
                        .foregroundStyle(.red)
                        .help("\(name) · \(format)")
                }
                Button {
                    fillsScreen.toggle()
                } label: {
                    Label(
                        fillsScreen ? "Fill · crops edges" : "Fit · entire screen",
                        systemImage: fillsScreen ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left"
                    )
                }
                .help(fillsScreen ? "Fill the Mac display by cropping the HDMI image's sides" : "Preserve the entire HDMI image without cropping")
            }
            .font(.system(size: 13, weight: .semibold))
            .buttonStyle(.borderedProminent)
            .tint(Color.black.opacity(0.72))
            .padding(16)
            Spacer()
        }
    }
}

private struct CapturePreview: NSViewRepresentable {
    let session: AVCaptureSession
    let fillsScreen: Bool

    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        return view
    }

    func updateNSView(_ view: PreviewView, context: Context) {
        view.previewLayer.videoGravity = fillsScreen ? .resizeAspectFill : .resizeAspect
        // The CM629 pillarboxes a 1920×1200 HDMI signal inside its 16:9 UVC
        // frame. A little overscan in Fill mode removes that embedded matte.
        view.overscan = fillsScreen ? 0.04 : 0
        view.needsLayout = true
    }

    final class PreviewView: NSView {
        let previewLayer = AVCaptureVideoPreviewLayer()
        var overscan: CGFloat = 0

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer = previewLayer
            previewLayer.backgroundColor = NSColor.black.cgColor
        }

        required init?(coder: NSCoder) { nil }

        override func layout() {
            super.layout()
            previewLayer.frame = bounds.insetBy(
                dx: -(bounds.width * overscan),
                dy: 0
            )
        }
    }
}
