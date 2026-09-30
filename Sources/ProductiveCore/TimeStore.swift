import Foundation

public protocol TokenStoring: Sendable {
    func read() -> String?
    @discardableResult func write(_ token: String) -> Bool
}

extension KeychainStore: TokenStoring {}

/// A start or stop that could not reach Productive. Sent at the next successful refresh.
enum PendingAction: Equatable {
    /// Start a timer on `service`; `at` is the click time.
    case start(service: Service, at: Date)
    /// Stop timer `timerID`, and set its entry to `baseMinutes` + the minutes from `startedAt` to `at`.
    case stop(timerID: String, entryID: String, startedAt: Date, baseMinutes: Int, at: Date)
    /// A start and stop that both happened offline: add `minutes` to `service` on `day`.
    case log(service: Service, day: Day, minutes: Int)
}

/// The app state. The only object that calls `ProductiveAPI`.
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

    public init(settings: SettingsStore = SettingsStore(),
                tokenStore: TokenStoring = KeychainStore(),
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
        self.favourites = settings.favourites
        self.weekDays = Week.days(containing: Day(now), firstWeekday: settings.firstWeekday)
    }

    // MARK: - Derived values

    public var today: Day { Day(now) }
    public var isRunning: Bool { timer != nil }
    public var organizationID: String { settings.organizationID }
    public var storedToken: String { tokenStore.read() ?? "" }
    public var lastService: Service? { settings.lastService }

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

    public func total(on day: Day) -> Int { entries(on: day).reduce(0) { $0 + liveMinutes($1) } }
    public var weekTotal: Int { weekDays.reduce(0) { $0 + total(on: $1) } }
    public var isCurrentWeek: Bool { weekDays.contains(today) }

    /// The number in the menu bar.
    public var menuBarMinutes: Int {
        if let running = runningEntry { return liveMinutes(running) }
        guard let last = settings.lastService else { return 0 }
        return entries(on: today).filter { $0.service.id == last.id }.reduce(0) { $0 + $1.minutes }
    }

    // MARK: - Lifecycle

    public func bootstrap() {
        guard let token = tokenStore.read(), !token.isEmpty, !settings.organizationID.isEmpty else {
            phase = .setup
            return
        }
        api = makeAPI(ProductiveConfig(token: token, organizationID: settings.organizationID))
        person = settings.person
        phase = .ready
        startClocks()
        Task { await refresh() }
    }

    /// Checks the token, stores it, and loads data. Returns the person on success.
    @discardableResult
    public func connect(token: String, organizationID: String) async -> Person? {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let org = organizationID.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = makeAPI(ProductiveConfig(token: token, organizationID: org))
        do {
            let me = try await candidate.me()
            tokenStore.write(token)
            settings.organizationID = org
            settings.person = me
            api = candidate
            person = me
            phase = .ready
            lastError = nil
            startClocks()
            servicesLoadedAt = nil
            await refresh()
            return me
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
    }

    public func signOut() {
        tokenStore.write("")
        settings.person = nil
        api = nil
        person = nil
        timer = nil
        entries = []
        services = []
        pending = []
        phase = .setup
        stopClocks()
    }

    private func startClocks() {
        guard ticker == nil else { return }
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
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

    func tick() {
        let previousDay = today
        now = clock()
        if today != previousDay {
            // Midnight: move the week view to the new day when it showed the old day.
            if selectedDay == previousDay { selectedDay = today }
            if weekDays.contains(previousDay) { weekDays = Week.days(containing: today, firstWeekday: firstWeekday) }
        }
    }

    // MARK: - Refresh

    public func refresh() async {
        guard let api, let person, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        now = clock()
        do {
            try await flushPending()
            async let timers = api.recentTimers(personID: person.id)
            let entryList = try await loadEntries(api: api, personID: person.id)
            let running = try await timers.first(where: \.isRunning)
            entries = entryList
            setTimer(running)
            isOffline = false
            lastError = nil
            if servicesLoadedAt.map({ now.timeIntervalSince($0) > 6 * 3600 }) ?? true {
                await refreshServices()
            }
        } catch {
            handle(error)
        }
    }

    public func refreshServices() async {
        guard let api, let person else { return }
        do {
            services = try await api.trackableServices(personID: person.id).sorted {
                ($0.clientName, $0.projectName, $0.name) < ($1.clientName, $1.projectName, $1.name)
            }
            servicesLoadedAt = clock()
            resolveFavourites()
        } catch {
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
        if let newTimer, newTimer.id != timer?.id || timer == nil {
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
        guard let last = settings.lastService else { return false }
        await start(resolvedService(for: last))
        return true
    }

    /// Starts `service`. Continues `preferred` (or today's unlocked entry on the service) when possible.
    public func start(_ service: Service, continuing preferred: TimeEntry? = nil) async {
        guard let api, let person else { return }
        if isRunning { await stop() }
        now = clock()
        let startedAt = now
        let existing = (preferred.flatMap { $0.day == today && !$0.isLocked ? $0 : nil })
            ?? entries.first { $0.day == today && $0.service.id == service.id && !$0.isLocked }
        settings.lastService = service

        // Show the timer at once.
        let placeholder = existing ?? TimeEntry(id: "pending-entry", day: today, minutes: 0, note: "", service: service)
        timerBaseMinutes = placeholder.minutes
        timer = RunningTimer(id: "pending", startedAt: startedAt, timeEntryID: placeholder.id, entry: placeholder)

        do {
            let entry: TimeEntry
            if let existing {
                entry = existing
            } else {
                entry = try await api.createTimeEntry(personID: person.id, serviceID: service.id, day: today, minutes: 0, note: "")
                entries.append(entry)
            }
            var started = try await api.startTimer(timeEntryID: entry.id)
            if started.entry == nil { started.entry = entry }
            timerBaseMinutes = entry.minutes
            timer = started
            lastError = nil
        } catch ProductiveError.offline {
            isOffline = true
            pending.append(.start(service: service, at: startedAt))
        } catch {
            timer = nil
            handle(error)
        }
    }

    public func stop() async {
        guard let running = timer else { return }
        now = clock()
        let stoppedAt = now
        let base = timerBaseMinutes
        let finalMinutes = runningSeconds / 60

        // Show the stop at once.
        timer = nil
        if let i = entries.firstIndex(where: { $0.id == running.timeEntryID }) { entries[i].minutes = finalMinutes }

        if running.id == "pending" {
            // The start never reached Productive: replace it with one logged block.
            if let i = pending.lastIndex(where: { if case .start = $0 { return true }; return false }),
               case .start(let service, let at) = pending[i] {
                pending.remove(at: i)
                let minutes = Int(stoppedAt.timeIntervalSince(at)) / 60
                pending.append(.log(service: service, day: Day(at), minutes: minutes))
            }
            return
        }

        guard let api else { return }
        do {
            _ = try await api.stopTimer(id: running.id)
            await refresh()
        } catch ProductiveError.offline {
            isOffline = true
            pending.append(.stop(timerID: running.id, entryID: running.timeEntryID,
                                 startedAt: running.startedAt, baseMinutes: base, at: stoppedAt))
        } catch {
            setTimer(running)
            handle(error)
        }
    }

    private func flushPending() async throws {
        guard let api, let person else { return }
        while let action = pending.first {
            switch action {
            case .start(let service, let at):
                let gap = max(0, Int(clock().timeIntervalSince(at)) / 60)
                let day = Day(at)
                let entry: TimeEntry
                if let existing = entries.first(where: { $0.day == day && $0.service.id == service.id && !$0.isLocked }) {
                    entry = try await api.updateTimeEntry(id: existing.id, minutes: existing.minutes + gap, note: nil)
                } else {
                    entry = try await api.createTimeEntry(personID: person.id, serviceID: service.id, day: day, minutes: gap, note: "")
                }
                _ = try await api.startTimer(timeEntryID: entry.id)
            case .stop(let timerID, let entryID, let startedAt, let base, let at):
                do { _ = try await api.stopTimer(id: timerID) }
                catch let e as ProductiveError where e.isNetwork { throw e }
                catch { /* The timer was already stopped somewhere else. */ }
                let minutes = base + max(0, Int(at.timeIntervalSince(startedAt)) / 60)
                _ = try await api.updateTimeEntry(id: entryID, minutes: minutes, note: nil)
            case .log(let service, let day, let minutes):
                if let existing = entries.first(where: { $0.day == day && $0.service.id == service.id && !$0.isLocked }) {
                    _ = try await api.updateTimeEntry(id: existing.id, minutes: existing.minutes + minutes, note: nil)
                } else {
                    _ = try await api.createTimeEntry(personID: person.id, serviceID: service.id, day: day, minutes: minutes, note: "")
                }
            }
            pending.removeFirst()
        }
    }

    // MARK: - Entries

    public func addEntry(service: Service, day: Day, minutes: Int, note: String) async -> Bool {
        guard let api, let person else { return false }
        do {
            let entry = try await api.createTimeEntry(personID: person.id, serviceID: service.id, day: day, minutes: minutes, note: note)
            entries.append(entry)
            return true
        } catch {
            handle(error)
            return false
        }
    }

    /// `minutes` is ignored for the running entry: the timer owns its time.
    public func updateEntry(_ entry: TimeEntry, minutes: Int?, note: String?) async -> Bool {
        guard let api, !entry.isLocked else { return false }
        let isRunningEntry = timer?.timeEntryID == entry.id
        do {
            let updated = try await api.updateTimeEntry(id: entry.id, minutes: isRunningEntry ? nil : minutes, note: note)
            if let i = entries.firstIndex(where: { $0.id == entry.id }) { entries[i] = updated }
            return true
        } catch {
            handle(error)
            return false
        }
    }

    public func deleteEntry(_ entry: TimeEntry) async -> Bool {
        guard let api, !entry.isLocked else { return false }
        if timer?.timeEntryID == entry.id { await stop() }
        do {
            try await api.deleteTimeEntry(id: entry.id)
            entries.removeAll { $0.id == entry.id }
            return true
        } catch {
            handle(error)
            return false
        }
    }

    // MARK: - Week navigation

    public func showWeek(offset: Int) {
        let anchor = (weekDays.first ?? today).adding(days: offset * 7)
        weekDays = Week.days(containing: anchor, firstWeekday: firstWeekday)
        selectedDay = weekDays.contains(today) ? today : weekDays.first!
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

    public func setFirstWeekday(_ day: Int) {
        settings.firstWeekday = day
        firstWeekday = day
        weekDays = Week.days(containing: selectedDay, firstWeekday: day)
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
        favourites[i] = Favourite(service: new)
        replacements[fav.serviceID] = nil
        if settings.lastService?.id == fav.serviceID { settings.lastService = new }
        saveFavourites()
    }

    /// The service to start for a stored service: itself, or the confirmed replacement.
    public func resolvedService(for service: Service) -> Service {
        services.first { $0.id == service.id } ?? service
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
