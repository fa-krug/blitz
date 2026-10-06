import Foundation
import SwiftUI

/// Keeps the extension's item-id selection in step with the flat palette index, and pages on it.
struct ExtensionSelectionForwarder: ViewModifier {
    let screen: ExtensionScreen
    let selection: Int
    @Environment(PaletteState.self) private var palette
    @Environment(ExtensionManager.self) private var extensions
    @State private var seededContext: String?

    private var selectedIndex: Int {
        screen.items.isEmpty ? 0 : min(max(selection, 0), screen.items.count - 1)
    }

    private var context: String? {
        guard let running = extensions.running, let root = screen.root else { return nil }
        return "\(running.entryID):\(root.id)"
    }

    func body(content: Content) -> some View {
        content.onChange(of: screen.selectionChange(at: selectedIndex), initial: true) { _, change in
            guard let change else { return }
            if seededContext != context {
                seededContext = context
                if let index = screen.selectedItemIndex, selectedIndex != index {
                    palette.selection = index
                    return
                }
            }
            let argument: Any = change.itemID.map { $0 as Any } ?? NSNull()
            extensions.dispatch(handler: change.handler, arguments: [argument])
        }
        .onChange(of: selectedIndex) { _, index in reach(index) }
        // A load that settles with its last rows already in view would otherwise never page again.
        .onChange(of: screen.isLoading) { reach(nil) }
    }

    private func reach(_ index: Int?) {
        guard let pagination = screen.pagination else { return }
        extensions.loadMore(
            pagination, reaching: index, itemCount: screen.items.count, isLoading: screen.isLoading)
    }
}
