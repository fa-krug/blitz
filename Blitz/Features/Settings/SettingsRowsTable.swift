import AppKit
import SwiftUI

/// Whether a list is long enough for `SettingsRowsTable`, whose rows cost twice a `Form`'s.
enum SettingsRowsTablePolicy {
    /// About a screenful: a shorter table would build every row anyway, each at twice the cost.
    private static let minimumRows = 15

    /// Takes the unfiltered count, so a filter keystroke never swaps the table for `Form` rows.
    static func hosts(rowCount: Int) -> Bool { rowCount > minimumRows }
}

/// A long Settings list as a table in one `Form` row, reusing a screenful of hosted rows.
struct SettingsRowsTable<Item: Identifiable & Equatable, Row: View>: View {
    let items: [Item]
    /// Fixed for every row; match the native `Form` row the list stands in for.
    let rowHeight: CGFloat
    var isEnabled = true
    /// Injects all a row reads besides its item: an unchanged item's row is never re-rendered.
    @ViewBuilder let row: @MainActor (Item) -> Row

    /// The open recorder's bounds in the table's space; nil while nothing is recording.
    @State private var recorderFrame: CGRect?

    var body: some View {
        HostedRowsTable(
            items: items, rowHeight: rowHeight, isEnabled: isEnabled, row: row,
            recorderFrame: $recorderFrame
        )
        .overlay(alignment: .topLeading) { recorderStandIn }
    }

    /// The open recorder's anchor can't leave its hosted row, so this republishes its bounds here.
    @ViewBuilder
    private var recorderStandIn: some View {
        if let recorderFrame {
            Color.clear
                .frame(width: recorderFrame.width, height: recorderFrame.height)
                .anchorPreference(key: ShortcutRecorderAnchorKey.self, value: .bounds) { $0 }
                .position(x: recorderFrame.midX, y: recorderFrame.midY)
                .allowsHitTesting(false)
        }
    }
}

private enum HostedRowsMetrics {
    /// Leave a little of the Form's edge inset at the first and last rows.
    static let overhang: CGFloat = 10
    static let searchDividerHeight: CGFloat = 1
    static let reuseID = NSUserInterfaceItemIdentifier("hostedRow")
}

