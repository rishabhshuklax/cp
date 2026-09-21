import AppKit
import SwiftUI

/// What is behind the menu bar icon.
///
/// Not the main surface — the picker is — but the one place that answers "is it
/// even running, and is it recording right now?" without a keystroke. So it
/// opens with the answer, in a sentence, with a coloured dot.
public struct MenuBarView: View {

    private let controller: AppController
    @Environment(\.dismiss) private var dismiss
    @State private var now = Date()

    public init(controller: AppController) {
        self.controller = controller
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            state

            header("Recent")
            ForEach(controller.recentForMenu(), id: \.id) { clipping in
                MenuRow {
                    ClipThumb(clipping: clipping, store: controller.store, links: controller.links)
                    Text(clipping.displayTitle)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 8)
                    Text(RelativeTime.short(clipping.lastCopiedAt, now: now))
                        .font(Theme.Font.capsuleKey)
                        .foregroundStyle(Theme.ink3)
                } action: {
                    controller.copyToClipboard(clipping)
                    dismiss()
                }
            }

            separator
            MenuRow {
                Text(controller.isPaused ? "Resume now" : "Pause for 10 minutes")
                Spacer(minLength: 8)
            } action: {
                controller.togglePause()
                dismiss()
            }
            if controller.stack.isArmed {
                MenuRow {
                    Text("Clear stack (\(controller.stack.count))")
                    Spacer(minLength: 8)
                } action: {
                    controller.stack.clear()
                    dismiss()
                }
            }
            MenuRow {
                Text("Open Library")
                Spacer(minLength: 8)
                Text("⌥⌘V").font(Theme.Font.capsuleKey).foregroundStyle(Theme.ink3)
            } action: {
                controller.openLibrary()
                dismiss()
            }
            MenuRow {
                Text("Settings…")
                Spacer(minLength: 8)
                Text("⌘,").font(Theme.Font.capsuleKey).foregroundStyle(Theme.ink3)
            } action: {
                controller.openSettings()
                dismiss()
            }

            separator
            MenuRow {
                Text("Quit cp")
                Spacer(minLength: 8)
                Text("⌘Q").font(Theme.Font.capsuleKey).foregroundStyle(Theme.ink3)
            } action: {
                NSApp.terminate(nil)
            }
        }
        .padding(6)
        .frame(width: 318)
        .onReceive(Timer.publish(every: 20, on: .main, in: .common).autoconnect()) { now = $0 }
    }

    private var state: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(controller.isPaused ? Theme.paused : Theme.positive)
                .frame(width: 7, height: 7)
            Text(controller.captureState)
                .font(Theme.Font.meta)
                .foregroundStyle(Theme.ink2)
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(Theme.Font.label)
            .foregroundStyle(Theme.ink3)
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 4)
    }

    private var separator: some View {
        Rectangle()
            .fill(Theme.line)
            .frame(height: 1)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
    }
}

/// A menu row: 30pt, and the accent under the pointer, the way every other menu
/// on the platform behaves.
struct MenuRow<Content: View>: View {

    @ViewBuilder let content: () -> Content
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                content()
            }
            .font(.system(size: 13.5))
            .foregroundStyle(isHovered ? Color.white : Theme.ink)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isHovered ? Theme.accent : .clear,
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onContinuousHover { phase in
            if case .active = phase { isHovered = true } else { isHovered = false }
        }
    }
}
