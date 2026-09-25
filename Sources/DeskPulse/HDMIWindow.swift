import AppKit
import SwiftUI

enum DashboardWindow {
    static let id = "dashboard"
}

@MainActor
enum HDMIWindow {
    static let id = "hdmi"
    /// SwiftUI can restore windows at launch; the HDMI screen should only open on request.
    static var wasRequested = false
    /// The HDMI screen's window while it is open.
    static weak var window: NSWindow?
}

/// The HDMI input in its own full-screen window (and so its own Space), running
/// alongside the dashboard. Closing the window releases the capture card.
struct HDMIWindowView: View {
    @StateObject private var capture = HDMICaptureModel()
    @StateObject private var audio = HDMIAudio()
    @EnvironmentObject private var dashboard: DashboardModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    /// Alerts from before this screen opened were already visible on the dashboard.
    @State private var openedAt = Date()
    @State private var dismissedAlertID: UUID?

    /// A new incoming alert that hasn't been acknowledged on this screen yet.
    private var visibleAlert: IncomingAlert? {
        guard
            let alert = dashboard.latestIncomingAlert,
            alert.receivedAt >= openedAt,
            alert.id != dismissedAlertID
        else { return nil }
        return alert
    }

    var body: some View {
        if HDMIWindow.wasRequested {
            HDMICaptureView(
                model: capture,
                audio: audio,
                onShowDashboard: { openWindow(id: DashboardWindow.id) },
                onClose: { dismissWindow(id: HDMIWindow.id) }
            )
            // Sound follows the picture: it starts with the card's matching audio
            // input once video is live and stops when the card goes away.
            .onChange(of: capture.state) { _, state in
                switch state {
                case .live(let deviceName, _): audio.start(matching: deviceName)
                case .unavailable, .idle: audio.stop()
                case .connecting, .requestingPermission: break
                }
            }
            .onDisappear { audio.stop() }
            .background(FullScreenWindow { HDMIWindow.window = $0 })
            .overlay(alignment: .top) {
                if let alert = visibleAlert {
                    IncomingAlertBanner(
                        alert: alert,
                        onShowSituation: {
                            dismissedAlertID = alert.id
                            openWindow(id: DashboardWindow.id)
                        },
                        onDismiss: { dismissedAlertID = alert.id }
                    )
                    .padding(.top, 72)
                    .padding(.horizontal, 24)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.snappy(duration: 0.3), value: visibleAlert?.id)
            .onChange(of: dashboard.latestIncomingAlert?.id) { _, _ in
                guard visibleAlert != nil else { return }
                NSSound(named: NSSound.Name("Sosumi"))?.play()
            }
        } else {
            Color.black
                .onAppear { dismissWindow(id: HDMIWindow.id) }
        }
    }
}

/// Shown on the HDMI screen when the incoming-alert rule fires, since the dashboard
/// that switches to the situation layout is in another Space.
struct IncomingAlertBanner: View {
    let alert: IncomingAlert
    let onShowSituation: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 24, weight: .bold))
            VStack(alignment: .leading, spacing: 3) {
                Text("Incoming alert · \(alert.receivedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 11, weight: .heavy))
                    .textCase(.uppercase)
                    .tracking(0.8)
                    .opacity(0.85)
                Text(alert.title)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onShowSituation) {
                Label("Show situation", systemImage: "shield.lefthalf.filled")
                    .font(.system(size: 13, weight: .bold))
            }
            .buttonStyle(.borderedProminent)
            .tint(.white)
            .foregroundStyle(.red)
            .keyboardShortcut(.defaultAction)
            .help("Switch to the dashboard's situation layout (Return)")
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss this alert")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: 760)
        .background(Color(red: 0.78, green: 0.06, blue: 0.08).opacity(0.95), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.25)))
        .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
    }
}

/// Puts the hosting window into native full screen once it appears, giving it its
/// own Space that can be reached by swiping.
struct FullScreenWindow: NSViewRepresentable {
    /// Called with the hosting window once it is known.
    var onWindow: (NSWindow) -> Void = { _ in }

    func makeNSView(context: Context) -> NSView {
        WindowObserverView(onWindow: onWindow)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class WindowObserverView: NSView {
        private let onWindow: (NSWindow) -> Void
        private var didRequestFullScreen = false

        init(onWindow: @escaping (NSWindow) -> Void) {
            self.onWindow = onWindow
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, !didRequestFullScreen else { return }
            didRequestFullScreen = true
            onWindow(window)
            window.collectionBehavior.insert(.fullScreenPrimary)
            // Let the window finish appearing before it animates into its own Space.
            Task { @MainActor [weak window] in
                guard let window, !window.styleMask.contains(.fullScreen) else { return }
                window.toggleFullScreen(nil)
            }
        }
    }
}
