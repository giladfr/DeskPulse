import Carbon.HIToolbox
import Foundation

/// Posted when Control–Command–H is pressed anywhere, even while another app is active.
let toggleHDMIScreenNotification = Notification.Name("DeskPulse.toggleHDMIScreen")

/// A system-wide shortcut registered through Carbon's hot-key API, which works without
/// Accessibility permission. Only the key combination is observed, never other typing.
@MainActor
final class GlobalHotKey {
    static let shared = GlobalHotKey()

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    func registerToggleHDMIScreen() {
        guard hotKeyRef == nil else { return }
        var pressed = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, _ in
                NotificationCenter.default.post(name: toggleHDMIScreenNotification, object: nil)
                return OSStatus(noErr)
            },
            1,
            &pressed,
            nil,
            &handlerRef
        )
        // 'DPHS': DeskPulse HDMI screen.
        let id = EventHotKeyID(signature: OSType(0x4450_4853), id: 1)
        RegisterEventHotKey(
            UInt32(kVK_ANSI_H),
            UInt32(cmdKey | controlKey),
            id,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }
}
