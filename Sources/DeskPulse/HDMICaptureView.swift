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
    private let lastDeviceStorageKey = "hdmi.capture-device.v1"
    /// True between start() and stop(); recovery only runs while the viewer is open.
    private var isActive = false
    /// Bumped on every start/stop so a slow, superseded start cannot report late.
    private var generation = 0
    private var recoveryAttempts = 0
    private var recoveryTask: Task<Void, Never>?
    nonisolated(unsafe) private var observers: [any NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(
                forName: AVCaptureDevice.wasConnectedNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.deviceConnected() }
            },
            center.addObserver(
                forName: AVCaptureDevice.wasDisconnectedNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let deviceID = (notification.object as? AVCaptureDevice)?.uniqueID
                MainActor.assumeIsolated { self?.deviceDisconnected(deviceID) }
            },
            center.addObserver(
                forName: AVCaptureSession.runtimeErrorNotification,
                object: session,
                queue: .main
            ) { [weak self] notification in
                let error = notification.userInfo?[AVCaptureSessionErrorKey] as? Error
                let message = error?.localizedDescription ?? "Unknown capture error"
                MainActor.assumeIsolated { self?.sessionFailed(message) }
            }
        ]
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func start() {
        isActive = true
        recoveryAttempts = 0
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
        isActive = false
        generation &+= 1
        recoveryTask?.cancel()
        recoveryTask = nil
        let session = session
        queue.async {
            if session.isRunning { session.stopRunning() }
        }
        state = .idle
    }

    // MARK: Recovery

    private func deviceConnected() {
        // A card plugged in while the viewer waits for one starts immediately.
        guard isActive, !isLive else { return }
        recoveryAttempts = 0
        configureAndStart()
    }

    private func deviceDisconnected(_ deviceID: String?) {
        guard deviceID != nil, deviceID == configuredDeviceID else { return }
        forgetInputs()
        guard isActive else { return }
        generation &+= 1
        recoveryTask?.cancel()
        state = .unavailable("The HDMI capture card was disconnected. Reconnect it to continue.")
    }

    private func sessionFailed(_ message: String) {
        Self.logger.error("HDMI capture runtime error: \(message, privacy: .public)")
        guard isActive else { return }
        forgetInputs()
        guard recoveryAttempts < 3 else {
            state = .unavailable("The HDMI capture stopped: \(message)")
            return
        }
        recoveryAttempts += 1
        state = .connecting
        let delay = Double(recoveryAttempts)
        recoveryTask?.cancel()
        recoveryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.isActive else { return }
            self.configureAndStart()
        }
    }

    /// Drops the session's inputs so the next start rebuilds them from scratch.
    private func forgetInputs() {
        configuredDeviceID = nil
        let session = session
        queue.async {
            if session.isRunning { session.stopRunning() }
            session.beginConfiguration()
            session.inputs.forEach(session.removeInput)
            session.commitConfiguration()
        }
    }

    private var isLive: Bool {
        if case .live = state { return true }
        return false
    }

    /// Applies a result from the capture queue unless a later start or stop replaced it.
    private func report(_ generation: Int, _ update: (HDMICaptureModel) -> Void) {
        guard generation == self.generation, isActive else { return }
        update(self)
    }

    // MARK: Configuration

    private func configureAndStart() {
        generation &+= 1
        let generation = generation
        state = .connecting
        let session = session
        let previousID = configuredDeviceID
        let rememberedID = UserDefaults.standard.string(forKey: lastDeviceStorageKey)
        queue.async { [weak self] in
            let discovery = AVCaptureDevice.DiscoverySession(
                deviceTypes: [.external], mediaType: .video, position: .unspecified
            )
            let devices = discovery.devices
            // Prefer the card that worked last time, then a known capture-card name,
            // and only then any other external camera.
            guard let device = devices.first(where: { $0.uniqueID == rememberedID })
                ?? devices.first(where: {
                    let name = $0.localizedName.lowercased()
                    return name.contains("ugreen") || name.contains("15389") || name.contains("cm629")
                })
                ?? devices.first
            else {
                Task { @MainActor in
                    self?.report(generation) {
                        $0.state = .unavailable("No USB HDMI capture card was found. Connect one to start.")
                    }
                }
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
                let deviceID = device.uniqueID
                let deviceName = device.localizedName
                Task { @MainActor in
                    self?.report(generation) {
                        $0.configuredDeviceID = deviceID
                        $0.recoveryAttempts = 0
                        $0.state = .live(deviceName, summary)
                        UserDefaults.standard.set(deviceID, forKey: $0.lastDeviceStorageKey)
                    }
                }
            } catch {
                let message = "Could not start \(device.localizedName): \(error.localizedDescription)"
                Task { @MainActor in
                    self?.report(generation) { $0.state = .unavailable(message) }
                }
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
    @State private var enhancesColor = false
    @State private var controlsVisible = true
    @State private var pointerOverControls = false
    @State private var hideControlsTask: Task<Void, Never>?

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

                // Kept in the hierarchy while hidden so the Escape shortcut always works.
                controls
                    .opacity(controlsVisible ? 1 : 0)
                    .allowsHitTesting(controlsVisible)
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active: showControlsBriefly()
                case .ended: scheduleControlsHide(after: 0.3)
                }
            }
            .onChange(of: model.state) { _, _ in showControlsBriefly() }
            .onAppear {
                model.start()
                showControlsBriefly()
            }
            .onDisappear {
                hideControlsTask?.cancel()
                model.stop()
            }
        }
        .background(Color.black)
    }

    /// Shows the toolbar on pointer movement and hides it, with the cursor, once idle,
    /// so the full HDMI picture stays unobstructed.
    private func showControlsBriefly() {
        if !controlsVisible {
            withAnimation(.easeOut(duration: 0.16)) { controlsVisible = true }
        }
        scheduleControlsHide(after: 2.5)
    }

    private func scheduleControlsHide(after seconds: Double) {
        hideControlsTask?.cancel()
        hideControlsTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            // Keep the toolbar up while it is in use or while there is no live picture.
            guard !Task.isCancelled, !pointerOverControls, case .live = model.state else { return }
            withAnimation(.easeOut(duration: 0.3)) { controlsVisible = false }
            NSCursor.setHiddenUntilMouseMoves(true)
        }
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
            .onHover { hovering in
                pointerOverControls = hovering
                if !hovering { showControlsBriefly() }
            }
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
            // AppKit owns the geometry of a view's backing layer, so the preview is a
            // sublayer whose frame this view controls; the backing layer clips it.
            wantsLayer = true
            layer?.backgroundColor = NSColor.black.cgColor
            layer?.masksToBounds = true
            previewLayer.backgroundColor = NSColor.black.cgColor
            layer?.addSublayer(previewLayer)
        }

        required init?(coder: NSCoder) { nil }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            previewLayer.frame = bounds.insetBy(
                dx: -(bounds.width * overscan),
                dy: 0
            )
            CATransaction.commit()
        }
    }
}
