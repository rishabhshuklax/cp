import AppKit
import Carbon.HIToolbox
import Foundation

/// A system-wide hotkey.
///
/// Carbon's `RegisterEventHotKey` is still the right call in 2026, and there is no
/// modern replacement. The alternatives both fail for this use:
/// `NSEvent.addGlobalMonitorForEvents` can observe a keystroke but not *consume*
/// it, so the shortcut also reaches the app underneath, and a `CGEventTap` needs
/// Accessibility permission just to bind a key — which would put a permission
/// prompt in front of first launch for something that does not need one.
public final class GlobalHotKey {

    public struct Combination: Equatable, Sendable {
        public let keyCode: UInt32
        public let modifiers: UInt32

        public init(keyCode: UInt32, modifiers: UInt32) {
            self.keyCode = keyCode
            self.modifiers = modifiers
        }

        /// ⇧⌘V — the shortcut every clipboard manager on the platform has trained
        /// people to reach for.
        public static let shiftCommandV = Combination(
            keyCode: UInt32(kVK_ANSI_V),
            modifiers: UInt32(cmdKey | shiftKey)
        )
    }

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let identifier: UInt32
    private var handler: (() -> Void)?

    /// Carbon dispatches to a C callback with no context pointer we can rely on
    /// across registrations, so instances register themselves here by id.
    private static var registry: [UInt32: GlobalHotKey] = [:]
    private static var nextIdentifier: UInt32 = 1

    public init() {
        self.identifier = Self.nextIdentifier
        Self.nextIdentifier += 1
    }

    deinit {
        unregisterWithoutCleanup()
    }

    @discardableResult
    public func register(_ combination: Combination, handler: @escaping () -> Void) -> Bool {
        unregister()
        self.handler = handler
        Self.registry[identifier] = self

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else { return status }

                let id = hotKeyID.id
                DispatchQueue.main.async {
                    GlobalHotKey.registry[id]?.handler?()
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            &eventHandler
        )
        guard installStatus == noErr else { return false }

        let hotKeyID = EventHotKeyID(signature: OSType(0x6370_6B79), id: identifier)  // 'cpky'
        let registerStatus = RegisterEventHotKey(
            combination.keyCode,
            combination.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        return registerStatus == noErr
    }

    public func unregister() {
        unregisterWithoutCleanup()
        Self.registry[identifier] = nil
        handler = nil
    }

    private func unregisterWithoutCleanup() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }
}
