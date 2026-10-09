import SwiftUI

struct HyperKeySettingsView: View {
    @Environment(AppCore.self) private var core
    @Environment(AppSettings.self) private var settings
    private var hyperTap: HyperKeyTap { core.hyperKeyTap }

    /// The Hyper modifier chord as prose glyphs, tracking the Include Shift toggle.
    private var hyperGlyphs: String { settings.hyperKeyIncludesShift ? "⌃⌥⇧⌘" : "⌃⌥⌘" }

    /// Only a choice made here resets Quick Press: settings.json may set both keys at once.
    private var hyperKeySelection: Binding<HyperKeyPhysicalKey> {
        Binding(
            get: { settings.hyperKey },
            set: { key in
                guard key != settings.hyperKey else { return }
                settings.hyperKey = key
                // A Quick Press choice is meaningless for a different key.
                settings.hyperKeyQuickPress = .none
                if key != .none { Permissions.ensureAccessibility() }
            })
    }

    /// The missing-permission half is its own row, so it can carry the button that fixes it.
    private var hyperSubtitle: String {
        guard settings.hyperKey != .none else { return "Remap one key to \(hyperGlyphs) held together." }
        return "\(settings.hyperKey.title) sends \(hyperGlyphs), shown as ✦ in shortcuts."
    }

    var body: some View {
        @Bindable var settings = settings
        return Form {
            Section {
                Picker(selection: hyperKeySelection) {
                    ForEach(HyperKeyPhysicalKey.allCases) { key in
                        Text(key.title).tag(key)
                    }
                } label: {
                    SettingsRowTitle(.hyperKeyHyperKey, "Hyper Key")
                    Text(hyperSubtitle)
                }

                if hyperTap.status == .needsAccessibility {
                    HStack(alignment: .center, spacing: Theme.Spacing.lg) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .frame(width: Theme.Size.settingsRowIcon)
                        Text("Remapping needs Accessibility access.")
                            .foregroundStyle(.orange)
                        Spacer(minLength: Theme.Spacing.lg)
                        Button("Grant Access…") { Permissions.openAccessibilitySettings() }
                    }
                }

                if settings.hyperKey.hasOriginalFunction {
                    Picker(selection: $settings.hyperKeyQuickPress) {
                        Text("Does Nothing").tag(HyperKeyQuickPress.none)
                        if let original = settings.hyperKey.quickPressOriginalTitle {
                            Text(original).tag(HyperKeyQuickPress.originalKey)
                        }
                        Text("Trigger Escape").tag(HyperKeyQuickPress.escape)
                    } label: {
                        SettingsRowTitle(.hyperKeyHyperKey, "Quick Press")
                        Text("When \(settings.hyperKey.title) is pressed alone.")
                    }
                }

                Toggle(isOn: $settings.hyperKeyIncludesShift) {
                    SettingsRowTitle(.hyperKeyHyperKey, "Include Shift (⇧)")
                }
                // Flipping it re-points recorded chords, so it needs a chord to mean.
                .settingsEnabled(settings.hyperKey != .none)
            }
            .settingsAnchor(.hyperKeyHyperKey)
        }
        .formStyle(.grouped)
        .settingsScrollTarget(.hyperKey)
    }
}
