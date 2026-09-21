import AppKit
import Observation
import SwiftUI

/// What just happened, in four words, bottom centre.
///
/// It always names the app — "Pasted into Notes", not "Pasted" — because the
/// one failure mode of an invisible paste is landing somewhere you did not
/// mean. The Undo on a delete is the only one that waits around.
@Observable
@MainActor
public final class ToastCenter {

    public struct Toast: Equatable {
        public let text: String
        public let hasUndo: Bool
        public let token: Int
    }

    public private(set) var current: Toast?

    @ObservationIgnored private var undoAction: (() -> Void)?
    @ObservationIgnored private var token = 0
    @ObservationIgnored private var dismissal: Task<Void, Never>?

    public static let shortDuration: TimeInterval = 1.8
    public static let undoDuration: TimeInterval = 5

    public init() {}

    public func show(_ text: String, undo: (() -> Void)? = nil) {
        token += 1
        undoAction = undo
        current = Toast(text: text, hasUndo: undo != nil, token: token)
        let duration = undo == nil ? Self.shortDuration : Self.undoDuration
        dismissal?.cancel()
        let mine = token
        dismissal = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled, let self, self.token == mine else { return }
            self.dismiss()
        }
    }

    public func undo() {
        let action = undoAction
        dismiss()
        action?()
    }

    public func dismiss() {
        dismissal?.cancel()
        dismissal = nil
        undoAction = nil
        current = nil
    }
}

public struct ToastView: View {

    private let toast: ToastCenter.Toast
    private let undo: () -> Void

    public init(toast: ToastCenter.Toast, undo: @escaping () -> Void) {
        self.toast = toast
        self.undo = undo
    }

    public var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.ink2)
            Text(toast.text)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(Theme.ink)
                .fixedSize()
            if toast.hasUndo {
                Button("Undo", action: undo)
                    .buttonStyle(.plain)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 16)
        .frame(height: 40)
        .cpGlass(in: Capsule())
        .padding(6)
    }
}

/// The window the toast lives in: never key, never activating, and out of the
/// way of everything including the picker.
@MainActor
public final class ToastWindow {

    private let center: ToastCenter
    private var panel: OverlayPanel?

    public init(center: ToastCenter) {
        self.center = center
    }

    public func update() {
        guard let toast = center.current else {
            panel?.orderOut(nil)
            return
        }
        let panel = existingOrNewPanel()
        let hosting = FirstMouseHostingView(rootView: ToastView(toast: toast) { [weak self] in self?.center.undo() })
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        panel.contentView = hosting
        panel.setContentSize(size)
        if let visible = NSWindow.activeScreen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(
                x: (visible.midX - size.width / 2).rounded(),
                y: (visible.minY + 34).rounded()
            ))
        }
        panel.orderFrontRegardless()
    }

    private func existingOrNewPanel() -> OverlayPanel {
        if let panel { return panel }
        let panel = OverlayPanel(rect: NSRect(x: 0, y: 0, width: 200, height: 52))
        self.panel = panel
        return panel
    }
}
