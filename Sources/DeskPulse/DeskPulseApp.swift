import SwiftUI

@main
struct DeskPulseApp: App {
    @StateObject private var model = DashboardModel()

    var body: some Scene {
        WindowGroup {
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
    }
}
