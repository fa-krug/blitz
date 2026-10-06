import SwiftUI

/// Smart Reminder's one inline field in root search: the sentence the model turns into a reminder.
@MainActor
enum SmartReminderArgumentsAccessory {
    static let fieldID = "note"

    /// Nil for any row but Smart Reminder's.
    static func make(
        entry: AppEntry,
        vm: PaletteState,
        metrics: InterfaceMetrics,
        focus: FocusState<String?>.Binding,
        onSubmit: @escaping () -> Void
    ) -> PaletteHeaderAccessory? {
        guard CommandCatalog.command(for: entry) == .smartReminder else { return nil }
        let argument = InlineArgument(id: fieldID, title: "What to remember")
        let value = binding(entryID: entry.id, vm: vm)
        let firstOwed = { value.wrappedValue.isEmpty ? fieldID : nil }
        return PaletteHeaderAccessory(
            width: InlineArgumentFields.totalWidth(for: [argument], hasIcon: true, metrics: metrics),
            fieldNames: [fieldID],
            firstIncompleteField: firstOwed(),
            view: AnyView(
                InlineArgumentFields(
                    arguments: [argument], icon: .symbol(CommandID.smartReminder.sfSymbol),
                    value: { _ in value }, focused: focus, openOptions: { _ in },
                    onSubmit: {
                        guard let owed = firstOwed() else { return onSubmit() }
                        focus.wrappedValue = owed
                    }
                )
                .id(entry.id))
        )
    }

    /// The typed sentence, or nothing while it is blank — what `runCommand` is handed.
    static func values(for entry: AppEntry, vm: PaletteState) -> [String: String] {
        let typed = vm.commandArguments[PaletteState.argumentKey(entry.id, fieldID)] ?? ""
        return typed.isEmpty ? [:] : [fieldID: typed]
    }

    private static func binding(entryID: String, vm: PaletteState) -> Binding<String> {
        let key = PaletteState.argumentKey(entryID, fieldID)
        return Binding(get: { vm.commandArguments[key] ?? "" }, set: { vm.commandArguments[key] = $0 })
    }
}
