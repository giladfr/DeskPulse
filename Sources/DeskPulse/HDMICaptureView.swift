@preconcurrency import AVFoundation
import CoreMedia
import CoreImage
import OSLog
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

    func start() {
        guard state != .requestingPermission else { return }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStart()
        case .notDetermined:
            state = .requestingPermission
            NSApplication.shared.activate(ignoringOtherApps: true)
            AVCaptureDevice.requestAccess(for: .video) { @Sendable [weak self] allowed in
                Task { @MainActor in
                    guard let self else { return }
                    if allowed {
                        self.configureAndStart()
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

    private func configureAndStart() {
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
                    let input = try AVCaptureDeviceInput(device: device)
                    guard session.canAddInput(input) else {
                        throw CaptureError.cannotAddInput
                    }
                    session.addInput(input)
                }

                guard let choice = Self.bestFormat(for: device) else {
                    throw CaptureError.noVideoFormat
                }
                // On macOS the session may re-apply its own format when it starts.
                // Holding the configuration lock across startRunning keeps ours, and
                // it is re-applied on every start because a stop can reset it too.
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                device.activeFormat = choice.format
                device.activeVideoMinFrameDuration = choice.frameDuration
                device.activeVideoMaxFrameDuration = choice.frameDuration
                if !session.isRunning { session.startRunning() }

                // Report what the device is actually running, not what was requested.
                let active = device.activeFormat
                let summary = Self.describe(active, frameDuration: device.activeVideoMinFrameDuration)
                Self.logger.info("HDMI capture: \(device.localizedName, privacy: .public) running \(summary, privacy: .public)")
                Task { @MainActor in
                    self?.configuredDeviceID = device.uniqueID
                    self?.state = .live(device.localizedName, summary)
                }
            } catch {
                Task { @MainActor in self?.state = .unavailable("Could not start \(device.localizedName): \(error.localizedDescription)") }
            }
        }
    }

    private struct FormatChoice {
        let format: AVCaptureDevice.Format
        let frameDuration: CMTime
    }

    nonisolated private static let logger = Logger(
        subsystem: "com.giladfride.DeskPulse",
        category: "HDMICapture"
    )

    /// HDMI sources rarely exceed 60 Hz, and faster UVC modes usually trade away resolution.
    nonisolated private static let maximumFrameRate = 60.0

    /// Ranks modes by smoothness first, then resolution, then image quality:
    /// a 60 fps mode beats any 30 fps one, a larger frame beats a smaller one at the
    /// same rate, and uncompressed video beats MJPEG at the same size and rate.
    nonisolated private static func bestFormat(for device: AVCaptureDevice) -> FormatChoice? {
        let candidates = device.formats.compactMap { format -> (FormatChoice, (Int, Int, Int))? in
            guard let duration = frameDuration(for: format) else { return nil }
            let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let fps = framesPerSecond(duration)
            let smoothness = fps >= 59 ? 2 : fps >= 29 ? 1 : 0
            let pixels = Int(size.width) * Int(size.height)
            let uncompressed = isCompressed(format) ? 0 : 1
            return (FormatChoice(format: format, frameDuration: duration), (smoothness, pixels, uncompressed))
        }
        for (choice, _) in candidates {
            logger.debug("HDMI capture mode available: \(describe(choice.format, frameDuration: choice.frameDuration), privacy: .public)")
        }
        return candidates.max { $0.1 < $1.1 }?.0
    }

    /// The fastest frame duration the format supports without exceeding `maximumFrameRate`.
    nonisolated private static func frameDuration(for format: AVCaptureDevice.Format) -> CMTime? {
        let ranges = format.videoSupportedFrameRateRanges
        if let fastest = ranges
            .filter({ $0.maxFrameRate <= maximumFrameRate + 0.5 })
            .max(by: { $0.maxFrameRate < $1.maxFrameRate }) {
            // Use the range's own duration so 59.94 Hz modes stay exact.
            return fastest.minFrameDuration
        }
        if ranges.contains(where: { $0.minFrameRate <= maximumFrameRate }) {
            return CMTime(value: 1, timescale: CMTimeScale(maximumFrameRate))
        }
        return ranges.min(by: { $0.maxFrameRate < $1.maxFrameRate })?.minFrameDuration
    }

    nonisolated private static func framesPerSecond(_ duration: CMTime) -> Double {
        let seconds = CMTimeGetSeconds(duration)
        return seconds > 0 ? 1 / seconds : 0
    }

    nonisolated private static func isCompressed(_ format: AVCaptureDevice.Format) -> Bool {
        let compressedCodecs: Set<FourCharCode> = [
            kCMVideoCodecType_JPEG,
            kCMVideoCodecType_JPEG_OpenDML,
            kCMVideoCodecType_H264,
            kCMVideoCodecType_HEVC
        ]
        return compressedCodecs.contains(
            CMFormatDescriptionGetMediaSubType(format.formatDescription)
        )
    }

    nonisolated private static func describe(
        _ format: AVCaptureDevice.Format,
        frameDuration: CMTime
    ) -> String {
        let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let fps = framesPerSecond(frameDuration)
        let rate = abs(fps - fps.rounded()) < 0.01
            ? String(Int(fps.rounded()))
            : String(format: "%.2f", fps)
        let code = CMFormatDescriptionGetMediaSubType(format.formatDescription)
        let fourCC = String([24, 16, 8, 0].map {
            Character(UnicodeScalar(UInt8(truncatingIfNeeded: code >> $0)))
        })
        let encoding = isCompressed(format) ? "compressed" : "uncompressed"
        return "\(size.width)×\(size.height) · \(rate) fps · \(encoding) (\(fourCC))"
    }

    private enum CaptureError: LocalizedError {
        case cannotAddInput
        case noVideoFormat

        var errorDescription: String? {
            switch self {
            case .cannotAddInput: "The capture input is not supported by this session."
            case .noVideoFormat: "The capture card did not report a usable video mode."
            }
        }
    }
}

struct HDMICaptureView: View {
    @ObservedObject var model: HDMICaptureModel
    let onExit: () -> Void
    @State private var fillsScreen = false
    @State private var enhancesColor = true
    @State private var controlsVisible = true

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black
                CapturePreview(
                    session: model.session,
                    fillsScreen: fillsScreen,
                    enhancesColor: enhancesColor
                )
                .frame(
                    width: proxy.size.width + proxy.safeAreaInsets.leading + proxy.safeAreaInsets.trailing,
                    height: proxy.size.height + proxy.safeAreaInsets.top + proxy.safeAreaInsets.bottom
                )
                .offset(
                    x: (proxy.safeAreaInsets.trailing - proxy.safeAreaInsets.leading) / 2,
                    y: (proxy.safeAreaInsets.bottom - proxy.safeAreaInsets.top) / 2
                )
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
            .onAppear { model.start() }
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
                Button {
                    enhancesColor.toggle()
                } label: {
                    Label(enhancesColor ? "Vivid" : "Natural", systemImage: "circle.lefthalf.filled")
                }
                .help(enhancesColor ? "Subtle contrast and saturation correction is on" : "Show the capture card's unadjusted colors")
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
    let enhancesColor: Bool

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
        if enhancesColor {
            let color = CIFilter(name: "CIColorControls")
            color?.setValue(1.08, forKey: kCIInputSaturationKey)
            color?.setValue(1.04, forKey: kCIInputContrastKey)
            color?.setValue(-0.005, forKey: kCIInputBrightnessKey)
            view.previewLayer.filters = color.map { [$0] } ?? []
        } else {
            view.previewLayer.filters = []
        }
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
