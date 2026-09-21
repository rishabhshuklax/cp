import AppKit
import Carbon.HIToolbox
import SwiftUI

/// The quick-switch HUD: the last eight clips, the one you are on lifted out
/// of the row. Release the shortcut and it pastes.
public struct SwitcherView: View {

    private let clippings: [Clipping]
    private let index: Int
    private let store: ClippingStore
    private let links: LinkPreviews
    private let onSelect: (Int) -> Void
    private let onCommit: (Int) -> Void

    public init(
        clippings: [Clipping],
        index: Int,
        store: ClippingStore,
        links: LinkPreviews,
        onSelect: @escaping (Int) -> Void,
        onCommit: @escaping (Int) -> Void
    ) {
        self.clippings = clippings
        self.index = index
        self.store = store
        self.links = links
        self.onSelect = onSelect
        self.onCommit = onCommit
    }

    public var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: Theme.Metric.cardGap) {
                ForEach(Array(clippings.enumerated()), id: \.element.id) { position, clipping in
                    card(clipping, at: position)
                }
            }
            caption
        }
        .padding(.horizontal, Theme.Metric.hudPadding)
        .padding(.top, Theme.Metric.hudPadding)
        .padding(.bottom, 12)
        .cpGlass(in: RoundedRectangle(cornerRadius: Theme.Metric.hudCorner, style: .continuous))
        .padding(20)
        .environment(\.colorScheme, NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light)
    }

    private func card(_ clipping: Clipping, at position: Int) -> some View {
        let isOn = position == index
        return ClipCard(clipping: clipping, store: store, links: links)
            .frame(width: Theme.Metric.cardSize, height: Theme.Metric.cardSize)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Metric.cardCorner, style: .continuous))
            .overlay(alignment: .topTrailing) {
                // The first card is what ⌘V would paste without cp at all.
                if position == 0 {
                    Image(systemName: "list.clipboard")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(Color.black.opacity(0.45), in: Circle())
                        .padding(8)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Metric.cardCorner, style: .continuous)
                    .strokeBorder(isOn ? Theme.ring : Theme.line, lineWidth: isOn ? 2.5 : 1)
            }
            .opacity(isOn ? 1 : 0.74)
            .scaleEffect(isOn ? 1.045 : 1)
            .offset(y: isOn ? -3 : 0)
            .shadow(color: .black.opacity(isOn ? 0.42 : 0), radius: 15, y: 7)
            .contentShape(Rectangle())
            .onTapGesture { onCommit(position) }
            .onContinuousHover { phase in
                guard case .active = phase else { return }
                onSelect(position)
            }
    }

    @ViewBuilder
    private var caption: some View {
        if clippings.indices.contains(index) {
            let clipping = clippings[index]
            HStack(spacing: 8) {
                if let icon = AppIconProvider.shared.icon(forBundleID: clipping.sourceBundleID) {
                    Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                }
                Text(clipping.sourceAppName ?? "Unknown app")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text(RelativeTime.long(clipping.lastCopiedAt))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.ink2)
            }
            .frame(height: 22)
        }
    }
}

/// The HUD's window: a key panel, so it can hear the shortcut being let go of.
@MainActor
public final class SwitcherWindow {

    private let store: ClippingStore
    private let links: LinkPreviews
    private let switcher: QuickSwitch
    private var panel: KeyPanel?
    private var clippings: [Clipping] = []

    public init(store: ClippingStore, links: LinkPreviews, switcher: QuickSwitch) {
        self.store = store
        self.links = links
        self.switcher = switcher
    }

    public var isVisible: Bool { panel?.isVisible ?? false }

    /// The clips the HUD is showing, newest first.
    public var current: [Clipping] { clippings }

    public func show(index: Int, clippings: [Clipping]) {
        self.clippings = clippings
        let panel = existingOrNewPanel()
        render(index: index)
        panel.centreOnActiveScreen()
        panel.makeKeyAndOrderFront(nil)
    }

    public func update(index: Int) {
        guard isVisible else { return }
        render(index: index)
    }

    public func hide() {
        panel?.orderOut(nil)
    }

    private func render(index: Int) {
        guard let panel else { return }
        let view = SwitcherView(
            clippings: clippings,
            index: index,
            store: store,
            links: links,
            onSelect: { [weak self] in self?.switcher.select($0) },
            onCommit: { [weak self] in self?.switcher.commit($0) }
        )
        if let hosting = panel.contentView as? NSHostingView<SwitcherView> {
            hosting.rootView = view
        } else {
            panel.contentView = NSHostingView(rootView: view)
        }
        let size = panel.contentView?.fittingSize ?? .zero
        panel.setContentSize(size)
        panel.centreOnActiveScreen()
    }

    private func existingOrNewPanel() -> KeyPanel {
        if let panel { return panel }
        let panel = KeyPanel(rect: NSRect(x: 0, y: 0, width: 600, height: 220))
        panel.keyHandler = { [weak self] event in
            guard let self else { return false }
            if event.type == .flagsChanged {
                self.switcher.modifiersChanged()
                return false
            }
            switch Int(event.keyCode) {
            case kVK_RightArrow: self.switcher.move(by: 1); return true
            case kVK_LeftArrow: self.switcher.move(by: -1); return true
            case kVK_Return: self.switcher.commit(); return true
            case kVK_Escape: self.switcher.cancel(); return true
            default: return false
            }
        }
        self.panel = panel
        return panel
    }
}
