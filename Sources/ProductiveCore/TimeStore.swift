import Foundation

public protocol TokenStoring: Sendable {
    func read() -> String?
    @discardableResult func write(_ token: String) -> Bool
}

extension KeychainStore: TokenStoring {}
extension FileTokenStore: Sendable {}

/// A start or stop that could not reach Productive. Sent at the next successful refresh.
/// Every action sends absolute minutes, so a retry after a partial failure gives the same result.
enum PendingAction: Equatable {
    /// Start a timer on `service`. `at` is the click time. `entryID` is the entry to continue
    /// (with `baseMinutes`), or nil to create one.
    case start(id: UUID, service: Service, at: Date, entryID: String?, baseMinutes: Int, note: String)
    /// Stop timer `timerID`, and set its entry to `baseMinutes` + the minutes from `startedAt` to `at`.
    case stop(id: UUID, timerID: String, entryID: String, startedAt: Date, baseMinutes: Int, at: Date)
    /// A start and stop that both happened offline: set `entryID` to `baseMinutes + minutes`,
    /// or create an entry of `minutes` when `entryID` is nil.
    case log(id: UUID, service: Service, day: Day, entryID: String?, baseMinutes: Int, minutes: Int, note: String)

    var id: UUID {
        switch self {
        case .start(let id, _, _, _, _, _), .stop(let id, _, _, _, _, _), .log(let id, _, _, _, _, _, _): return id
        }
    }
}

/// The local state at a stop, used to send the stop and to undo it if Productive refuses it.
private struct StopSnapshot {
    let timer: RunningTimer
    let baseMinutes: Int
    let previousMinutes: Int?
}

/// The app state. The only object that calls `ProductiveAPI`.
///
/// Concurrency model: user actions change the published state at once (optimistic UI) and
/// increase `generation`. The API work of every action and refresh runs one at a time on a
/// serial queue. A refresh discards its results when `generation` changed while it waited,
/// so an old server response never overwrites a newer user action.
@MainActor
public final class TimeStore: ObservableObject {
    public enum Phase: Equatable { case setup, ready }

    @Published public private(set) var phase: Phase = .setup
    @Published public private(set) var person: Person?
    @Published public private(set) var entries: [TimeEntry] = []
    @Published public private(set) var timer: RunningTimer?
    @Published public private(set) var services: [Service] = []
    @Published public private(set) var favourites: [Favourite] = []
    /// Favourites whose budget closed, keyed by the old service id, with the proposed new service.
    @Published public private(set) var replacements: [String: Service] = [:]
    @Published public private(set) var weekDays: [Day] = []
    @Published public var selectedDay: Day
    @Published public private(set) var lastError: String?
    @Published public private(set) var isOffline = false
    @Published public private(set) var isLoading = false
    @Published public private(set) var now: Date
    @Published public private(set) var weeklyTargetMinutes: Int
    @Published public private(set) var firstWeekday: Int
    @Published public private(set) var showWeekends: Bool
    @Published public private(set) var idleDetection: Bool
    @Published public private(set) var idleMinutes: Int
    /// Calendar meetings by day, loaded for the selected day.
    @Published public private(set) var calendar: [Day: [CalendarEvent]] = [:]

    private let settings: SettingsStore
    private let tokenStore: TokenStoring
    private let makeAPI: (ProductiveConfig) -> ProductiveAPI
    private let clock: () -> Date
    private var api: ProductiveAPI?
    private(set) var pending: [PendingAction] = []
    /// The running entry's minutes when the timer started (Productive adds the session on stop).
    private var timerBaseMinutes = 0
    private var servicesLoadedAt: Date?
    private var ticker: Timer?
    private var poller: Timer?

    private var generation = 0
    private var tail: Task<Void, Never>?
    private var refreshQueued = false
    /// Real timers for optimistic starts, keyed by the start's action id.
    private var startedTimers: [UUID: RunningTimer] = [:]
    private static let placeholderPrefix = "pending-"
    /// Entries that already got an automatic note (or failed to), so each gets one try per launch.
    private var autoNoted: Set<String> = []

