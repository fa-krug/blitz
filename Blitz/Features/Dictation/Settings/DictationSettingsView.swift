import AVFoundation
import AppKit
import SwiftUI

struct DictationSettingsView: View {
    @Environment(AppCore.self) private var core
    @Environment(AppSettings.self) private var settings
    @State private var microphones: [AVCaptureDevice] = []
    @State private var microphoneAccess = Permissions.microphoneAccess()

    private var coordinator: DictationCoordinator { core.dictationCoordinator }

    var body: some View {
        @Bindable var settings = settings
        return Form {
            Section {
                Toggle(isOn: enabledBinding) {
                    SettingsFeatureToggleLabel(
                        anchor: .dictationDictation, title: "Enable Dictation",
                        subtitle: "Speak instead of typing, transcribed on this Mac.")
                }
                if settings.dictationEnabled, microphoneAccess != .granted {
                    SettingsRow(
                        title: "Microphone access is off",
                        subtitle: "Allow it in Privacy & Security ▸ Microphone."
                    ) {
                        Button("Open System Settings…") { Permissions.openMicrophoneSettings() }
                    }
                }
            }
            .settingsAnchor(.dictationDictation)

            DictationShortcutSection()
                .settingsEnabled(settings.dictationEnabled)

            DictationLanguageSection()
                .settingsEnabled(settings.dictationEnabled)

            Section {
                Picker(selection: microphoneBinding) {
                    Text(microphones.isEmpty ? "No microphone available" : "System default").tag("")
                    if !microphones.isEmpty { Divider() }
                    ForEach(microphones, id: \.uniqueID) { microphone in
                        Text(microphone.localizedName).tag(microphone.uniqueID)
                    }
                } label: {
                    SettingsRowTitle(.dictationOutput, "Microphone")
                }
                Picker(selection: $settings.dictationDestination) {
                    ForEach(DictationDestination.allCases) { destination in
                        Text(destination.title).tag(destination)
                    }
                } label: {
                    SettingsRowTitle(.dictationOutput, "When finished")
                }
                Toggle(isOn: $settings.dictationLiveInsertion) {
                    SettingsRowTitle(.dictationOutput, "Insert while recording")
                    Text("Paste at each pause as you speak, instead of only when you finish.")
                }
                .disabled(!settings.dictationDestination.pastes)
                Toggle(isOn: $settings.dictationAdaptsCapitalization) {
                    SettingsRowTitle(.dictationOutput, "Adapt capitalization")
                    Text("Match the first letter to the text before the cursor.")
                }
            } header: {
                SettingsSectionHeader(.dictationOutput)
            } footer: {
                Text("Press Return to finish or Escape to cancel. Protected fields may refuse the text.")
                    .foregroundStyle(.secondary)
            }
            .settingsEnabled(settings.dictationEnabled)
        }
        .formStyle(.grouped)
        .settingsScrollTarget(.dictation)
        // Nothing announces a grant made in System Settings or a headset plugged in meanwhile.
        .task {
            refresh()
            for await _ in NotificationCenter.default.notifications(
                named: NSApplication.didBecomeActiveNotification)
            {
                refresh()
            }
        }
    }

    private func refresh() {
        microphoneAccess = Permissions.microphoneAccess()
        microphones = DictationCapture.microphones
        coordinator.refreshLanguage()
    }

    /// Routed through the coordinator, because turning it on is consent to the microphone.
    private var enabledBinding: Binding<Bool> {
        Binding(get: { settings.dictationEnabled }, set: { coordinator.setEnabled($0) })
    }

    private var microphoneBinding: Binding<String> {
        Binding(
            get: { settings.dictationMicrophone ?? "" },
            set: { settings.dictationMicrophone = $0.isEmpty ? nil : $0 })
    }
}

private struct DictationShortcutSection: View {
    @Environment(AppCore.self) private var core
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Section {
            Picker(selection: $settings.dictationMode) {
                ForEach(DictationMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            } label: {
                SettingsRowTitle(.dictationShortcut, "Shortcut behavior")
            }
            SettingsRow(title: "Shortcut", anchor: .dictationShortcut) {
                ShortcutRecorder(action: .dictation)
            }
            if settings.dictationMode == .hold {
                let issue = core.dictationCoordinator.holdShortcutIssue
                Text(
                    issue
                        ?? "Hold a key combination or a single modifier such as Right Option, and "
                        + "release it to insert the text. Double taps need Press to start or stop.")
                    .font(.caption)
                    .foregroundStyle(issue == nil ? Color.secondary : Color.orange)
            }
            Toggle(isOn: $settings.dictationPlaysSounds) {
                SettingsRowTitle(.dictationShortcut, "Play sounds")
                Text("Play macOS’s dictation sounds when recording starts and stops.")
            }
        } header: {
            SettingsSectionHeader(.dictationShortcut)
        }
    }
}

private struct DictationLanguageSection: View {
    @Environment(AppCore.self) private var core
    @Environment(AppSettings.self) private var settings

    private var coordinator: DictationCoordinator { core.dictationCoordinator }

    var body: some View {
        Section {
            Picker(selection: languageBinding) {
                Text(systemTitle).tag("")
                if !coordinator.supportedLanguages.isEmpty { Divider() }
                ForEach(coordinator.supportedLanguages, id: \.identifier) { locale in
                    Text(DictationLanguage.name(of: locale, in: .current)).tag(locale.identifier)
                }
            } label: {
                SettingsRowTitle(.dictationLanguage, "Language")
            }
            DictationModelRow(status: coordinator.assetStatus) { coordinator.downloadLanguage() }
        } header: {
            SettingsSectionHeader(.dictationLanguage)
        } footer: {
            Text("Apple’s speech model runs on this Mac; macOS downloads each language once.")
                .foregroundStyle(.secondary)
        }
    }

    private var systemTitle: String {
        guard let resolved = coordinator.resolvedLanguage, settings.dictationLanguage == nil else {
            return "System"
        }
        return "System (\(DictationLanguage.name(of: resolved, in: .current)))"
    }

    private var languageBinding: Binding<String> {
        Binding(
            get: { settings.dictationLanguage ?? "" },
            set: { settings.dictationLanguage = $0.isEmpty ? nil : $0 })
    }
}

/// The chosen language's model: ready, a download to start, or one running.
private struct DictationModelRow: View {
    let status: DictationAssetStatus
    let download: () -> Void

    var body: some View {
        switch status {
        case .downloading(let fraction):
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("Downloading speech model…")
                if let fraction {
                    ProgressView(value: fraction)
                        .accessibilityLabel("Speech model download progress")
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .accessibilityLabel("Preparing speech model download")
                }
            }
        default:
            SettingsRow(title: "Speech model", subtitle: status.title) {
                if status == .notInstalled {
                    Button("Download", action: download)
                }
            }
        }
    }
}
