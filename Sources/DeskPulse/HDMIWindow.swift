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
}

/// The HDMI input in its own full-screen window (and so its own Space), running
/// alongside the dashboard. Closing the window releases the capture card.
struct HDMIWindowView: View {
    @StateObject private var capture = HDMICaptureModel()
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        if HDMIWindow.wasRequested {
            HDMICaptureView(
                model: capture,
                onShowDashboard: { openWindow(id: DashboardWindow.id) },
                onClose: { dismissWindow(id: HDMIWindow.id) }
            )
            .background(FullScreenWindow())
        } else {
            Color.black
                .onAppear { dismissWindow(id: HDMIWindow.id) }
        }
    }
}

/// Puts the hosting window into native full screen once it appears, giving it its
/// own Space that can be reached by swiping.
struct FullScreenWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        WindowObserverView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class WindowObserverView: NSView {
        private var didRequestFullScreen = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, !didRequestFullScreen else { return }
            didRequestFullScreen = true
            window.collectionBehavior.insert(.fullScreenPrimary)
            // Let the window finish appearing before it animates into its own Space.
            Task { @MainActor [weak window] in
                guard let window, !window.styleMask.contains(.fullScreen) else { return }
                window.toggleFullScreen(nil)
            }
        }
    }
}
