import Foundation

/// A finished transcription in `~/Documents/oton/transcriptions/`.
public struct TranscriptInfo: Codable, Equatable, Sendable {
    public var number: Int          // 1 = newest
    public var name: String
    public var path: String
    public var start: Date
    public var end: Date

    public init(number: Int, name: String, path: String, start: Date, end: Date) {
        self.number = number; self.name = name; self.path = path; self.start = start; self.end = end
    }

    /// "10:40–11:25 (45m)"
    public var timeRange: String { "\(Fmt.hhmm(start))–\(Fmt.hhmm(end)) (\(Fmt.compact(end.timeIntervalSince(start))))" }

    /// "Thu 26.11. 10:40–11:25 (45m)"
    public var title: String { "\(Fmt.formatter("EEE dd.MM.").string(from: start)) \(timeRange)" }
}

/// Recordings and transcriptions share one base name: `26-11-26_1040-1125_45m_oton` + `.m4a` / `.txt`.
public struct Library: Sendable {
    public let paths: Paths
    public init(paths: Paths) { self.paths = paths }

    static let day = Fmt.formatter("yy-MM-dd")
    static let hm = Fmt.formatter("HHmm")
    static let parser = Fmt.formatter("yy-MM-dd HHmm")

    public static func baseName(start: Date, end: Date) -> String {
        "\(day.string(from: start))_\(hm.string(from: start))-\(hm.string(from: end))_\(Fmt.compact(end.timeIntervalSince(start)))_oton"
    }

    public func recordingURL(_ base: String) -> URL { paths.recordings.appendingPathComponent(base + ".m4a") }
    public func transcriptURL(_ base: String) -> URL { paths.transcriptions.appendingPathComponent(base + ".txt") }

    /// A base name not used by any recording, transcription or pending job yet (`…_oton-2` for a second one).
    public func newBase(start: Date, end: Date) -> String {
        let base = Self.baseName(start: start, end: end)
        let fm = FileManager.default
        var candidate = base
        var n = 2
        while fm.fileExists(atPath: recordingURL(candidate).path) || fm.fileExists(atPath: transcriptURL(candidate).path)
                || fm.fileExists(atPath: paths.work.appendingPathComponent(candidate).path) {
            candidate = "\(base)-\(n)"
            n += 1
        }
        return candidate
    }

    /// Parses `yy-MM-dd_HHmm-HHmm_…_oton[-n].txt` back into start and end.
    public static func parse(_ name: String) -> (Date, Date)? {
        let p = name.split(separator: "_")
        guard p.count >= 4, name.hasSuffix(".txt"), p[3].hasPrefix("oton") else { return nil }
        let times = p[1].split(separator: "-")
        guard times.count == 2, let s = parser.date(from: "\(p[0]) \(times[0])"),
              var e = parser.date(from: "\(p[0]) \(times[1])") else { return nil }
        if e < s { e = e.addingTimeInterval(86400) }   // across midnight
        return (s, e)
    }

    /// Newest first, numbered from 1.
    public func transcripts() -> [TranscriptInfo] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: paths.transcriptions.path)) ?? []
        let items: [(String, Date, Date)] = names.compactMap { name in Self.parse(name).map { (name, $0.0, $0.1) } }
        let sorted = items.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 > $1.0 }
        return sorted.enumerated().map { i, it in
            TranscriptInfo(number: i + 1, name: it.0, path: paths.transcriptions.appendingPathComponent(it.0).path, start: it.1, end: it.2)
        }
    }

    public func transcript(at path: String) -> TranscriptInfo? {
        let name = (path as NSString).lastPathComponent
        guard let (s, e) = Self.parse(name) else { return nil }
        return TranscriptInfo(number: 0, name: name, path: path, start: s, end: e)
    }
}

public enum Prompt {
    public static let defaultTemplate = """
    Du bekommst das Transkript eines Gesprächs vom {{date}}, {{time}}.
    Es wurde automatisch transkribiert und kann Fehler enthalten. Es gibt KEINE
    Sprecherzuordnung. Die Kopfzeilen des Transkripts (Date, Mic, Gaps, Note)
    sind technische Metadaten der Aufnahme, nicht Inhalt des Gesprächs:
    erwähne Mikrofon und Aufnahmetechnik nicht.

    Antworte auf Deutsch, in Markdown. Entscheide zuerst: Wurden im Gespräch
    konkrete Aufgaben vereinbart?

    **Falls ja:**
    ## Kurzfassung
    3–5 Sätze: Worum ging es, was ist das Ergebnis?
    ## Aufgaben
    - [ ] Aufgabe (bis: Datum, falls genannt)
    Nenne eine Person nur, wenn sie im Gesprochenen ausdrücklich als zuständig
    genannt wird; sonst keine Person. Nur Aufgaben, die wirklich vereinbart
    wurden. Nichts erfinden.
    ## Entscheidungen
    ## Offene Fragen

    **Falls nein** (reine Diskussion, Abstimmung, Ergebnis ohne To-dos):
    ## Zusammenfassung
    Ausführliche Zusammenfassung: Ausgangslage, besprochene Punkte und
    Argumente, erreichter Endstand / Ergebnis.
    ## Offene Fragen (falls vorhanden)

    Schreibe nicht dazu, welchen Modus du gewählt hast.

    --- Transkript ---
    {{transcript}}

    """

    /// Reads `prompt.md`, writing the default on first use (never overwritten afterwards).
    public static func template(paths: Paths) -> String {
        if let s = try? String(contentsOf: paths.prompt, encoding: .utf8) { return s }
        try? Data(defaultTemplate.utf8).write(to: paths.prompt)
        return defaultTemplate
    }

    public static func render(template: String, transcript: String, info: TranscriptInfo) -> String {
        var out = template.replacingOccurrences(of: "{{date}}", with: Fmt.formatter("dd.MM.yyyy").string(from: info.start))
        out = out.replacingOccurrences(of: "{{time}}", with: "\(Fmt.hhmm(info.start))–\(Fmt.hhmm(info.end)) Uhr")
        if out.contains("{{transcript}}") { return out.replacingOccurrences(of: "{{transcript}}", with: transcript) }
        return out + "\n\n" + transcript
    }
}
