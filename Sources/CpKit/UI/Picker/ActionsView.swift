import SwiftUI

/// ⌘K: everything this clipping can do, with its own filter field.
///
/// Anchored to the hero's right edge rather than centred, because it is about
/// the thing above it. Type to narrow — "mark" finds Markdown — then ↩.
public struct ActionsView: View {

    @Bindable private var model: PickerModel
    @FocusState private var focused: Bool

    public init(model: PickerModel) {
        self._model = Bindable(model)
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return VStack(alignment: .leading, spacing: 0) {
            TextField("Paste as…", text: $model.actionQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(Theme.ink)
                .focused($focused)
                .padding(.horizontal, 10)
                .frame(height: 34)
            Rectangle().fill(Theme.line).frame(height: 1)
                .padding(.bottom, 4)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.actions.enumerated()), id: \.element.id) { index, action in
                        if action.startsGroup {
                            Rectangle().fill(Theme.line)
                                .frame(height: 1)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                        }
                        row(action, index: index)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
        .padding(6)
        .frame(width: Theme.Metric.actionsWidth)
        .frame(maxHeight: Theme.Metric.resultsHeight - Theme.Metric.actionsTop - 12, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
        .cpGlassScrim(in: shape)
        .onAppear { focused = true }
    }

    private func row(_ action: PickerAction, index: Int) -> some View {
        let isSelected = index == model.actionIndex
        return HStack(spacing: 10) {
            Text(action.label)
                .font(Theme.Font.action)
                .foregroundStyle(action.isDanger ? Theme.danger : Theme.ink)
            Spacer(minLength: 8)
            if let key = action.key {
                Text(key)
                    .font(Theme.Font.capsuleKey)
                    .foregroundStyle(Theme.ink3)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Theme.Metric.actionRowHeight)
        .background(isSelected ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { model.run(action) }
        .onContinuousHover { phase in
            guard case .active = phase else { return }
            model.setActionIndex(index)
        }
    }
}
