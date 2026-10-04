/// Where the Settings window is: a pane, and optionally one of that pane's own pages.
struct SettingsLocation: Equatable {
    let tab: SettingsTab
    /// Named by the pane that owns it, so the window never needs to know what a page holds.
    let page: String?

    init(_ tab: SettingsTab, page: String? = nil) {
        self.tab = tab
        self.page = page
    }
}

/// Browser semantics: choosing a location truncates what was ahead; re-choosing it is no move.
struct SettingsHistory {
    private(set) var current: SettingsLocation
    private var back: [SettingsLocation] = []
    private var forward: [SettingsLocation] = []

    init(current: SettingsLocation) {
        self.current = current
    }

    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }

    mutating func select(_ location: SettingsLocation) {
        guard location != current else { return }
        back.append(current)
        forward.removeAll()
        current = location
    }

    mutating func goBack() {
        guard let previous = back.popLast() else { return }
        forward.append(current)
        current = previous
    }

    mutating func goForward() {
        guard let next = forward.popLast() else { return }
        back.append(current)
        current = next
    }
}
