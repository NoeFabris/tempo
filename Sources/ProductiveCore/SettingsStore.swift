import Foundation
import Security

/// Stores the API token in the macOS Keychain. The token never goes to disk in plain text.
public struct KeychainStore: Sendable {
    public let service: String
    public let account: String

    public init(service: String = "app.tempo.menubar", account: String = "productive-api-token") {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    public func read() -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public func write(_ token: String) -> Bool {
        SecItemDelete(query as CFDictionary)
        guard !token.isEmpty else { return true }
        var q = query
        q[kSecValueData as String] = Data(token.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }
}

/// Stores the API token in a file that only the user can read (folder 0700, file 0600):
/// ~/Library/Application Support/Tempo/token. Chosen over the Keychain because locally built,
/// unsigned versions made macOS ask for the password after every build.
/// The first read moves a token that an older version saved in the Keychain.
public struct FileTokenStore: TokenStoring {
    public let url: URL
    private let legacy: KeychainStore?

    public init(directory: URL? = nil, migrateFrom legacy: KeychainStore? = KeychainStore()) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tempo", isDirectory: true)
        url = base.appendingPathComponent("token")
        self.legacy = legacy
    }

    public func read() -> String? {
        if let data = try? Data(contentsOf: url), let token = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            return token
        }
        // One-time move from the Keychain (older versions).
        guard let legacy, let token = legacy.read(), !token.isEmpty, write(token) else { return nil }
        legacy.write("")
        return token
    }

    @discardableResult
    public func write(_ token: String) -> Bool {
        let fm = FileManager.default
        guard !token.isEmpty else {
            try? fm.removeItem(at: url)
            return true
        }
        do {
            let dir = url.deletingLastPathComponent()
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            // Create with 0600 before the token is written, so it is never readable by others.
            if !fm.fileExists(atPath: url.path) {
                guard fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { return false }
            }
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: Data(token.utf8))
            return true
        } catch {
            return false
        }
    }
}

/// Non-secret settings, kept in UserDefaults.
public final class SettingsStore: @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private enum Key {
        static let organizationID = "organizationID"
        static let person = "person"
        static let weeklyTarget = "weeklyTargetMinutes"
        static let firstWeekday = "firstWeekday"
        static let favourites = "favourites"
        static let lastService = "lastService"
        static let lastEntry = "lastEntry"
        static let calendarLinks = "calendarLinks"
        static let showWeekends = "showWeekends"
        static let idleDetection = "idleDetection"
        static let idleMinutes = "idleMinutes"
        static let meetingServices = "meetingServices"
    }

    public var organizationID: String {
        get { defaults.string(forKey: Key.organizationID) ?? "" }
        set { defaults.set(newValue, forKey: Key.organizationID) }
    }

    public var person: Person? {
        get { decode(Key.person) }
        set { encode(newValue, Key.person) }
    }

    /// Default 37:30.
    public var weeklyTargetMinutes: Int {
        get { defaults.object(forKey: Key.weeklyTarget) as? Int ?? 37 * 60 + 30 }
        set { defaults.set(newValue, forKey: Key.weeklyTarget) }
    }

    /// 1 = Sunday, 2 = Monday (default).
    public var firstWeekday: Int {
        get { defaults.object(forKey: Key.firstWeekday) as? Int ?? 2 }
        set { defaults.set(newValue, forKey: Key.firstWeekday) }
    }

    public var favourites: [Favourite] {
        get { decode(Key.favourites) ?? [] }
        set { encode(newValue, Key.favourites) }
    }

    public var lastService: Service? {
        get { decode(Key.lastService) }
        set { encode(newValue, Key.lastService) }
    }

    public var lastEntry: LastEntry? {
        get { decode(Key.lastEntry) }
        set { encode(newValue, Key.lastEntry) }
    }

    /// Show Saturday and Sunday in the week strip. Default off.
    public var showWeekends: Bool {
        get { defaults.bool(forKey: Key.showWeekends) }
        set { defaults.set(newValue, forKey: Key.showWeekends) }
    }

    /// Ask what to do with idle time while a timer runs. Default on.
    public var idleDetection: Bool {
        get { defaults.object(forKey: Key.idleDetection) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.idleDetection) }
    }

    /// Minutes without keyboard or mouse use before the time counts as idle. Default 5.
    public var idleMinutes: Int {
        get { defaults.object(forKey: Key.idleMinutes) as? Int ?? 5 }
        set { defaults.set(newValue, forKey: Key.idleMinutes) }
    }

    /// Calendar event id → the id of the entry that logged it.
    public var calendarLinks: [String: String] {
        get { decode(Key.calendarLinks) ?? [:] }
        set { encode(newValue, Key.calendarLinks) }
    }

    /// Meeting series (or name) → the service used the last time.
    public var meetingServices: [String: Service] {
        get { decode(Key.meetingServices) ?? [:] }
        set { encode(newValue, Key.meetingServices) }
    }

    private func decode<T: Decodable>(_ key: String) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private func encode<T: Encodable>(_ value: T?, _ key: String) {
        if let value, let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
        else { defaults.removeObject(forKey: key) }
    }
}
