import Foundation

enum JSON {
    /// Reads the first key present in the dict (case-insensitive fallbacks
    /// mirror the Dart client, which tolerates both snake_case and PascalCase).
    private static func any(_ json: [String: Any], _ keys: [String]) -> Any? {
        for key in keys {
            if let value = json[key] { return value }
        }
        return nil
    }

    static func str(_ json: [String: Any], _ keys: String...) -> String? {
        guard let value = any(json, keys) else { return nil }
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }

    static func int(_ json: [String: Any], _ keys: String...) -> Int {
        guard let value = any(json, keys) else { return 0 }
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s) ?? 0 }
        return 0
    }

    static func intOrNull(_ json: [String: Any], _ keys: String...) -> Int? {
        guard let value = any(json, keys), !(value is NSNull) else { return nil }
        if let n = value as? NSNumber { return n.intValue }
        if let s = value as? String { return Int(s) }
        return nil
    }

    static func double(_ json: [String: Any], _ keys: String..., fallback: Double = 0) -> Double {
        guard let value = any(json, keys) else { return fallback }
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) ?? fallback }
        return fallback
    }

    static func bool(_ json: [String: Any], _ keys: String...) -> Bool {
        guard let value = any(json, keys) else { return false }
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n.boolValue }
        if let s = value as? String { return s == "true" || s == "1" }
        return false
    }

    static func array(_ json: [String: Any], _ keys: String...) -> [[String: Any]] {
        guard let value = any(json, keys), !(value is NSNull) else { return [] }
        if let arr = value as? [[String: Any]] { return arr }
        if let arr = value as? [Any] {
            return arr.compactMap { $0 as? [String: Any] }
        }
        return []
    }

    static func dict(_ json: [String: Any], _ keys: String...) -> [String: Any]? {
        guard let value = any(json, keys) else { return nil }
        return value as? [String: Any]
    }

    /// Server categories arrive as either a comma-joined string or a
    /// {order: name} map; normalize to a display string.
    static func categories(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        if let s = value as? String {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let dict = value as? [String: Any] {
            let names = dict.values.map { "\($0)" }.filter { !$0.isEmpty }
            return names.isEmpty ? nil : names.joined(separator: ", ")
        }
        if let dict = value as? [Int: String] {
            let names = dict.values.filter { !$0.isEmpty }
            return names.isEmpty ? nil : names.joined(separator: ", ")
        }
        return nil
    }
}

enum Formatters {
    static func duration(seconds: Int) -> String {
        guard seconds > 0 else { return "0:00" }
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }

    /// "1h 12m", "45m", "<1m" — for remaining-time labels.
    static func compactDuration(seconds: Int) -> String {
        let seconds = max(seconds, 0)
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
        if minutes > 0 { return "\(minutes)m" }
        return seconds > 0 ? "<1m" : "0m"
    }

    /// Relative wording for the past week, then an absolute date.
    static func relativeDate(_ raw: String) -> String {
        guard let date = parseDate(raw) else { return raw }
        let calendar = Calendar.current
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: .now)).day ?? 0
        if days <= 0 { return "Today" }
        if days == 1 { return "Yesterday" }
        if days < 7 { return "\(days) days ago" }
        if calendar.isDate(date, equalTo: .now, toGranularity: .year) {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }

    static func parseDate(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let formats = [
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd",
        ]
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        for format in formats {
            parser.dateFormat = format
            if let date = parser.date(from: trimmed) { return date }
        }
        return ISO8601DateFormatter().date(from: trimmed)
    }
}
