import Observation

/// Not on `AppCore`: one window's session, restarted on every reopen so history never survives.
@MainActor
@Observable
final class SettingsNavigationState {
    private var history: SettingsHistory
    private var requests = 0
    /// Bumped by `restart`, so the pane remounts and its appear-time refreshes run again.
    private(set) var session = 0

    init(tab: SettingsTab) {
        history = SettingsHistory(current: SettingsLocation(tab))
    }

    var tab: SettingsTab { history.current.tab }
    /// The current pane's own page, if one is open; nil is the pane itself.
    var page: String? { history.current.page }
    var canGoBack: Bool { history.canGoBack }
    var canGoForward: Bool { history.canGoForward }

    /// Set by a search result, consumed by the pane that scrolls to it.
    private(set) var scrollRequest: SettingsScrollRequest?
    /// The section lit right now. One source for the whole window, so a pane swap can't lose it.
    private(set) var flashing: SettingsTarget?

    /// A page names one of the pane's own; a search result also asks the pane to reveal a section.
    func select(_ tab: SettingsTab, page: String? = nil, revealing target: SettingsTarget? = nil) {
        history.select(SettingsLocation(tab, page: page))
        // Any navigation puts the previous pulse out, so a stale light can't outlive its pane.
        flashing = nil
        guard let target else { return }
        requests += 1
        scrollRequest = SettingsScrollRequest(target: target, token: requests)
    }

    /// A reopened window starts as a new one would: on `tab`, with no history behind it.
    func restart(on tab: SettingsTab, page: String?, revealing target: SettingsTarget?) {
        history = SettingsHistory(current: SettingsLocation(tab))
        scrollRequest = nil
        session += 1
        select(tab, page: page, revealing: target)
    }

    func beginFlash(_ target: SettingsTarget) {
        flashing = target
    }

    /// Ends the pulse, unless a later jump has already lit something else.
    func endFlash(_ target: SettingsTarget) {
        guard flashing == target else { return }
        flashing = nil
    }

    /// Released after the pulse: it keys the pane's task, so clearing it early cancels the reveal.
    func clear(_ request: SettingsScrollRequest) {
        guard scrollRequest == request else { return }
        scrollRequest = nil
    }

    func goBack() { history.goBack() }
    func goForward() { history.goForward() }
}
