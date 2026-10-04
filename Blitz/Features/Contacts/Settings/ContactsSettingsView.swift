import SwiftUI

struct ContactsSettingsView: View {
    @Environment(AppCore.self) private var core
    @Environment(AppSettings.self) private var settings
    @Environment(ContactsStore.self) private var store

    var body: some View {
        Form {
            Section {
                Toggle(isOn: enabledBinding) {
                    SettingsFeatureToggleLabel(
                        anchor: .contactsContacts, title: "Use contacts in Blitz",
                        subtitle: "Search, call, email and edit your contacts from the palette.")
                }
            }
            .settingsAnchor(.contactsContacts)

            if settings.contactsEnabled, store.access == .notDetermined {
                Section {
                    SettingsRow(
                        title: "Contacts access is needed",
                        subtitle: "Needed to read and change your contacts."
                    ) {
                        Button("Allow Contacts Access…") {
                            core.contactsCoordinator.setContactsEnabled(true)
                        }
                    }
                }
            } else if store.access == .denied {
                Section {
                    SettingsRow(
                        title: "Contacts access is off",
                        subtitle: "Allow it in Privacy & Security ▸ Contacts."
                    ) {
                        Button("Open System Settings…") { Permissions.openContactsSettings() }
                    }
                }
            }

            FeatureCommandsSection(owner: .contacts, anchor: .contactsCommands)
                .settingsEnabled(settings.contactsEnabled)

            LauncherContactsSection()
                .settingsEnabled(settings.contactsEnabled)
        }
        .formStyle(.grouped)
        .settingsScrollTarget(.contacts)
        .releasesFocusOnOutsideClick()
        // Nothing announces a grant made in System Settings, so the pane reads the book itself.
        .onAppear {
            store.refreshAccess()
            if !store.hasLoaded { store.reload() }
        }
    }

    /// Routed through the coordinator so enabling, which is also consent, confirms first.
    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { settings.contactsEnabled },
            set: { core.contactsCoordinator.setContactsEnabled($0) }
        )
    }
}

/// The marked cards, or a search's first few: a `Form` realizes every row, so never the whole book.
private struct LauncherContactsSection: View {
    @Environment(ContactsStore.self) private var store
    @State private var query = ""

    private static let resultLimit = 50

    private var contacts: [ContactItem] {
        guard !query.isEmpty else { return store.contacts.filter(store.isSearchable) }
        return Array(ContactDirectory.matching(store.contacts, query: query).prefix(Self.resultLimit))
    }

    var body: some View {
        Section {
            SettingsFilterField(prompt: "Search contacts to add…", query: $query)

            let contacts = contacts
            if contacts.isEmpty {
                Text(emptyMessage)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                ForEach(contacts) { contact in
                    LauncherContactRow(contact: contact)
                }
            }
        } header: {
            SettingsSectionHeader(.contactsLauncherSearch)
        } footer: {
            Text("A marked contact shows up in the launcher's own search, beside your apps.")
                .foregroundStyle(.secondary)
        }
    }

    private var emptyMessage: String {
        if !query.isEmpty { return "No matches for “\(query)”." }
        guard store.access == .granted else { return "Nothing to show yet." }
        return "No contacts in launcher search yet. Search above to add one."
    }
}

private struct LauncherContactRow: View {
    let contact: ContactItem
    @Environment(AppCore.self) private var core

    var body: some View {
        SettingsRow(title: contact.title, subtitle: contact.subtitle) {
            Toggle("", isOn: binding)
                .labelsHidden()
                .toggleStyle(.checkbox)
                .accessibilityLabel("Show \(contact.title) in launcher search")
        }
    }

    private var binding: Binding<Bool> {
        Binding(
            get: { core.contactsCoordinator.isSearchable(contact) },
            set: { core.contactsCoordinator.setSearchable($0, for: contact) }
        )
    }
}
