import AppKit
import SwiftUI

/// The picker's window, and the one place its keys are routed.
///
/// Every key goes through `KeyPanel.sendEvent` to the model first; what the
/// model does not claim reaches the search field with focus intact. Losing key
/// status closes the picker — the old panel kept floating over everything after
/// a click elsewhere, which is how you end up with a clipboard manager on top
/// of your screen share.
@MainActor
public final class PickerWindow {

    private let model: PickerModel
    private var panel: KeyPanel?
    private var isHiding = false

    /// Called after the picker goes away, however it went away.
    public var onHide: (() -> Void)?

    public init(model: PickerModel) {
        self.model = model
    }

    public var isVisible: Bool { panel?.isVisible ?? false }

    public func show() {
        let panel = existingOrNewPanel()
        model.open()
        panel.positionOnActiveScreen(topFraction: Theme.Metric.pickerTopFraction)
        panel.makeKeyAndOrderFront(nil)
    }

    public func hide() {
        guard let panel, panel.isVisible, !isHiding else { return }
        isHiding = true
        panel.orderOut(nil)
        isHiding = false
        onHide?()
    }

    public func toggle() {
        isVisible ? hide() : show()
    }

    private func existingOrNewPanel() -> KeyPanel {
        if let panel { return panel }
        let rect = NSRect(x: 0, y: 0, width: Theme.Metric.pickerWidth, height: Theme.Metric.pickerHeight)
        let panel = KeyPanel(rect: rect)
        let hosting = NSHostingView(rootView: PickerView(model: model))
        hosting.frame = rect
        panel.contentView = hosting
        panel.keyHandler = { [weak self] event in
            guard let self, self.panel?.isVisible == true else { return false }
            return self.model.handle(event)
        }
        panel.onResignKey = { [weak self] in
            // Another window took the keyboard: the picker's moment is over.
            self?.hide()
        }
        self.panel = panel
        return panel
    }
}
