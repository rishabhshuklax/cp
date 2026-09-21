import AppKit
import Carbon.HIToolbox

/// What the UI needs from `Paster`, so the paste stack and the format chip can
/// be driven by a fake in tests instead of by real ⌘V keystrokes.
///
/// `Paster` conforms as it stands; this adds nothing to it but a seam.
@MainActor
public protocol PasteWriting: AnyObject {
    var canPaste: Bool { get }
    func requestPermission()
    @discardableResult func write(_ payload: PastePayload) -> Int
    func paste(into target: NSRunningApplication?, automatic: Bool, completion: @escaping @MainActor (PasteOutcome) -> Void)
    func replaceLastPaste(with payload: PastePayload, in target: NSRunningApplication?, completion: @escaping @MainActor (PasteOutcome) -> Void)
}

extension Paster: PasteWriting {}

/// Somewhere to run a closure a little later. Real time in the app, controlled
/// time in tests — the paste stack is all about the gaps between pastes.
public protocol Scheduling: Sendable {
    func run(after delay: TimeInterval, _ work: @escaping @MainActor () -> Void)
}

public struct MainQueueScheduler: Scheduling {
    public init() {}

    public func run(after delay: TimeInterval, _ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated { work() }
        }
    }
}

extension HotKeyCombo {
    /// The modifier you keep held down to switch instead of picking.
    ///
    /// ⌘ for the ⇧⌘V default. For a shortcut without ⌘ it is whichever
    /// modifier the shortcut leads with, so "hold it and tap the key again"
    /// means the same thing whatever the shortcut is.
    public var anchorModifier: NSEvent.ModifierFlags {
        if modifiers & UInt32(cmdKey) != 0 { return .command }
        if modifiers & UInt32(controlKey) != 0 { return .control }
        if modifiers & UInt32(optionKey) != 0 { return .option }
        return .shift
    }
}
