import SwiftUI

/// How to free ⌘Space in System Settings; onboarding and General settings show the same steps.
struct SpotlightShortcutGuide: View {
    let holders: [SpotlightShortcut.Owner]

    /// Empty only between a refresh and the bind it triggers, when Spotlight is the likely owner.
    private var settingTitles: String {
        (holders.isEmpty ? [.spotlight] : holders)
            .map { "“\($0.settingTitle)”" }
            .joined(separator: " and ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("macOS opens Spotlight with ⌘Space. To give it to Blitz:")
                .font(.callout)
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                step(1, "Open Keyboard settings and click Keyboard Shortcuts…")
                step(2, "Choose Spotlight.")
                step(3, "Turn off \(settingTitles).")
            }
            HStack(spacing: Theme.Spacing.lg) {
                Button("Open Keyboard Settings") { Permissions.openKeyboardSettings() }
                    .controlSize(.small)
                Text("Blitz takes ⌘Space as soon as it’s free.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
            Text("\(number).")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
    }
}
