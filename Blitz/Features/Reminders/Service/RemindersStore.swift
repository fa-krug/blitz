import AppKit
import EventKit

/// Open reminders, read from and written back to EventKit. See docs/features/reminders.md.
@MainActor
@Observable
final class RemindersStore {
    /// Every open reminder on a list that is switched on, in `ReminderAgenda.sorted` order.
    private(set) var reminders: [ReminderItem] = []
    private(set) var lists: [ReminderList] = []
    private(set) var access: CalendarAccess = Permissions.remindersAccess()
    /// False until the first fetch lands, so an empty list never claims there is nothing to do.
    private(set) var hasLoaded = false

    private let defaults = UserDefaults.standard
    private let hiddenKey = "hiddenReminderLists"
    /// Exclusions, not inclusions, so a list added after this was written defaults to on.
    private var hiddenListIDs: Set<String>

    /// Built on first use, so a Mac with the feature off never loads EventKit at launch.
    @ObservationIgnored private var eventStore: EKEventStore?
    @ObservationIgnored private var changeObserver: NotificationToken?
    /// Reminders are fetched asynchronously, so a newer reload cancels the one still in flight.
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    /// A change notice queued just before `stop` must not bring a stopped store back to life.
    @ObservationIgnored private var isRunning = false

    init() {
        hiddenListIDs = Set(defaults.stringArray(forKey: hiddenKey) ?? [])
    }

    /// TCC sends nothing when a grant changes in Settings, so anything acting on `access` re-reads.
    func refreshAccess() {
        access = Permissions.remindersAccess()
    }

    // MARK: - Lifecycle

    func start() {
        isRunning = true
        refreshAccess()
        guard access == .granted else { return }
        reload()
    }

    func stop() {
        isRunning = false
        reloadTask?.cancel()
        reloadTask = nil
        changeObserver = nil
        eventStore = nil
        publish([])
        lists = []
        hasLoaded = false
    }

    /// Blitz's own consent dialog has already been accepted by the time this runs.
    func requestAccess() async -> Bool {
        let granted = await Permissions.requestRemindersAccess()
        refreshAccess()
        guard granted else { return false }
        // A store built before the grant never sees the new lists; drop it and rebuild.
        changeObserver = nil
        eventStore = nil
        reload()
        return true
    }

    /// EventKit says when to reload, which covers an edit made in Reminders.app or on another Mac.
    private func observeStoreChanges() {
        guard changeObserver == nil, let eventStore else { return }
        let center = NotificationCenter.default
        let token = center.addObserver(
            forName: .EKEventStoreChanged, object: eventStore, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        changeObserver = NotificationToken(token, center: center)
    }

    // MARK: - Reading

    func reload() {
        guard isRunning else { return }
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in await self?.load() }
    }

