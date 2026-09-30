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