private struct HostedRowsTable<Item: Identifiable & Equatable, Row: View>: NSViewRepresentable {
    let items: [Item]
    let rowHeight: CGFloat
    let isEnabled: Bool
    let row: @MainActor (Item) -> Row
    @Binding var recorderFrame: CGRect?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let table = ClickThroughTableView()
        table.headerView = nil
        table.style = .plain
        table.rowHeight = rowHeight
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.focusRingType = .none
        table.refusesFirstResponder = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("item"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        context.coordinator.table = table
        let container = OverhangingTableView(
            table: table,
            topOverhang: HostedRowsMetrics.overhang + HostedRowsMetrics.searchDividerHeight,
            bottomOverhang: HostedRowsMetrics.overhang)
        context.coordinator.container = container
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        context.coordinator.show(self)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSView, context: Context) -> CGSize? {
        let rows = CGFloat(items.count) * rowHeight
        return CGSize(
            width: proposal.width ?? nsView.frame.width,
            height: rows - 2 * HostedRowsMetrics.overhang - HostedRowsMetrics.searchDividerHeight)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        fileprivate weak var table: NSTableView?
        fileprivate weak var container: NSView?
        private var list: HostedRowsTable?
        private var shownIsEnabled = true
        private weak var recorderOwner: Cell?

        fileprivate func show(_ list: HostedRowsTable) {
            self.list = list
            guard let table else { return }
            if table.rowHeight != list.rowHeight { table.rowHeight = list.rowHeight }
            let refreshesAll = list.isEnabled != shownIsEnabled
            shownIsEnabled = list.isEnabled
            if table.numberOfRows != list.items.count {
                // Unclipped outside a window, where noting a new count builds every row.
                guard table.window != nil else { return table.reloadData() }
                table.noteNumberOfRowsChanged()
            }
            // Not `reloadData`: a filter keystroke re-renders only the rows whose item moved.
            table.enumerateAvailableRowViews { rowView, row in
                guard row < list.items.count, let cell = rowView.view(atColumn: 0) as? Cell,
                    refreshesAll || cell.shownItem != list.items[row]
                else { return }
                cell.show(content(for: row, of: list), item: list.items[row])
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            list?.items.count ?? 0
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let list else { return nil }
            let content = content(for: row, of: list)
            let reused = tableView.makeView(withIdentifier: HostedRowsMetrics.reuseID, owner: nil)
            let cell = reused as? Cell ?? Cell(content)
            cell.coordinator = self
            cell.show(content, item: list.items[row])
            return cell
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

        /// False past either end, so Tab leaves the table through the window's key view loop.
        fileprivate func focusAlias(from cell: Cell, backward: Bool) -> Bool {
            guard let table else { return false }
            let step = backward ? -1 : 1
            var row = table.row(for: cell) + step
            // A disabled alias refuses focus, so Tab passes over its row as a native one would.
            while row >= 0, row < table.numberOfRows {
                table.scrollRowToVisible(row)
                let next = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? Cell
                if next?.focusAlias() == true { return true }
                row += step
            }
            return false
        }

        fileprivate func recorderMoved(to frame: CGRect?, in cell: Cell) {
            if let frame {
                recorderOwner = cell
                publish(frame)
            } else if recorderOwner === cell {
                recorderOwner = nil
                publish(nil)
            }
        }

        private func publish(_ frame: CGRect?) {
            guard let list, list.recorderFrame != frame else { return }
            list.recorderFrame = frame
        }

        private func content(for row: Int, of list: HostedRowsTable) -> CellContent {
            CellContent(
                row: list.row(list.items[row]), showsDivider: row > 0, isEnabled: list.isEnabled)
        }
    }

    /// A reused row: its hosted controls survive, and only the item changes hands.
    final class Cell: NSTableCellView {
        weak var coordinator: Coordinator?
        private(set) var shownItem: Item?
        private let host: NSHostingView<CellContent>

        init(_ content: CellContent) {
            host = NSHostingView(rootView: content)
            super.init(frame: .zero)
            identifier = HostedRowsMetrics.reuseID
            // The table fixes the row height; a hosting view left to size itself would fight it.
            host.sizingOptions = []
            host.translatesAutoresizingMaskIntoConstraints = false
            addSubview(host)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: leadingAnchor),
                host.trailingAnchor.constraint(equalTo: trailingAnchor),
                host.topAnchor.constraint(equalTo: topAnchor),
                host.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        func show(_ content: CellContent, item: Item) {
            shownItem = item
            var content = content
            content.onRecorderFrame = { [weak self] frame in self?.recorderMoved(to: frame) }
            content.onAliasTab = { [weak self] backward in
                guard let self, let coordinator else { return false }
                return coordinator.focusAlias(from: self, backward: backward)
            }
            host.rootView = content
        }

        fileprivate func focusAlias() -> Bool {
            // A cell just scrolled in hasn't built its hosted views until it lays out.
            layoutSubtreeIfNeeded()
            guard let alias = aliasView else { return false }
            return window?.makeFirstResponder(alias) ?? false
        }

        /// The row's one editable text view is its alias; the name and the recorder are drawn text.
        private var aliasView: NSTextView? {
            var pending: [NSView] = [host]
            while let view = pending.popLast() {
                if let alias = view as? NSTextView, alias.isEditable { return alias }
                pending.append(contentsOf: view.subviews)
            }
            return nil
        }

        private func recorderMoved(to frame: CGRect?) {
            guard let coordinator, let container = coordinator.container else { return }
            coordinator.recorderMoved(to: frame.map { host.convert($0, to: container) }, in: self)
        }
    }

    /// What a cell hosts: the row, plus the hairline a `Form` row would draw above it.
    struct CellContent: View {
        let row: Row
        let showsDivider: Bool
        let isEnabled: Bool
        var onRecorderFrame: @MainActor (CGRect?) -> Void = { _ in }
        var onAliasTab: @MainActor (_ backward: Bool) -> Bool = { _ in false }

        var body: some View {
            VStack(spacing: 0) {
                Divider().opacity(showsDivider ? 1 : 0)
                row
                    // The key view loop can't reach a row the table hasn't built, so Tab asks here.
                    .environment(\.aliasTabHandler, AliasTabAction(onAliasTab))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .disabled(!isEnabled)
            // The recorder's anchor can't leave this hosting view; its bounds go out by hand.
            .overlayPreferenceValue(ShortcutRecorderAnchorKey.self) { anchor in
                GeometryReader { proxy in
                    Color.clear.onChange(of: anchor.map { proxy[$0] }, initial: true) { _, frame in
                        onRecorderFrame(frame)
                    }
                }
            }
        }
    }
}

/// Hangs the table into the `Form` row's padding: negative padding doesn't move an AppKit view.
private final class OverhangingTableView: NSView {
    private let table: NSTableView
    private let topOverhang: CGFloat
    private let bottomOverhang: CGFloat

    init(table: NSTableView, topOverhang: CGFloat, bottomOverhang: CGFloat) {
        self.table = table
        self.topOverhang = topOverhang
        self.bottomOverhang = bottomOverhang
        super.init(frame: .zero)
        addSubview(table)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        table.frame = NSRect(
            x: bounds.minX, y: bounds.minY - topOverhang,
            width: bounds.width, height: bounds.height + topOverhang + bottomOverhang)
    }
}

/// Hands every click to the hosted row; a table otherwise claims clicks that miss an `NSControl`.
private final class ClickThroughTableView: NSTableView {
    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool {
        true
    }
}