    /// `EKEventStore` is not `Sendable`, so it stays on main; only the fetch itself runs elsewhere.
    private func load() async {
        refreshAccess()
        guard access == .granted else {
            publish([])
            lists = []
            return
        }
        let store = currentStore()
        observeStoreChanges()

        let sources = store.calendars(for: .reminder)
        let nextLists =
            sources
            .map {
                ReminderList(
                    id: $0.calendarIdentifier, title: $0.title, accountName: $0.source.title)
            }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        if nextLists != lists { lists = nextLists }

        let selected = sources.filter { !hiddenListIDs.contains($0.calendarIdentifier) }
        guard !selected.isEmpty else {
            publish([])
            return
        }
        let colors = Dictionary(
            selected.compactMap { list in Self.color(of: list).map { (list.calendarIdentifier, $0) } },
            uniquingKeysWith: { first, _ in first })
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil, ending: nil, calendars: selected)
        let fetched = await withCheckedContinuation { continuation in
            Self.fetch(predicate, from: store, colors: colors, into: continuation)
        }
        guard !Task.isCancelled else { return }
        publish(ReminderAgenda.sorted(fetched, calendar: .current))
    }

    /// Nonisolated, so EventKit's completion runs on its own queue without a main-actor check.
    nonisolated private static func fetch(
        _ predicate: NSPredicate, from store: EKEventStore,
        colors: [String: ReminderItem.ListColor],
        into continuation: CheckedContinuation<[ReminderItem], Never>
    ) {
        store.fetchReminders(matching: predicate) { reminders in
            let items = (reminders ?? []).compactMap { item(from: $0, colors: colors) }
            continuation.resume(returning: items)
        }
    }

    private func publish(_ next: [ReminderItem]) {
        if access == .granted, !hasLoaded { hasLoaded = true }
        guard next != reminders else { return }
        reminders = next
    }

    nonisolated private static func item(
        from reminder: EKReminder, colors: [String: ReminderItem.ListColor]
    ) -> ReminderItem? {
        guard let list = reminder.calendar else { return nil }
        return ReminderItem(
            id: reminder.calendarItemIdentifier,
            title: reminder.title ?? "(No Title)",
            notes: reminder.notes,
            due: reminder.dueDateComponents.flatMap(due(from:)),
            listID: list.calendarIdentifier,
            listName: list.title,
            listColor: colors[list.calendarIdentifier])
    }

    /// A timed reminder may carry the zone it was set in; it is read back in this Mac's zone.
    nonisolated private static func due(from components: DateComponents) -> ReminderDue? {
        guard components.hour != nil, let date = Calendar.current.date(from: components) else {
            return ReminderDue(components: components)
        }
        return ReminderDue(date: date, includesTime: true, calendar: .current)
    }

    private static func color(of list: EKCalendar) -> ReminderItem.ListColor? {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
            let components = list.cgColor?.converted(
                to: space, intent: .defaultIntent, options: nil)?.components,
            components.count >= 3
        else { return nil }
        return ReminderItem.ListColor(
            red: components[0], green: components[1], blue: components[2])
    }

    func reminder(id: ReminderItem.ID) -> ReminderItem? {
        reminders.first { $0.id == id }
    }

    /// The snapshot once a fetch has landed; a chat can ask before the first one has.
    func loadedReminders() async -> [ReminderItem] {
        if !hasLoaded, reloadTask == nil { reload() }
        // A newer reload cancels the one awaited here, so wait on whichever is current.
        while !hasLoaded, let task = reloadTask {
            await task.value
            if task == reloadTask { break }
        }
        return reminders
    }

    // MARK: - Writing

    /// The id Reminders.app opens it by; nil means no list accepts it, a report, not a no-op.
    func create(_ draft: ReminderDraft) -> ReminderItem.ID? {
        let store = currentStore()
        guard access == .granted, let list = store.defaultCalendarForNewReminders() else {
            return nil
        }
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = list
        apply(draft, to: reminder, dueChanged: true)
        guard save(reminder, in: store) else { return nil }
        return reminder.calendarItemIdentifier
    }

    /// False when the reminder is gone or will not save; its list and alarms are left as they were.
    func update(_ item: ReminderItem, with draft: ReminderDraft) -> Bool {
        guard case let (reminder, store)? = stored(item) else { return false }
        apply(draft, to: reminder, dueChanged: draft.due != item.due)
        return save(reminder, in: store)
    }

    func complete(_ item: ReminderItem) -> Bool {
        guard case let (reminder, store)? = stored(item) else { return false }
        reminder.isCompleted = true
        return save(reminder, in: store)
    }

    func delete(_ item: ReminderItem) -> Bool {
        guard case let (reminder, store)? = stored(item),
            (try? store.remove(reminder, commit: true)) != nil
        else { return false }
        reload()
        return true
    }

    private func currentStore() -> EKEventStore {
        let store = eventStore ?? EKEventStore()
        eventStore = store
        return store
    }

    private func stored(_ item: ReminderItem) -> (EKReminder, EKEventStore)? {
        let store = currentStore()
        guard access == .granted,
            let reminder = store.calendarItem(withIdentifier: item.id) as? EKReminder
        else { return nil }
        return (reminder, store)
    }

    private func save(_ reminder: EKReminder, in store: EKEventStore) -> Bool {
        guard (try? store.save(reminder, commit: true)) != nil else { return false }
        reload()
        return true
    }

    private func apply(_ draft: ReminderDraft, to reminder: EKReminder, dueChanged: Bool) {
        reminder.title = draft.trimmedTitle
        reminder.notes = draft.trimmedNotes
        guard dueChanged else { return }
        reminder.dueDateComponents = draft.due.map(Self.components(of:))
        // Only a dated alarm follows the due date; a location alarm set in Reminders stays put.
        for alarm in reminder.alarms ?? [] where alarm.absoluteDate != nil {
            reminder.removeAlarm(alarm)
        }
        guard draft.due?.time != nil, let date = draft.due?.date(in: .current) else { return }
        reminder.addAlarm(EKAlarm(absoluteDate: date))
    }

    /// A timed reminder is pinned to this Mac's zone; a day-only one floats, as Reminders.app's do.
    nonisolated private static func components(of due: ReminderDue) -> DateComponents {
        var components = due.components
        if due.time != nil { components.timeZone = .current }
        return components
    }

    // MARK: - Per-list switches

    func isEnabled(_ list: ReminderList) -> Bool {
        !hiddenListIDs.contains(list.id)
    }

    func setEnabled(_ enabled: Bool, for list: ReminderList) {
        if enabled {
            hiddenListIDs.remove(list.id)
        } else {
            hiddenListIDs.insert(list.id)
        }
        defaults.set(Array(hiddenListIDs), forKey: hiddenKey)
        reload()
    }
}
