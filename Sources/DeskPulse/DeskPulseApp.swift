import SwiftUI

@main
struct DeskPulseApp: App {
    @StateObject private var model = DashboardModel()

    var body: some Scene {
        // A single dashboard window, so "show the dashboard" from the HDMI screen
        // brings this one forward instead of opening another.
        Window("DeskPulse", id: DashboardWindow.id) {
            DashboardView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
                .frame(minWidth: 1100, minHeight: 700)
                .onAppear {
                    NSApplication.shared.presentationOptions = [
                        .autoHideDock, .autoHideMenuBar, .fullScreen
                    ]
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .windowArrangement) {
                Button("Enter Full Screen") {
                    NSApplication.shared.keyWindow?.toggleFullScreen(nil)
                }
                .keyboardShortcut("f", modifiers: [.command, .control])
            }
        }

        Window("HDMI Input", id: HDMIWindow.id) {
            HDMIWindowView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
                .frame(minWidth: 640, minHeight: 360)
        }
        .windowStyle(.hiddenTitleBar)
        // Opened from the dashboard's toolbar only, not from the Window menu.
        .commandsRemoved()
    }
}
