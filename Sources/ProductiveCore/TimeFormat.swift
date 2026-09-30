import Foundation

public enum TimeFormat {
    /// 45 → "0:45", 125 → "2:05".
    public static func hm(_ minutes: Int) -> String {
        let m = max(0, minutes)
        return String(format: "%d:%02d", m / 60, m % 60)
    }

    /// 3725 → "1:02:05".
    public static func hms(seconds: Int) -> String {
        let s = max(0, seconds)
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    /// Parses user input into minutes.
    /// "1:30" → 90, "1.5" / "1,5" → 90, "2" → 120 (plain numbers are hours), "45m" → 45.
    public static func parseMinutes(_ input: String) -> Int? {
        let s = input.trimmingCharacters(in: .whitespaces).lowercased()
        guard !s.isEmpty else { return nil }
        if s.hasSuffix("m"), let m = Int(s.dropLast().trimmingCharacters(in: .whitespaces)), m >= 0 {
            return m
        }
        if s.contains(":") {
            let parts = s.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            let h = parts[0].isEmpty ? 0 : Int(parts[0])
            guard let h, let m = Int(parts[1]), h >= 0, (0..<60).contains(m) else { return nil }
            return h * 60 + m
        }
        let hs = s.hasSuffix("h") ? String(s.dropLast()) : s
        guard let hours = Double(hs.replacingOccurrences(of: ",", with: ".")), hours >= 0 else { return nil }
        return Int((hours * 60).rounded())
    }
}

public enum Week {
    /// The 7 days of the week that contains `day`. `firstWeekday`: 1 = Sunday, 2 = Monday.
    public static func days(containing day: Day, firstWeekday: Int, calendar: Calendar = .current) -> [Day] {
        var cal = calendar
        cal.firstWeekday = firstWeekday
        let date = day.date(calendar: cal)
        let weekday = cal.component(.weekday, from: date)
        let offset = (weekday - firstWeekday + 7) % 7
        let start = day.adding(days: -offset, calendar: cal)
        return (0..<7).map { start.adding(days: $0, calendar: cal) }
    }

    public static func totals(_ entries: [TimeEntry]) -> [Day: Int] {
        entries.reduce(into: [:]) { $0[$1.day, default: 0] += $1.minutes }
    }
}