    public init(settings: SettingsStore = SettingsStore(),
                tokenStore: TokenStoring = FileTokenStore(),
                makeAPI: @escaping (ProductiveConfig) -> ProductiveAPI = { ProductiveClient(config: $0) },
                clock: @escaping () -> Date = Date.init) {
        self.settings = settings
        self.tokenStore = tokenStore
        self.makeAPI = makeAPI
        self.clock = clock
        let now = clock()
        self.now = now
        self.selectedDay = Day(now)
        self.weeklyTargetMinutes = settings.weeklyTargetMinutes
        self.firstWeekday = settings.firstWeekday
        self.showWeekends = settings.showWeekends
        self.idleDetection = settings.idleDetection
        self.idleMinutes = settings.idleMinutes
        self.favourites = settings.favourites
        self.weekDays = Week.days(containing: Day(now), firstWeekday: settings.firstWeekday)
    }

    // MARK: - Derived values

    public var today: Day { Day(now) }
    public var isRunning: Bool { timer != nil }
    public var organizationID: String { settings.organizationID }
    /// The token is read once per launch.
    private var cachedToken: String?
    public var hasStoredToken: Bool { !(cachedToken ?? "").isEmpty }
    public var lastService: Service? { settings.lastService }

    /// The entry that ▶ resumes: the last entry, when it is from today and can still change.
    public var resumableEntry: TimeEntry? {
        guard let last = settings.lastEntry, last.day == today,
              let entry = entries.first(where: { $0.id == last.entryID }), !entry.isLocked else { return nil }
        return entry
    }

    public var runningEntry: TimeEntry? {
        guard let timer else { return nil }
        return entries.first { $0.id == timer.timeEntryID } ?? timer.entry
    }

    public var runningService: Service? { runningEntry?.service }

    public var runningSeconds: Int {
        guard let timer else { return 0 }
        return timerBaseMinutes * 60 + max(0, Int(now.timeIntervalSince(timer.startedAt)))
    }

    /// Minutes of an entry, with the running session added when its timer runs.
    public func liveMinutes(_ entry: TimeEntry) -> Int {
        guard let timer, timer.timeEntryID == entry.id else { return entry.minutes }
        return runningSeconds / 60
    }

    public func entries(on day: Day) -> [TimeEntry] {
        var list = entries.filter { $0.day == day }
        if let running = runningEntry, running.day == day, !list.contains(where: { $0.id == running.id }) {
            list.append(running)
        }
        return list
    }

    public func entry(id: String) -> TimeEntry? {
        entries.first { $0.id == id } ?? (runningEntry?.id == id ? runningEntry : nil)
    }

    public func total(on day: Day) -> Int { entries(on: day).reduce(0) { $0 + liveMinutes($1) } }
    /// The days in the week strip: all 7, or Monday to Friday. Totals still count all 7 days.
    public var visibleWeekDays: [Day] {
        showWeekends ? weekDays : weekDays.filter { !Calendar.current.isDateInWeekend($0.date()) }
    }

    public var weekTotal: Int { weekDays.reduce(0) { $0 + total(on: $1) } }
    public var isCurrentWeek: Bool { weekDays.contains(today) }

    /// The number in the menu bar: the running entry, or the entry that ▶ resumes.
    public var menuBarMinutes: Int {
        if let running = runningEntry { return liveMinutes(running) }
        return resumableEntry?.minutes ?? 0
    }

    // MARK: - Serial queue

    /// Runs `op` after all earlier queued operations.
    private func serial<T>(_ op: @escaping @MainActor () async -> T) async -> T {
        let previous = tail
        let task = Task { @MainActor () -> T in
            await previous?.value
            return await op()
        }
        tail = Task { _ = await task.value }
        return await task.value
    }

    // MARK: - Lifecycle

