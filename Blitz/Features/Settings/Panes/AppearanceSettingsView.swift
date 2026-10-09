import SwiftUI

struct AppearanceSettingsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        return Form {
            Section {
                Picker(selection: $settings.appearance) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.title).tag(appearance)
                    }
                } label: {
                    SettingsRowTitle(.appearanceAppearance, "Theme")
                }
                InterfaceSizeRow()
                WindowModeRow()
                Toggle(isOn: $settings.showFavoritesInCompactMode) {
                    SettingsRowTitle(.appearanceAppearance, "Show favorites in compact mode")
                    Text("Launch them with ⌘1–⌘5.")
                }
                .settingsEnabled(settings.compactMode)
                Toggle(isOn: $settings.openOnCursorScreen) {
                    SettingsRowTitle(.appearanceAppearance, "Follow the cursor across displays")
                }
                Toggle(isOn: $settings.paletteDraggable) {
                    SettingsRowTitle(.appearanceAppearance, "Drag to reposition")
                    Text("Drag the strip above the search field.")
                }
            }
            .settingsAnchor(.appearanceAppearance)
        }
        .formStyle(.grouped)
        .settingsScrollTarget(.appearance)
    }
}

private struct WindowModeRow: View {
    @Environment(AppSettings.self) private var settings

    private static let preview = CGSize(width: 135, height: 80)

    var body: some View {
        SettingsRow(
            title: "Window mode", subtitle: "Choose how the launcher opens.",
            subtitleLineLimit: 2, alignment: .top, anchor: .appearanceAppearance
        ) {
            HStack(spacing: Theme.Spacing.md) {
                option("Compact", image: "WindowModeCompact", compact: true)
                option("Expanded", image: "WindowModeExpanded", compact: false)
            }
        }
    }

    private func option(_ title: String, image: String, compact: Bool) -> some View {
        let selected = settings.compactMode == compact
        return Button {
            settings.compactMode = compact
        } label: {
            VStack(spacing: Theme.Spacing.xs) {
                Image(image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: Self.preview.width, height: Self.preview.height)
                    .clipShape(
                        RoundedRectangle(cornerRadius: Theme.Radius.barControl, style: .continuous)
                    )
                    .saturation(selected ? 1 : 0)
                Text(title)
                    .font(.caption)
                    .fontWeight(selected ? .semibold : .regular)
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(WindowModeButtonStyle())
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

private struct WindowModeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PressedLabel(configuration: configuration)
    }

    private struct PressedLabel: View {
        let configuration: ButtonStyle.Configuration
        @State private var showsPressed = false

        var body: some View {
            configuration.label
                .opacity(showsPressed ? 0.7 : 1)
                .task(id: configuration.isPressed) {
                    if configuration.isPressed {
                        try? await Task.sleep(for: .milliseconds(20))
                        guard !Task.isCancelled else { return }
                        showsPressed = true
                    } else {
                        showsPressed = false
                    }
                }
        }
    }
}

/// Three glyph steps read as a legend; a true-to-scale "Aa" would look identical at 1.1.
private struct InterfaceSizeRow: View {
    @Environment(AppSettings.self) private var settings

    private static let glyph: [InterfaceSize: CGFloat] = [
        .standard: 11, .large: 14, .larger: 17
    ]

    var body: some View {
        SettingsRow(
            title: "Interface size",
            subtitle: "Scales the launcher and its panels, not Settings.",
            anchor: .appearanceAppearance
        ) {
            HStack(spacing: Theme.Spacing.xs) {
                ForEach(InterfaceSize.allCases) { size in
                    segment(size)
                }
            }
        }
    }

    private func segment(_ size: InterfaceSize) -> some View {
        let selected = settings.interfaceSize == size
        return Button {
            settings.interfaceSize = size
        } label: {
            Text("Aa")
                .font(.system(size: Self.glyph[size] ?? 13, weight: .medium))
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .settingsOptionSegment(isSelected: selected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(size.title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .help(size.title)
    }
}
