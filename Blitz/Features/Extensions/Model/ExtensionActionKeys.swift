import Foundation

/// Which actions ↵ and ⌘↵ fire, and the keycaps the ⌘K panel draws beside them.
enum ExtensionActionKeys {
    struct Slot: Equatable {
        /// Its own `shortcut` is ⌘↵, which outranks the positional second action.
        var declaresCommandReturn = false
        /// Reached through a submenu, where ↵ opens the panel rather than firing the leaf.
        var isInSubmenu = false
        /// The keycaps its own `shortcut` draws, if it has one.
        var ownCaps: String?
    }

    static let returnCaps = "↵"
    static let commandReturnCaps = "⌘↵"

    /// ⌘↵'s action; none in a form, where ⌘↵ already submits through the primary action.
    static func secondary(in slots: [Slot], isForm: Bool) -> Int? {
        guard !isForm else { return nil }
        if let declared = slots.firstIndex(where: \.declaresCommandReturn) { return declared }
        guard slots.count > 1, !slots[1].isInSubmenu else { return nil }
        return 1
    }

    static func caps(for slots: [Slot], isForm: Bool) -> [String?] {
        let secondary = secondary(in: slots, isForm: isForm)
        return slots.indices.map { index in
            if index == 0, !slots[0].isInSubmenu { return isForm ? commandReturnCaps : returnCaps }
            if index == secondary { return commandReturnCaps }
            return slots[index].ownCaps
        }
    }
}
