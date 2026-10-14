import SwiftUI

/// A peer of the AI pane, not a section in it: it only borrows the provider layer.
struct QuickActionsSettingsView: View {
    @Environment(AppCore.self) private var core
    @Environment(AppSettings.self) private var appSettings
    @Environment(QuickActionSettingsStore.self) private var store
    @Environment(CustomQuickActionStore.self) private var customActions
    @Environment(AISettingsStore.self) private var aiSettings
    @Environment(SettingsNavigationState.self) private var navigation

    /// Polled like the Permissions pane: the grant lands in System Settings, which sends nothing.
    @State private var isTrusted = Permissions.isAccessibilityTrusted()
    @State private var editingAction: BuiltInQuickAction?
    @State private var customEditing: CustomQuickActionEditRequest?

    var body: some View {
        // Once per render: each access would look the four up in the catalog again.
        let items = QuickActionSettingsItem.all(custom: customActions.actions)
        let shown = items.first { $0.id == navigation.page }
        SettingsPagedPane(showsPage: shown != nil) {
            if let shown {
                QuickActionPage(
                    item: shown, subtitle: subtitle(for: shown.action),
                    onEdit: { edit(shown.action) })
            }
        } library: {
            library(items)
        }
        .task {
            while !Task.isCancelled {
                isTrusted = Permissions.isAccessibilityTrusted()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .settingsEditorPanel(item: $editingAction) { action in
            InstructionsEditorPanel(
                action: action,
                instructionOverride: store.settings.instructionOverride(for: action),
                modelOverride: store.modelOverride(for: .builtIn(action))
            ) { instructionOverride, modelOverride in
                store.settings.setInstructionOverride(instructionOverride, for: action)
                store.setModelOverride(modelOverride, for: .builtIn(action))
            }
        }
        .settingsEditorPanel(item: $customEditing) { request in
            CustomQuickActionEditorPanel(
                request: request,
                model: request.action.flatMap { store.modelOverride(for: .custom($0)) })
        }
        .onAppear {
            core.quickActionCoordinator.loadLanguages()
            store.repairModel(against: aiSettings.connections, fallback: aiSettings.defaultModel)
            store.resolveModel(
                appleIntelligenceAvailable: aiSettings.isAppleIntelligenceAvailable(),
                fallback: aiSettings.defaultModel)
            core.applyInstalledAILifecycle()
        }
        .onChange(of: appSettings.aiEnabled) { repairInstalledModel() }
        .onChange(of: aiSettings.enabledInstalledProviders) {
            core.applyInstalledAILifecycle()
            repairInstalledModel()
        }
        .onChange(of: core.codexSubscription.models) { repairInstalledModel() }
        .onChange(of: core.codexSubscription.phase) { repairInstalledModel() }
        .onChange(of: core.installedAI.statuses) { repairInstalledModel() }
    }

    private func library(_ items: [QuickActionSettingsItem]) -> some View {
        Form {
            Section {
                Toggle(isOn: enabledBinding) {
                    SettingsFeatureToggleLabel(
                        anchor: .quickActionsQuickActions, title: "Enable Quick Actions",
                        subtitle: "Act on selected text. Nothing is read until you press a shortcut.")
                }
                if appSettings.quickActionsEnabled, !isTrusted {
                    // Every shortcut fails without it; better said here than found one press later.
                    HStack(alignment: .center, spacing: Theme.Spacing.lg) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .frame(width: Theme.Size.settingsRowIcon)
                        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                            Text("Accessibility permission required")
                                .foregroundStyle(.orange)
                            Text("Needed to read your selection.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: Theme.Spacing.lg)
                        Button("Open System Settings") { Permissions.openAccessibilitySettings() }
                    }
                }
            } header: {
                SettingsSectionHeader(.quickActionsQuickActions)
            }

            Group {
                actionsSection(items)
                modelSection
                languageSection
            }
            .settingsEnabled(appSettings.quickActionsEnabled)
        }
        .formStyle(.grouped)
        .settingsScrollTarget(.quickActions)
    }

    /// Native rows rather than `SettingsPageRows`: the list is short, and none holds a control.
    private func actionsSection(_ items: [QuickActionSettingsItem]) -> some View {
        Section {
            ForEach(items) { item in
                Button {
                    navigation.select(navigation.tab, page: item.id)
                } label: {
                    QuickActionRow(item: item, subtitle: subtitle(for: item.action))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Configure \(item.action.title)")
                .id(item.id)
            }
            Button {
                customEditing = CustomQuickActionEditRequest(action: nil)
            } label: {
                SettingsRowTitle(.quickActionsActions, "Add Quick Action")
            }
        } header: {
            SettingsSectionHeader(.quickActionsActions)
        }
    }

    private func edit(_ action: QuickAction) {
        switch action {
        case .builtIn(let builtIn): editingAction = builtIn
        case .custom(let custom): customEditing = CustomQuickActionEditRequest(action: custom)
        }
    }

    private var modelSection: some View {
        Section {
            AIModelSelectionRows(
                selection: store.model,
                select: store.select,
                modelLabel: {
                    SettingsRowTitle(.quickActionsModel, "Model")
                    Text("Unless an action sets its own.")
                },
                effortLabel: {
                    SettingsRowTitle(.quickActionsModel, "Reasoning effort")
                }
            )
        } header: {
            SettingsSectionHeader(.quickActionsModel)
        } footer: {
            Text("Separate from AI Agent's, so frequent use needn't bill an API.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var languageSection: some View {
        Section {
            Picker(selection: languageBinding) {
                Text("Same as this Mac").tag("")
                ForEach(core.quickActionCoordinator.offeredLanguages, id: \.minimalIdentifier) {
                    Text(TextTranslator.displayName(of: $0)).tag($0.minimalIdentifier)
                }
            } label: {
                SettingsRowTitle(.quickActionsTranslate, "Translate to")
            }
        } header: {
            SettingsSectionHeader(.quickActionsTranslate)
        } footer: {
            Text("Apple's translator, on this Mac. A language downloads on first use.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func subtitle(for action: QuickAction) -> String? {
        let details = [
            action.alwaysPreviews ? "Always shown in a panel" : nil,
            store.modelOverride(for: action).map(routeTitle)
        ].compactMap(\.self)
        return details.isEmpty ? nil : details.joined(separator: " · ")
    }

    private func routeTitle(_ selection: AIModelSelection) -> String {
        let model = modelChoices.first { $0.matches(selection) }?.title ?? selection.model
        guard let effort = selection.effort else { return model }
        return "\(model) (\(ChatGPTSubscription.Effort(id: effort, detail: nil).title))"
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { appSettings.quickActionsEnabled },
            set: { core.quickActionCoordinator.setEnabled($0) })
    }

    private var languageBinding: Binding<String> {
        Binding(
            get: { store.settings.targetLanguage },
            set: { store.settings.targetLanguage = $0 })
    }

    private var modelChoices: [AIModelOption] {
        AIModelOption.availableGroups(
            settings: aiSettings, subscription: core.codexSubscription,
            installedAI: core.installedAI
        )
        .flatMap(\.options)
    }

    private func repairInstalledModel() {
        // Catalog rows name a route without an effort; a repaired selection must carry the default.
        let options = modelChoices.map {
            AIModelOption.withDefaultEffort(
                $0.selection, settings: aiSettings, subscription: core.codexSubscription,
                installedAI: core.installedAI)
        }
        var unavailable = Set<AIModelSource>()
        if !aiSettings.enabledInstalledProviders.contains(.codex)
            || core.codexSubscription.phase == .signedOut
            || core.codexSubscription.phase.isUnavailable
        {
            unavailable.insert(.codex)
        }
        for kind in InstalledAIKind.managedCLIKinds {
            let phase = core.installedAI.status(for: kind).phase
            guard
                !aiSettings.enabledInstalledProviders.contains(kind)
                    || phase == .signInRequired || phase == .notInstalled
            else { continue }
            unavailable.insert(kind.source)
        }
        store.repairInstalledModel(
            available: options, unavailableSources: unavailable,
            fallback: aiSettings.defaultModel)
    }

    private struct InstructionsEditorPanel: View {
        @Environment(\.settingsEditorDismiss) private var dismiss
        @State private var instructions: String
        @State private var model: AIModelSelection?

        let action: BuiltInQuickAction
        let builtIn: String
        let onSave: (String?, AIModelSelection?) -> Void

        init(
            action: BuiltInQuickAction, instructionOverride: String?,
            modelOverride: AIModelSelection?,
            onSave: @escaping (String?, AIModelSelection?) -> Void
        ) {
            self.action = action
            let builtIn = QuickActionPrompt.instructions(for: action)
            _instructions = State(initialValue: instructionOverride ?? builtIn)
            _model = State(initialValue: modelOverride)
            self.builtIn = builtIn
            self.onSave = onSave
        }

        var body: some View {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                SettingsEditorHeader(
                    title: "Customize \(action.title)",
                    subtitle: "Tell Blitz how you want \(action.title) to handle your selected text."
                )

                TextEditor(text: $instructions)
                    .font(.body)
                    .settingsEditorTextArea(height: Theme.Size.editorTextHeight * 2)

                QuickActionModelPicker(selection: $model)

                HStack(spacing: Theme.Spacing.md) {
                    Button("Use Default") { instructions = builtIn }
                        .buttonStyle(.modalAction(.standard, fillsWidth: false))
                        .disabled(instructions == builtIn)
                    Spacer()
                    Button("Cancel") { dismiss() }
                        .buttonStyle(.modalAction(.cancel))
                        .keyboardShortcut(.cancelAction)
                    Button("Save") {
                        onSave(instructions == builtIn ? nil : instructions, model)
                        dismiss()
                    }
                    .buttonStyle(.modalAction(.primary))
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(Theme.Spacing.dialogInset)
            .frame(width: Theme.Size.editorSheetWidth)
            .settingsEditorPanelSurface()
        }
    }
}
