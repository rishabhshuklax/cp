import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Whether macOS lets cp read the clipboard at all (macOS 15.4 and later).
///
/// Read through a closure rather than straight off `NSPasteboard.general`, so
/// a test never has to touch the real clipboard to draw this row.
public enum ClipboardAccess: Equatable, Sendable {
    case allowed
    case ask
    case notAllowed

    public var label: String {
        switch self {
        case .allowed: return "Allowed"
        case .ask: return "Ask each time"
        case .notAllowed: return "Not allowed"
        }
    }

    /// `nil` before macOS 15.4, where there is no such setting to show.
    public static func current(_ pasteboard: @autoclosure () -> NSPasteboard = .general) -> ClipboardAccess? {
        guard #available(macOS 15.4, *) else { return nil }
        switch pasteboard().accessBehavior {
        case .alwaysAllow: return .allowed
        case .alwaysDeny: return .notAllowed
        default: return .ask
        }
    }
}

/// Turns a key press into a shortcut, or rejects it.
public enum HotKeyRecorder {

    /// A shortcut needs a real modifier: ⇧V alone would fire every time you
    /// typed a capital V. esc is the way out and is never a shortcut.
    public static func combo(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> HotKeyCombo? {
        guard Int(keyCode) != kVK_Escape else { return nil }
        let flags = modifiers.intersection([.command, .control, .option, .shift])
        guard flags.contains(.command) || flags.contains(.control) || flags.contains(.option) else { return nil }
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        return HotKeyCombo(keyCode: UInt32(keyCode), modifiers: carbon)
    }
}

/// The shortcut recorder: click it, press the combination, and it is live.
public struct ShortcutRecorder: View {

    private let combo: HotKeyCombo
    private let failed: Bool
    private let record: (HotKeyCombo) -> Void

    @State private var isRecording = false
    @State private var monitor: Any?

    public init(combo: HotKeyCombo, failed: Bool, record: @escaping (HotKeyCombo) -> Void) {
        self.combo = combo
        self.failed = failed
        self.record = record
    }

    public var body: some View {
        HStack(spacing: 8) {
            if failed, !isRecording {
                Text("Taken by another app")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.danger)
            }
            Button {
                isRecording ? stop() : start()
            } label: {
                Text(isRecording ? "Press keys…" : combo.displayString)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isRecording ? Theme.accent : Theme.ink)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(isRecording ? Theme.selection : Theme.hover,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(isRecording ? Theme.selectionEdge : Theme.line, lineWidth: 1)
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .onDisappear { stop() }
    }

    private func start() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            // Read off the event before hopping actors: NSEvent is not Sendable.
            let keyCode = event.keyCode
            let flags = event.modifierFlags
            MainActor.assumeIsolated {
                if Int(keyCode) == kVK_Escape {
                    stop()
                    return
                }
                // Not a shortcut yet: keep listening rather than beeping.
                guard let combo = HotKeyRecorder.combo(keyCode: keyCode, modifiers: flags) else { return }
                record(combo)
                stop()
            }
            // While recording, every key belongs to the recorder.
            return nil
        }
    }

    private func stop() {
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// One line: a label, and the control that changes it.
public struct SettingRow<Content: View>: View {

    private let label: String
    private let isLast: Bool
    private let content: () -> Content

    public init(_ label: String, isLast: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.label = label
        self.isLast = isLast
        self.content = content
    }

    public var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(Theme.Font.settingsRow)
                .foregroundStyle(Theme.ink)
            Spacer(minLength: 8)
            content()
                .font(.system(size: 13))
                .foregroundStyle(Theme.ink2)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 46)
        .overlay(alignment: .bottom) {
            if !isLast {
                Rectangle().fill(Theme.line).frame(height: 1)
            }
        }
    }
}

/// A row that is only a verb, and a destructive one.
public struct SettingDangerRow: View {

    private let title: String
    private let action: () -> Void

    public init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(Theme.Font.settingsRow)
                    .foregroundStyle(Theme.danger)
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 46)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A group of rows. Grouping is the only structure Settings gets — there are no
/// paragraphs anywhere in here.
public struct SettingCard<Content: View>: View {

    private let content: () -> Content

    public init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    public var body: some View {
        VStack(spacing: 0) {
            content()
        }
        .background(Theme.wash, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.line, lineWidth: 1)
        }
        .padding(.bottom, 14)
    }
}
