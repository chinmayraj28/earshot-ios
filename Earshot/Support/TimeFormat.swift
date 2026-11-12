import Foundation

/// Date formatting used across the app. Built on `FormatStyle`, so it follows
/// the person's locale and 12/24-hour setting.
enum TimeFormat {
    /// Compact time for conversation rows: "Now", "14:05", "Yesterday", "Monday", "3 Nov".
    static func short(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if abs(now.timeIntervalSince(date)) < 60 { return "Now" }
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                              to: calendar.startOfDay(for: now)).day, days < 7, days > 0 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return date.formatted(.dateTime.day().month(.abbreviated))
        }
        return date.formatted(date: .numeric, time: .omitted)
    }

    /// Spoken form for VoiceOver: "29 minutes ago".
    static func spoken(_ date: Date, now: Date = .now) -> String {
        if abs(now.timeIntervalSince(date)) < 60 { return "just now" }
        return date.formatted(.relative(presentation: .named, unitsStyle: .wide))
    }

    /// Separator between groups of messages: "Today, 14:05", "Yesterday, 09:12", "Monday, 18:30", "3 Nov, 10:00".
    static func separator(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return "Today, \(time)" }
        if calendar.isDateInYesterday(date) { return "Yesterday, \(time)" }
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date),
                                              to: calendar.startOfDay(for: now)).day, days < 7, days > 0 {
            return "\(date.formatted(.dateTime.weekday(.wide))), \(time)"
        }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return "\(date.formatted(.dateTime.day().month(.wide))), \(time)"
        }
        return "\(date.formatted(.dateTime.day().month(.wide).year())), \(time)"
    }
}
