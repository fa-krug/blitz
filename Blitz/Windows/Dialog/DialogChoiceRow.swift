import SwiftUI

/// A dialog's segmented choice: one row of values under a label, exactly one selected.
struct DialogChoiceRow<Value: Hashable>: View {
    @Environment(\.metrics) private var metrics
    let label: String
    let values: [Value]
    let title: (Value) -> String
    @Binding var selection: Value
    @State private var hoveredValue: Value?

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.spacing.sm) {
            Text(label)
                .font(metrics.typography.rowTrailing)
                .foregroundStyle(Theme.Colors.textSecondary)
                .fixedSize()

            HStack(spacing: 0) {
                ForEach(values, id: \.self) { value in
                    Button {
                        selection = value
                    } label: {
                        Text(title(value))
                            .font(metrics.typography.rowTrailing)
                            .foregroundStyle(
                                selection == value
                                    ? Theme.Colors.textPrimary : Theme.Colors.textSecondary
                            )
                            .frame(maxWidth: .infinity)
                            .frame(height: metrics.size.dialogButtonHeight)
                            .contentShape(Rectangle())
                            .background(
                                RoundedRectangle(
                                    cornerRadius: metrics.radius.row, style: .continuous
                                )
                                .fill(fill(for: value)))
                    }
                    .buttonStyle(.plain)
                    .onHover { hoveredValue = $0 ? value : nil }
                    .accessibilityLabel(title(value))
                    .accessibilityAddTraits(
                        selection == value ? [.isButton, .isSelected] : .isButton)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: metrics.radius.row, style: .continuous)
                    .fill(Theme.Colors.controlSurface))
        }
    }

    private func fill(for value: Value) -> Color {
        if selection == value { return Theme.Colors.selection }
        if hoveredValue == value { return Theme.Colors.rowHover }
        return .clear
    }
}
