import SwiftUI

struct GeneralSettingsView: View {
    @Environment(AppCore.self) private var core
    @Environment(AppSettings.self) private var settings
    private var launcherRanking: LauncherRankingStore { core.launcherRanking }
    private var queryHistory: LauncherQueryHistoryStore { core.launcherQueryHistory }
    @Environment(SettingsNavigationState.self) private var navigation
    @State private var inputSources: [InputSourceSwitcher.Option] = []
    /// Below the fold, held back a frame; a search result revealing one mounts them at once.
    @State private var mountsLowerSections = false

    var body: some View {
        @Bindable var settings = settings
        return Form {
            Section {
                LauncherShortcutRows(hotKeys: core.hotKeys)
            } header: {
                SettingsSectionHeader(.generalGlobalShortcuts)
            }

            Section {
                Toggle(isOn: $settings.launchAtLogin) {
                    SettingsRowTitle(.generalGeneral, "Launch at login")
                }
                Toggle(isOn: $settings.showInMenuBar) {
                    SettingsRowTitle(.generalGeneral, "Show in menu bar")
                    Text("Shortcuts still work when hidden.")
                }
                Picker(selection: $settings.popToRootTimeout) {
                    ForEach(PopToRootTimeout.allCases) { timeout in
                        Text(timeout.title).tag(timeout)
                    }
                } label: {
                    SettingsRowTitle(.generalGeneral, "Pop to Root Search")
                    Text("After the launcher closes.")
                }
                Picker(selection: $settings.escapeKeyBehavior) {
                    ForEach(EscapeKeyBehavior.allCases) { behavior in
                        Text(behavior.title).tag(behavior)
                    }
                } label: {
                    SettingsRowTitle(.generalGeneral, "Escape Key Behavior")
                    Text("When the search field is empty.")
                }
                // Empty only when TIS fails; one layout still lists, so the row stays put.
                if !inputSources.isEmpty {
                    Picker(selection: $settings.autoSwitchInputSourceID) {
                        Text("None").tag(nil as String?)
                        ForEach(inputSources) { source in
                            Text(source.title).tag(Optional(source.id))
                        }
                    } label: {
                        SettingsRowTitle(.generalGeneral, "Auto-switch input source")
                        Text("While the launcher is open.")
                    }
                }
                LabeledContent {
                    Button("Show Tour") { core.onboardingCoordinator.showOnboarding() }
                } label: {
                    SettingsRowTitle(.generalGeneral, "Welcome Tour")
                    Text("The first-run setup, plus a few tips.")
                }
            } header: {
                SettingsSectionHeader(.generalGeneral)
            }

            if mountsLowerSections || navigation.scrollRequest?.target.tab == .general {
                lowerSections
            }
        }
        .formStyle(.grouped)
        .settingsScrollTarget(.general)
        .onAppear(perform: refreshInputSources)
        // Past the task's first suspension, so the sections above the fold paint a frame first.
        .task {
            await Task.yield()
            mountsLowerSections = true
        }
        .onReceive(
            DistributedNotificationCenter.default().publisher(
                for: InputSourceSwitcher.sourcesDidChange)
        ) { _ in
            refreshInputSources()
        }
    }

    /// Calculator and Search: what the pane holds below its first screenful.
    @ViewBuilder
    private var lowerSections: some View {
        @Bindable var settings = settings
        Section {
            Picker(selection: $settings.calcNumberStyle) {
                ForEach(CalcNumberStyle.allCases) { style in
                    let sample = core.regionNumberFormat.format(for: style).localized("1,234,567.89")
                    Text("\(style.title) (\(sample))").tag(style)
                }
            } label: {
                SettingsRowTitle(.generalCalculator, "Number format")
                Text("With a decimal comma, ; separates arguments.")
            }
        } header: {
            SettingsSectionHeader(.generalCalculator)
        }

        Section {
            Toggle(isOn: $settings.launcherShowsSuggestions) {
                SettingsRowTitle(.generalSearch, "Show suggestions")
                Text("What you open most, while the search field is empty.")
            }
            Picker(selection: $settings.rootSearchSensitivity) {
                ForEach(SearchSensitivity.allCases) { sensitivity in
                    Text(sensitivity.title).tag(sensitivity)
                }
            } label: {
                SettingsRowTitle(.generalSearch, "Search sensitivity")
                Text("Lower finds names from scattered letters.")
            }
            LabeledContent {
                Button("Reset…", role: .destructive, action: confirmRankingReset)
                    .disabled(launcherRanking.isEmpty)
            } label: {
                SettingsRowTitle(.generalSearch, "Learned ranking")
                Text("Learned privately from the results you pick.")
            }
            Toggle(isOn: $settings.launcherSavesSearchHistory) {
                SettingsRowTitle(.generalSearch, "Remember search history")
                Text("↑ recalls searches after a restart. Shell commands are never kept.")
            }
            LabeledContent {
                Button("Clear…", role: .destructive, action: confirmHistoryClear)
                    .disabled(queryHistory.isEmpty)
            } label: {
                SettingsRowTitle(.generalSearch, "Search history")
                Text("The searches ↑ walks back through.")
            }
        } header: {
            SettingsSectionHeader(.generalSearch)
        }
    }

    private func confirmRankingReset() {
        Task {
            guard
                await core.confirm(
                    title: "Reset learned launcher ranking?",
                    message: "Blitz will relearn your preferred results as you use the launcher.",
                    symbol: PaletteMode.launcher.systemImage, confirmTitle: "Reset Ranking")
            else { return }
            launcherRanking.resetAll()
        }
    }

    private func confirmHistoryClear() {
        Task {
            guard
                await core.confirm(
                    title: "Clear launcher search history?",
                    message: "↑ will start again from the next search you run.",
                    symbol: "clock.arrow.circlepath", confirmTitle: "Clear History")
            else { return }
            queryHistory.clear()
        }
    }

    private func refreshInputSources() {
        inputSources = core.inputSourceSwitcher.options(selecting: settings.autoSwitchInputSourceID)
    }
}

/// The launcher's recorder, and a warning while macOS still takes its ⌘Space for Spotlight.
private struct LauncherShortcutRows: View {
    @State private var spotlight: SpotlightHandoffSession

    init(hotKeys: HotKeyManager) {
        _spotlight = State(initialValue: SpotlightHandoffSession(hotKeys: hotKeys))
    }

    var body: some View {
        SettingsRow(title: "App Launcher", anchor: .generalGlobalShortcuts) {
            ShortcutRecorder(action: .togglePalette)
        }
        .onAppear { spotlight.refresh() }
        // Coming back from System Settings is what activates Blitz again.
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            spotlight.refresh()
        }
        if spotlight.isLauncherBlocked {
            HStack(alignment: .center, spacing: Theme.Spacing.lg) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .frame(width: Theme.Size.settingsRowIcon)
                Text("Spotlight still opens with ⌘Space.")
                    .foregroundStyle(.orange)
                Spacer(minLength: Theme.Spacing.lg)
                if !spotlight.isWaiting {
                    Button("Fix…") { spotlight.showGuide() }
                }
            }
            if spotlight.isWaiting {
                SpotlightShortcutGuide(holders: spotlight.holders)
            }
        }
    }
}