    public func bootstrap() {
        guard !settings.organizationID.isEmpty, let token = tokenStore.read(), !token.isEmpty else {
            phase = .setup
            return
        }
        cachedToken = token
        api = makeAPI(ProductiveConfig(token: token, organizationID: settings.organizationID))
        person = settings.person
        phase = .ready
        startClocks()
        Task { await refresh() }
    }

    /// Checks the token, stores it, and loads data. Returns the person on success.
    /// An empty `token` keeps the saved token (for example, to change only the organisation ID).
    @discardableResult
    public func connect(token: String, organizationID: String) async -> Person? {
        let typed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = typed.isEmpty ? (cachedToken ?? "") : typed
        let org = organizationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = makeAPI(ProductiveConfig(token: token, organizationID: org))
        let me: Person
        do {
            me = try await candidate.me()
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
        if token != cachedToken {
            guard tokenStore.write(token) else {
                lastError = "Could not save the token in the Keychain."
                return nil
            }
            cachedToken = token
        }
        let sameAccount = me.id == person?.id && org == settings.organizationID
        generation += 1 // Discard any refresh of the old account that is still running.
        if !sameAccount { resetAccountState() }
        settings.organizationID = org
        settings.person = me
        api = candidate
        person = me
        phase = .ready
        lastError = nil
        servicesLoadedAt = nil
        startClocks()
        await serial { [weak self] in await self?.performRefresh() }
        return me
    }

    public func signOut() {
        generation += 1
        tokenStore.write("")
        cachedToken = nil
        settings.person = nil
        api = nil
        person = nil
        resetAccountState()
        phase = .setup
        stopClocks()
    }

    private func resetAccountState() {
        timer = nil
        entries = []
        services = []
        replacements = [:]
        pending = []
        startedTimers = [:]
        calendar = [:]
        isOffline = false
    }

    private func startClocks() {
        guard ticker == nil else { return }
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.advanceClock() }
        }
        poller = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = Task { await self?.refresh() } }
        }
    }

    private func stopClocks() {
        ticker?.invalidate()
        poller?.invalidate()
        ticker = nil
        poller = nil
    }

    /// Reads the clock. At midnight, moves the week view to the new day when it showed the old day.
    @discardableResult
    func advanceClock() -> Date {
        let previousDay = Day(now)
        now = clock()
        let newDay = today
        if newDay != previousDay {
            if selectedDay == previousDay { selectedDay = newDay }
            if weekDays.contains(previousDay) { weekDays = Week.days(containing: newDay, firstWeekday: firstWeekday) }
        }
        return now
    }

    // MARK: - Refresh

    public func refresh() async {
        guard api != nil, !refreshQueued else { return }
        refreshQueued = true
        await serial { [weak self] in
            self?.refreshQueued = false
            await self?.performRefresh()
        }
    }

    public func refreshServices() async {
        await serial { [weak self] in await self?.performServicesRefresh() }
    }

    /// Runs on the serial queue only.
    private func performRefresh() async {
        guard let api, let person else { return }
        let gen = generation
        isLoading = true
        defer { isLoading = false }
        advanceClock()
        do {
            try await flushPending(api: api, person: person)
            async let timers = api.recentTimers(personID: person.id)
            let entryList = try await loadEntries(api: api, personID: person.id)
            let running = try await timers.first(where: \.isRunning)
            // A user action changed the state while this refresh waited; its own work follows.
            guard gen == generation else { return }
            entries = entryList
            setTimer(running)
            if let entry = runningEntry, !entry.isPending { remember(entry) }
            await loadCalendar(selectedDay, force: true)
            isOffline = false
            lastError = nil
            await fillJiraNotes(api: api)
            if servicesLoadedAt.map({ now.timeIntervalSince($0) > 6 * 3600 }) ?? true {
                await performServicesRefresh()
            }
        } catch {
            guard gen == generation else { return }
            handle(error)
        }
    }

    /// Entries tracked from Jira have no note. Set the note to the experiment code ("E97", "E83 QA").
    /// A note that is only the bare code (set by an older version) is upgraded to add "QA".
    private func fillJiraNotes(api: ProductiveAPI) async {
        let candidates = entries.filter { entry in
            guard let jira = entry.jira, let code = jira.experimentCode,
                  !entry.isLocked, !entry.isPending, !autoNoted.contains(entry.id) else { return false }
            return entry.note.isEmpty || (entry.note == jira.baseExperimentCode && entry.note != code)
        }
        for entry in candidates {
            autoNoted.insert(entry.id)
            guard let code = entry.jira?.experimentCode,
                  let updated = try? await api.updateTimeEntry(id: entry.id, changes: EntryChanges(note: code)),
                  let i = entries.firstIndex(where: { $0.id == entry.id }) else { continue }
            var merged = updated
            if merged.jira == nil { merged.jira = entry.jira }
            entries[i] = merged
        }
    }

    private func performServicesRefresh() async {
        guard let api, let person else { return }
        let gen = generation
        do {
            let list = try await api.trackableServices(personID: person.id).sorted {
                ($0.shortClientName.lowercased(), $0.budgetName, $0.section, $0.position ?? 0, $0.name)
                    < ($1.shortClientName.lowercased(), $1.budgetName, $1.section, $1.position ?? 0, $1.name)
            }
            guard person == self.person else { return }
            services = list
            servicesLoadedAt = clock()
            resolveFavourites()
        } catch {
            guard gen == generation else { return }
            handle(error)
        }
    }

    private func loadEntries(api: ProductiveAPI, personID: String) async throws -> [TimeEntry] {
        let current = Week.days(containing: today, firstWeekday: firstWeekday)
        var list = try await api.timeEntries(personID: personID, from: current.first!, to: current.last!)
        if weekDays != current, let first = weekDays.first, let last = weekDays.last {
            list += try await api.timeEntries(personID: personID, from: first, to: last)
        }
        return list
    }

    private func setTimer(_ newTimer: RunningTimer?) {
        if let newTimer, newTimer.id != timer?.id {
            timerBaseMinutes = (entries.first { $0.id == newTimer.timeEntryID } ?? newTimer.entry)?.minutes ?? 0
        }
        timer = newTimer
    }

    private func handle(_ error: Error) {
        let e = error as? ProductiveError
        switch e {
        case .offline?:
            isOffline = true
        case .unauthorized?:
            stopClocks()
            api = nil
            phase = .setup
            lastError = e?.errorDescription
        default:
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    public func clearError() { lastError = nil }

    // MARK: - Timer actions

    /// The menu bar ▶ / ■ click. Returns false when the app needs the picker (no last service).
    @discardableResult
    public func toggle() async -> Bool {
        if isRunning {
            await stop()
            return true
        }
        if let entry = resumableEntry {
            await start(resolvedService(for: entry.service), continuing: entry)
            return true
        }
        guard let last = settings.lastService else { return false }
        // After midnight (or when the last entry is gone): a new entry on the same service, same note.
        let note = settings.lastEntry.flatMap { $0.serviceID == last.id ? $0.note : nil } ?? ""
        await start(resolvedService(for: last), note: note)
        return true
    }

    private func remember(_ entry: TimeEntry) {
        settings.lastService = entry.service
        settings.lastEntry = LastEntry(entryID: entry.id, day: entry.day, serviceID: entry.service.id, note: entry.note)
    }

    /// Starts `service`.
    /// - With `preferred`: continues that entry when it is from today, else makes a new entry with its note.
    /// - Without: continues today's entry on the service that has no note, else makes a new entry with `note`.
    public func start(_ service: Service, continuing preferred: TimeEntry? = nil, note: String = "") async {
        guard api != nil, person != nil else { return }
        // A second click on what already runs does nothing (for example, a double click).
        if let running = runningEntry, running.service.id == service.id, preferred == nil || preferred?.id == running.id {
            return
        }
        let startedAt = advanceClock()
        let previous = timer.map { localStop($0, at: startedAt) }

        let today = Day(startedAt)
        let usable: (TimeEntry) -> Bool = { $0.day == today && !$0.isLocked && !$0.isPending }
        let existing: TimeEntry?
        let newNote: String
        if let preferred {
            existing = usable(preferred) ? preferred : nil
            newNote = preferred.note
        } else {
            existing = note.isEmpty ? entries.first { usable($0) && $0.service.id == service.id && $0.note.isEmpty } : nil
            newNote = note
        }
        settings.lastService = service

        // Show the timer at once.
        let actionID = UUID()
        let placeholderID = Self.placeholderPrefix + actionID.uuidString
        let placeholder = existing
            ?? TimeEntry(id: Self.placeholderPrefix + "entry", day: today, minutes: 0, note: newNote, service: service)
        generation += 1
        timerBaseMinutes = placeholder.minutes
        timer = RunningTimer(id: placeholderID, startedAt: startedAt, timeEntryID: placeholder.id, entry: placeholder)

        await serial { [weak self] in
            guard let self else { return }
            if let previous { await self.performStop(previous, at: startedAt, refreshAfter: false) }
            await self.performStart(actionID, service: service, existing: existing, note: newNote, at: startedAt)
        }
    }

    private func performStart(_ actionID: UUID, service: Service, existing: TimeEntry?, note: String, at startedAt: Date) async {
        guard let api, let person else { return }
        let placeholderID = Self.placeholderPrefix + actionID.uuidString
        var entry = existing
        do {
            if entry == nil {
                let created = try await api.createTimeEntry(personID: person.id, serviceID: service.id,
                                                            day: Day(startedAt), minutes: 0, note: note)
                entries.append(created)
                entry = created
            }
            var started = try await api.startTimer(timeEntryID: entry!.id)
            if started.entry == nil { started.entry = entry }
            startedTimers[actionID] = started
            remember(entry!)
            if timer?.id == placeholderID {
                timerBaseMinutes = entry!.minutes
                timer = started
            }
            lastError = nil
        } catch ProductiveError.offline {
            isOffline = true
            pending.append(.start(id: actionID, service: service, at: startedAt,
                                  entryID: entry?.id, baseMinutes: entry?.minutes ?? 0, note: note))
        } catch {
            if timer?.id == placeholderID { timer = nil }
            handle(error)
        }
    }

    public func stop() async {
        guard let running = timer else { return }
        let stoppedAt = advanceClock()
        let snapshot = localStop(running, at: stoppedAt)
        await serial { [weak self] in await self?.performStop(snapshot, at: stoppedAt, refreshAfter: true) }
    }

    /// Shows a stop at once and returns what `performStop` needs.
    private func localStop(_ running: RunningTimer, at stoppedAt: Date) -> StopSnapshot {
        let index = entries.firstIndex { $0.id == running.timeEntryID }
        let snapshot = StopSnapshot(timer: running, baseMinutes: timerBaseMinutes,
                                    previousMinutes: index.map { entries[$0].minutes })
        generation += 1
        timer = nil
        if let index { entries[index].minutes = timerBaseMinutes + Self.minutes(from: running.startedAt, to: stoppedAt) }
        return snapshot
    }

    /// Runs on the serial queue only.
    private func performStop(_ snapshot: StopSnapshot, at stoppedAt: Date, refreshAfter: Bool) async {
        guard let api else { return }
        var target = snapshot.timer

        if target.id.hasPrefix(Self.placeholderPrefix), let actionID = UUID(uuidString: String(target.id.dropFirst(Self.placeholderPrefix.count))) {
            if let i = pending.firstIndex(where: { $0.id == actionID }),
               case .start(_, let service, let at, let entryID, let base, let note) = pending[i] {
                // The start never reached Productive: log the whole block instead.
                pending[i] = .log(id: actionID, service: service, day: Day(at), entryID: entryID,
                                  baseMinutes: base, minutes: Self.minutes(from: at, to: stoppedAt), note: note)
                return
            }
            guard let real = startedTimers.removeValue(forKey: actionID) else { return } // The start failed.
            target = real
        }

        do {
            _ = try await api.stopTimer(id: target.id)
            if refreshAfter { await performRefresh() }
        } catch ProductiveError.offline {
            isOffline = true
            pending.append(.stop(id: UUID(), timerID: target.id, entryID: target.timeEntryID,
                                 startedAt: target.startedAt, baseMinutes: snapshot.baseMinutes, at: stoppedAt))
        } catch {
            // Undo the local stop, unless the user started something else in the meantime.
            if timer == nil {
                if let old = snapshot.previousMinutes, let i = entries.firstIndex(where: { $0.id == target.timeEntryID }) {
                    entries[i].minutes = old
                }
                timerBaseMinutes = snapshot.baseMinutes
                timer = target
            }
            handle(error)
        }
    }

    /// Removes the time after `idleStart` from the running entry. The timer stops; with `keepRunning`
    /// it starts again on the same entry, so the work continues without the idle minutes.
    public func removeIdleTime(since idleStart: Date, keepRunning: Bool) async {
        guard let running = timer, !running.id.hasPrefix(Self.placeholderPrefix), api != nil else { return }
        let entryID = running.timeEntryID
        let kept = timerBaseMinutes + Self.minutes(from: running.startedAt, to: max(idleStart, running.startedAt))
        advanceClock()
        // Show it at once.
        generation += 1
        timer = nil
        if let i = entries.firstIndex(where: { $0.id == entryID }) { entries[i].minutes = kept }

        await serial { [weak self] in
            guard let self, let api = self.api else { return }
            do {
                _ = try await api.stopTimer(id: running.id)
                var updated = try await api.updateTimeEntry(id: entryID, changes: EntryChanges(minutes: kept))
                if updated.jira == nil { updated.jira = running.entry?.jira ?? self.entries.first { $0.id == entryID }?.jira }
                if let i = self.entries.firstIndex(where: { $0.id == entryID }) { self.entries[i] = updated }
                if keepRunning {
                    var restarted = try await api.startTimer(timeEntryID: entryID)
                    if restarted.entry == nil { restarted.entry = updated }
                    self.timerBaseMinutes = kept
                    self.timer = restarted
                }
                self.lastError = nil
            } catch {
                self.handle(error)
                await self.performRefresh()
            }
        }
    }

    /// Runs on the serial queue only (inside `performRefresh`).
    private func flushPending(api: ProductiveAPI, person: Person) async throws {
        while let action = pending.first {
            switch action {
            case .start(let id, let service, let at, let entryID, let base, let note):
                let gap = Self.minutes(from: at, to: clock())
                let entry: TimeEntry
                if let entryID {
                    entry = try await api.updateTimeEntry(id: entryID, minutes: base + gap, note: nil)
                } else {
                    entry = try await api.createTimeEntry(personID: person.id, serviceID: service.id,
                                                          day: Day(at), minutes: gap, note: note)
                    // A retry must continue this entry, not create a second one.
                    replacePending(id, with: .start(id: id, service: service, at: at, entryID: entry.id,
                                                    baseMinutes: 0, note: note))
                }
                startedTimers[id] = try await api.startTimer(timeEntryID: entry.id)

            case .stop(_, let timerID, let entryID, let startedAt, let base, let at):
                do { _ = try await api.stopTimer(id: timerID) }
                catch let e as ProductiveError where e.isNetwork { throw e }
                catch { /* The timer was already stopped somewhere else. */ }
                _ = try await api.updateTimeEntry(id: entryID, minutes: base + Self.minutes(from: startedAt, to: at), note: nil)

            case .log(let id, let service, let day, let entryID, let base, let minutes, let note):
                if let entryID {
                    _ = try await api.updateTimeEntry(id: entryID, minutes: base + minutes, note: nil)
                } else {
                    let entry = try await api.createTimeEntry(personID: person.id, serviceID: service.id,
                                                              day: day, minutes: minutes, note: note)
                    replacePending(id, with: .log(id: id, service: service, day: day, entryID: entry.id,
                                                  baseMinutes: 0, minutes: minutes, note: note))
                }
            }
            pending.removeAll { $0.id == action.id }
        }
    }

    private func replacePending(_ id: UUID, with action: PendingAction) {
        if let i = pending.firstIndex(where: { $0.id == id }) { pending[i] = action }
    }

    private static func minutes(from start: Date, to end: Date) -> Int {
        max(0, Int(end.timeIntervalSince(start)) / 60)
    }

    // MARK: - Entries

    /// Adds a manual entry. With `event`, it also remembers the meeting as logged and its service.
    @discardableResult
    public func addEntry(service: Service, day: Day, minutes: Int, note: String, event: CalendarEvent? = nil) async -> Bool {
        generation += 1
        return await serial { [weak self] in
            guard let self, let api = self.api, let person = self.person else { return false }
            do {
                let entry = try await api.createTimeEntry(personID: person.id, serviceID: service.id, day: day, minutes: minutes, note: note)
                self.entries.append(entry)
                if let event {
                    self.settings.calendarLinks[event.id] = entry.id
                    self.settings.meetingServices[event.seriesKey] = service
                }
                return true
            } catch {
                self.handle(error)
                return false
            }
        }
    }

    // MARK: - Calendar

    /// All calendar events of `day` (loaded by `loadCalendar`), in time order.
    public func meetings(on day: Day) -> [CalendarEvent] {
        calendar[day] ?? []
    }

    /// The entry that logged `event`, if it still exists.
    public func loggedEntry(for event: CalendarEvent) -> TimeEntry? {
        settings.calendarLinks[event.id].flatMap { id in entries.first { $0.id == id } }
    }

    /// The service used the last time for this meeting (series), with fresh labels.
    public func rememberedService(for event: CalendarEvent) -> Service? {
        settings.meetingServices[event.seriesKey].map(resolvedService(for:))
    }

    /// Loads the meetings of `day`. Errors are ignored: the calendar is optional.
    public func loadCalendar(_ day: Day, force: Bool = false) async {
        guard let api, let person, force || calendar[day] == nil else { return }
        guard let events = try? await api.calendarEvents(personID: person.id, day: day), person == self.person else { return }
        calendar[day] = events
    }

    public func updateEntry(_ entry: TimeEntry, minutes: Int?, note: String?) async -> Bool {
        await updateEntry(entry, changes: EntryChanges(minutes: minutes, note: note))
    }

    /// Nil fields keep their value. For the running entry, only the note can change:
    /// the timer owns its time, service and date.
    public func updateEntry(_ entry: TimeEntry, changes: EntryChanges) async -> Bool {
        guard !entry.isLocked, !entry.isPending else { return false }
        generation += 1
        return await serial { [weak self] in
            guard let self, let api = self.api else { return false }
            var changes = changes
            if self.timer?.timeEntryID == entry.id { changes = EntryChanges(note: changes.note) }
            guard !changes.isEmpty else { return true }
            do {
                let updated = try await api.updateTimeEntry(id: entry.id, changes: changes)
                if let i = self.entries.firstIndex(where: { $0.id == entry.id }) { self.entries[i] = updated }
                if self.settings.lastEntry?.entryID == entry.id { self.remember(updated) }
                return true
            } catch {
                self.handle(error)
                return false
            }
        }
    }

    public func deleteEntry(_ entry: TimeEntry) async -> Bool {
        guard !entry.isLocked, !entry.isPending else { return false }
        if timer?.timeEntryID == entry.id { await stop() }
        generation += 1
        return await serial { [weak self] in
            guard let self, let api = self.api else { return false }
            do {
                try await api.deleteTimeEntry(id: entry.id)
                self.entries.removeAll { $0.id == entry.id }
                return true
            } catch {
                self.handle(error)
                return false
            }
        }
    }

    // MARK: - Week navigation

    public func showWeek(offset: Int) {
        let anchor = (weekDays.first ?? today).adding(days: offset * 7)
        weekDays = Week.days(containing: anchor, firstWeekday: firstWeekday)
        selectedDay = weekDays.contains(today) ? today : (visibleWeekDays.first ?? weekDays.first!)
        Task { await refresh() }
    }

    public func showCurrentWeek() {
        weekDays = Week.days(containing: today, firstWeekday: firstWeekday)
        selectedDay = today
        Task { await refresh() }
    }

    // MARK: - Settings

    public func setWeeklyTarget(minutes: Int) {
        settings.weeklyTargetMinutes = minutes
        weeklyTargetMinutes = minutes
    }

    public func setIdleDetection(_ on: Bool) {
        settings.idleDetection = on
        idleDetection = on
    }

    public func setIdleMinutes(_ minutes: Int) {
        settings.idleMinutes = minutes
        idleMinutes = minutes
    }

    public func setShowWeekends(_ show: Bool) {
        settings.showWeekends = show
        showWeekends = show
    }

    public func setFirstWeekday(_ day: Int) {
        settings.firstWeekday = day
        firstWeekday = day
        weekDays = Week.days(containing: selectedDay, firstWeekday: day)
        Task { await refresh() }
    }

    // MARK: - Favourites

    public func isFavourite(_ service: Service) -> Bool {
        favourites.contains { $0.serviceID == service.id }
    }

    public func toggleFavourite(_ service: Service) {
        if isFavourite(service) { favourites.removeAll { $0.serviceID == service.id } }
        else { favourites.append(Favourite(service: service)) }
        saveFavourites()
    }

    public func removeFavourite(_ fav: Favourite) {
        favourites.removeAll { $0.serviceID == fav.serviceID }
        saveFavourites()
    }

    public func moveFavourite(_ fav: Favourite, by delta: Int) {
        guard let i = favourites.firstIndex(of: fav) else { return }
        let j = min(max(i + delta, 0), favourites.count - 1)
        guard i != j else { return }
        favourites.swapAt(i, j)
        saveFavourites()
    }

    /// Accepts the proposed service for a favourite whose budget closed.
    public func acceptReplacement(for fav: Favourite) {
        guard let new = replacements[fav.serviceID], let i = favourites.firstIndex(of: fav) else { return }
        if isFavourite(new) {
            favourites.remove(at: i) // The new budget is already a favourite: drop the old one.
        } else {
            favourites[i] = Favourite(service: new)
        }
        replacements[fav.serviceID] = nil
        if settings.lastService?.id == fav.serviceID { settings.lastService = new }
        saveFavourites()
    }

    /// The current copy of a stored service (fresh labels), or the stored service itself.
    /// A replacement for a closed budget needs the user's confirmation, so it is not used here.
    public func resolvedService(for service: Service) -> Service {
        services.first { $0.id == service.id } ?? service
    }

    /// Services of recent entries, newest first (for the picker).
    public var recentServices: [Service] {
        var seen = Set<String>()
        return entries.sorted { $0.day > $1.day }
            .map { resolvedService(for: $0.service) }
            .filter { !$0.id.isEmpty && seen.insert($0.id).inserted }
    }

    /// Client codes learned from Jira keys ("WT-558" on a Wingtip entry → "wt": "Wingtip Online Ltd").
    public var clientCodes: [String: String] {
        var codes: [String: String] = [:]
        for entry in entries {
            guard let key = entry.jira?.key, let dash = key.firstIndex(of: "-"), !entry.service.clientName.isEmpty else { continue }
            codes[key[..<dash].lowercased()] = entry.service.clientName
        }
        return codes
    }

    public func isMissing(_ fav: Favourite) -> Bool {
        !services.isEmpty && replacements[fav.serviceID] == nil && !services.contains { $0.id == fav.serviceID }
    }

    private func resolveFavourites() {
        var found: [String: Service] = [:]
        for fav in favourites {
            if case .replacement(let s) = FavouriteMatcher.resolve(fav, in: services) { found[fav.serviceID] = s }
        }
        replacements = found
    }

    private func saveFavourites() {
        settings.favourites = favourites
        resolveFavourites()
    }
}
