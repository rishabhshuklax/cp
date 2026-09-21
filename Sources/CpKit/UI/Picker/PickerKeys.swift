import AppKit
import Carbon.HIToolbox

/// Everything the picker does with a key.
public enum PickerKey: Equatable, Sendable {
    case up
    case down
    /// ↩ — paste in the default format.
    case paste
    /// ⌥↩ — paste as plain text.
    case pastePlain
    /// ⇧↩ — add to, or take out of, the stack.
    case stackToggle
    /// ⌘↩ — paste the stack in order when there is one, else paste.
    case stackPaste
    case escape
    case tab
    /// Space — Look, but only when nothing has been typed.
    case space
    /// ⌘Y — Look.
    case look
    /// ⌘K — the actions list.
    case actions
    case pin
    case delete
    case undo
    /// ⌘1…⌘9 — paste that row.
    case row(Int)
    /// ⌫ — removes the last filter, but only when nothing has been typed.
    case backspace
    case settings
}

/// Key codes to picker keys.
///
/// Matching is on the virtual key code and the four modifier flags, never on
/// characters: ⌥1 arrives as `¡`, ⇧⌘V as `√` on some layouts, and a key code
/// means the same thing on every layout there is.
public enum PickerKeys {

    public static func key(for event: NSEvent) -> PickerKey? {
        key(keyCode: event.keyCode, modifiers: event.modifierFlags)
    }

    public static func key(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> PickerKey? {
        let flags = modifiers.intersection([.command, .option, .shift, .control])
        switch (Int(keyCode), flags) {
        case (kVK_UpArrow, []): return .up
        case (kVK_DownArrow, []): return .down
        case (kVK_Return, []), (kVK_ANSI_KeypadEnter, []): return .paste
        case (kVK_Return, [.option]): return .pastePlain
        case (kVK_Return, [.shift]): return .stackToggle
        case (kVK_Return, [.command]): return .stackPaste
        case (kVK_Escape, []): return .escape
        case (kVK_Tab, []): return .tab
        case (kVK_Space, []): return .space
        case (kVK_ANSI_Y, [.command]): return .look
        case (kVK_ANSI_K, [.command]): return .actions
        case (kVK_ANSI_P, [.command]): return .pin
        case (kVK_Delete, [.command]): return .delete
        case (kVK_Delete, []): return .backspace
        case (kVK_ANSI_Z, [.command]): return .undo
        case (kVK_ANSI_Comma, [.command]): return .settings
        case (let code, [.command]):
            guard let digit = digits[code] else { return nil }
            return .row(digit)
        default: return nil
        }
    }

    /// Key codes for 1…9, which are not in numeric order on any layout.
    private static let digits: [Int: Int] = [
        kVK_ANSI_1: 1, kVK_ANSI_2: 2, kVK_ANSI_3: 3, kVK_ANSI_4: 4, kVK_ANSI_5: 5,
        kVK_ANSI_6: 6, kVK_ANSI_7: 7, kVK_ANSI_8: 8, kVK_ANSI_9: 9,
    ]
}

/// What the actions list does with a key. Its own small map, because while it
/// is open it owns ↑ ↓ ↩ esc and everything else belongs to its filter field.
public enum ActionKey: Equatable, Sendable {
    case up
    case down
    case run
    case close
}

public enum ActionKeys {

    public static func key(for event: NSEvent) -> ActionKey? {
        key(keyCode: event.keyCode, modifiers: event.modifierFlags)
    }

    public static func key(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> ActionKey? {
        let flags = modifiers.intersection([.command, .option, .shift, .control])
        switch (Int(keyCode), flags) {
        case (kVK_UpArrow, []): return .up
        case (kVK_DownArrow, []): return .down
        case (kVK_Return, []), (kVK_ANSI_KeypadEnter, []): return .run
        case (kVK_Escape, []), (kVK_ANSI_K, [.command]): return .close
        default: return nil
        }
    }
}
