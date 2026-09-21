import SwiftUI

/// Liquid Glass where the system has it, a material and a hairline where it
/// doesn't.
///
/// macOS 26 draws `glassEffect` properly — it refracts and reacts to what is
/// behind it. On 14 and 15 the closest honest thing is `.regularMaterial` plus
/// the 1pt inner edge that makes a floating surface read as floating. Both live
/// behind this one helper so no view has to branch on the OS.
extension View {

    /// Glass for a piece of chrome: the search capsule, the results panel, the
    /// HUD, the chip, the toast. Never for a row.
    @ViewBuilder
    public func cpGlass<S: InsettableShape>(in shape: S) -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.regularMaterial, in: shape)
                .overlay { shape.strokeBorder(Theme.edge, lineWidth: 1) }
        }
    }

    /// Denser glass, for a surface floating over another one — the actions
    /// overlay, the stack tray, the menu — where content behind two layers of
    /// blur would otherwise show through as noise.
    @ViewBuilder
    public func cpGlassScrim<S: InsettableShape>(in shape: S) -> some View {
        self.background(Theme.scrim, in: shape)
            .background(.regularMaterial, in: shape)
            .overlay { shape.strokeBorder(Theme.edge, lineWidth: 1) }
    }
}

/// Groups glass surfaces so the system can blend them where they meet. A no-op
/// before macOS 26.
public struct CpGlassContainer<Content: View>: View {
    private let spacing: CGFloat
    private let content: Content

    public init(spacing: CGFloat = 10, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    public var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

/// The one button shape in this app: a capsule with a label and, when there is
/// one, the key that does the same thing.
public struct CapsuleButton: View {
    private let title: String
    private let key: String?
    private let prominent: Bool
    private let role: ButtonRole?
    private let action: () -> Void

    public init(
        _ title: String,
        key: String? = nil,
        prominent: Bool = false,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.key = key
        self.prominent = prominent
        self.role = role
        self.action = action
    }

    public var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: 7) {
                Text(title)
                if let key {
                    Text(key)
                        .font(Theme.Font.capsuleKey)
                        .foregroundStyle(prominent ? Theme.onAccent.opacity(0.72) : Theme.ink3)
                }
            }
            .font(Theme.Font.capsule)
            .foregroundStyle(prominent ? Theme.onAccent : Theme.ink)
            .padding(.horizontal, 12)
            .frame(height: Theme.Metric.capsuleHeight)
            .contentShape(Capsule())
        }
        .buttonStyle(CapsuleButtonStyle(prominent: prominent))
    }
}

/// Flat wash, or the accent, under the label. `.glass` and `.glassProminent`
/// take over on macOS 26.
private struct CapsuleButtonStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        Group {
            if #available(macOS 26, *) {
                if prominent {
                    configuration.label
                        .glassEffect(.regular.tint(Theme.accent).interactive(), in: .capsule)
                } else {
                    configuration.label.glassEffect(.regular.interactive(), in: .capsule)
                }
            } else if prominent {
                configuration.label.background(Theme.accent, in: Capsule())
            } else {
                configuration.label
                    .background(Theme.wash, in: Capsule())
                    .overlay { Capsule().strokeBorder(Theme.line, lineWidth: 1) }
            }
        }
        .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

/// A keycap: `⌘1` on a row while ⌘ is held, `⇥` on the suggestion.
public struct Keycap: View {
    private let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .font(Theme.Font.keycap)
            .foregroundStyle(Theme.ink2)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(Theme.wash, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.line, lineWidth: 1)
            }
    }
}
