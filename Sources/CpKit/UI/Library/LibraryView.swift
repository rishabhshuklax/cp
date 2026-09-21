import AppKit
import SwiftUI

/// The Library: everything you have copied, to look through rather than to
/// paste from.
///
/// It exists so the picker does not have to be both. A 200ms keyboard flow and
/// a place to browse a month of history want opposite things from every control
/// on screen; one surface trying to be both is what traps the popover model.
public struct LibraryView: View {

    @Bindable private var model: LibraryModel
    @State private var now = Date()

    public init(model: LibraryModel) {
        self._model = Bindable(model)
    }

    public var body: some View {
        HStack(spacing: 0) {
            sidebar
            main
        }
        .background(Theme.windowBackground)
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { now = $0 }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(model.sidebarTop) { item in sidebarRow(item) }
                header("Kinds")
                ForEach(model.sidebarKindItems) { item in sidebarRow(item) }
                header("Copied from")
                ForEach(model.sidebarApps) { item in sidebarRow(item) }
            }
            .padding(.horizontal, 8)
            // Room for the traffic lights, which sit over the sidebar.
            .padding(.top, 52)
            .padding(.bottom, 10)
        }
        .scrollIndicators(.hidden)
        .frame(width: Theme.Metric.sidebarWidth)
        .cpGlass(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(10)
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(Theme.Font.label)
            .foregroundStyle(Theme.ink3)
            .padding(.horizontal, 10)
            .padding(.top, 14)
            .padding(.bottom, 5)
    }

    private func sidebarRow(_ item: LibraryModel.SidebarItem) -> some View {
        let isOn = model.filter == item.filter
        return Button { model.filter = item.filter } label: {
            HStack(spacing: 9) {
                if let bundleID = item.bundleID, let icon = AppIconProvider.shared.icon(forBundleID: bundleID) {
                    Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                } else {
                    Image(systemName: item.symbolName)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 16)
                }
                Text(item.title)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text("\(item.count)")
                    .font(Theme.Font.rowTime)
                    .foregroundStyle(Theme.ink3)
                    .monospacedDigit()
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(isOn ? Theme.selection : .clear,
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Main

    private var main: some View {
        VStack(spacing: 0) {
            toolbar
            HStack(spacing: 0) {
                grid
                    .overlay(alignment: .bottom) {
                        if model.selection.count > 1 { bulkBar }
                    }
                Rectangle().fill(Theme.line).frame(width: 1)
                inspector
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text(model.filter.title)
                .font(Theme.Font.windowTitle)
                .foregroundStyle(Theme.ink)
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.ink2)
                TextField("Search, including text in images", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.ink)
            }
            .padding(.horizontal, 12)
            .frame(width: 280, height: 34)
            .background(Theme.wash, in: Capsule())
            .overlay { Capsule().strokeBorder(Theme.line, lineWidth: 1) }
        }
        .padding(.leading, 14)
        .padding(.trailing, 18)
        .frame(height: 62)
    }

    private var grid: some View {
        ScrollView {
            if model.isEmpty {
                Text(model.query.isEmpty ? "Nothing here yet" : "Nothing matches “\(model.query)”")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.ink3)
                    .frame(maxWidth: .infinity, minHeight: 300)
            }
            ForEach(model.groups) { group in
                VStack(alignment: .leading, spacing: 10) {
                    Text(group.day.rawValue)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.ink2)
                        .padding(.horizontal, 2)
                        .padding(.top, 16)
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: Theme.Metric.tileMinWidth), spacing: 12, alignment: .top)],
                        alignment: .leading,
                        spacing: 12
                    ) {
                        ForEach(group.clippings, id: \.id) { clipping in
                            tile(clipping)
                        }
                    }
                }
            }
            Color.clear.frame(height: 80)
        }
        .scrollIndicators(.hidden)
        .padding(.horizontal, 18)
    }

    private func tile(_ clipping: Clipping) -> some View {
        let isOn = model.isSelected(clipping.id)
        return VStack(spacing: 0) {
            ClipCard(clipping: clipping, store: model.store, links: model.links)
                .frame(height: model.height(for: clipping))
                .clipped()
            if model.showsFooter(clipping) {
                HStack(spacing: 6) {
                    if let icon = AppIconProvider.shared.icon(forBundleID: clipping.sourceBundleID) {
                        Image(nsImage: icon).resizable().frame(width: 14, height: 14)
                    }
                    Text("\(clipping.sourceAppName ?? "Unknown") · \(RelativeTime.short(clipping.lastCopiedAt, now: now))")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.ink3)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
                .padding(.top, 2)
                .background(Theme.card)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(isOn ? Theme.accent : Theme.line, lineWidth: isOn ? 2.5 : 1)
        }
        .overlay(alignment: .topTrailing) {
            if isOn, model.selection.count > 1 {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: 20, height: 20)
                    .background(Theme.accent, in: Circle())
                    .padding(8)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            let extending = NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.shift)
            model.select(clipping.id, extending: extending)
        }
    }

    // MARK: - Inspector

    @ViewBuilder
    private var inspector: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let clipping = model.focus {
                ClipCard(clipping: clipping, style: .inspector, store: model.store, links: model.links)
                    .frame(height: 190)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Theme.line, lineWidth: 1)
                    }

                VStack(spacing: 0) {
                    inspectorRow("From") {
                        HStack(spacing: 6) {
                            if let icon = AppIconProvider.shared.icon(forBundleID: clipping.sourceBundleID) {
                                Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                            }
                            Text(clipping.sourceAppName ?? "Unknown app")
                        }
                    }
                    inspectorRow("Copied") { Text(RelativeTime.long(clipping.lastCopiedAt, now: now)) }
                    inspectorRow("Times copied") { Text("\(clipping.copyCount)") }
                    inspectorRow("Kept until") { Text(model.keptUntil(clipping)) }
                }

                HStack(spacing: 8) {
                    CapsuleButton("Copy", prominent: true) { model.host?.copyToClipboard(clipping) }
                    CapsuleButton(clipping.isPinned ? "Unpin" : "Pin") { model.host?.togglePin(clipping) }
                    CapsuleButton("Delete") { model.host?.delete(clipping) }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(width: Theme.Metric.inspectorWidth, alignment: .top)
    }

    private func inspectorRow<Content: View>(_ label: String, @ViewBuilder value: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(Theme.ink2)
            Spacer(minLength: 8)
            value()
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
        }
        .frame(height: 32)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.line).frame(height: 1)
        }
    }

    // MARK: - Several at once

    private var bulkBar: some View {
        HStack(spacing: 6) {
            Text("\(model.selection.count) selected")
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(Theme.ink)
                .padding(.trailing, 8)
            CapsuleButton("Add to stack") { model.host?.addToStack(model.selection) }
            CapsuleButton("Pin") { model.host?.setPinned(model.selection, pinned: true) }
            CapsuleButton("Delete") { model.host?.delete(model.selection) }
        }
        .padding(.leading, 18)
        .padding(.trailing, 8)
        .frame(height: 46)
        .cpGlass(in: Capsule())
        .padding(.bottom, 22)
    }
}
