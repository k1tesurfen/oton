import Foundation

/// `settings.json`. Missing keys fall back to defaults; written by the app when the mic choice changes.
public struct Settings: Codable, Equatable, Sendable {
    /// Mic names, most recently chosen first. The first one that's connected (and usable) is recorded.
    public var preferredMics: [String] = []
    public var wolfgangPath: String = "/usr/local/bin/wolfgang"
    public var geminiURL: String = "https://gemini.google.com/app"

    public init() {}

    public init(from decoder: Decoder) throws {
        let d = Settings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        preferredMics = try c.decodeIfPresent([String].self, forKey: .preferredMics) ?? d.preferredMics
        wolfgangPath = try c.decodeIfPresent(String.self, forKey: .wolfgangPath) ?? d.wolfgangPath
        geminiURL = try c.decodeIfPresent(String.self, forKey: .geminiURL) ?? d.geminiURL
    }

    /// Missing file = defaults. A broken file throws (and is never overwritten by `load`).
    public static func load(from url: URL) throws -> Settings {
        guard FileManager.default.fileExists(atPath: url.path) else { return Settings() }
        return try JSONDecoder().decode(Settings.self, from: Data(contentsOf: url))
    }

    public func save(to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(self).write(to: url, options: .atomic)
    }
}

public enum Fmt {
    static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }

    /// "10:40"
    public static func hhmm(_ d: Date) -> String { formatter("HH:mm").string(from: d) }

    /// "45m", "1h05m", "2h": whole minutes, at least 1m. Used in file names.
    public static func compact(_ s: TimeInterval) -> String {
        let m = max(1, Int((s / 60).rounded()))
        if m < 60 { return "\(m)m" }
        return m % 60 == 0 ? "\(m / 60)h" : String(format: "%dh%02dm", m / 60, m % 60)
    }

    /// "45 min", "1 h 5 min"
    public static func duration(_ t: TimeInterval) -> String {
        let m = Int((t / 60).rounded())
        if m < 60 { return "\(m) min" }
        return m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min"
    }

    /// Stopwatch for the menu bar: "4:07", "1:02:33".
    public static func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}
