import Foundation

/// A stretch of the recording file captured in one go on one mic. A new segment starts whenever the mic is
/// (re)opened: at start, after a mic switch or disconnect, after sleep.
public struct Segment: Codable, Equatable, Sendable {
    public var outStart: TimeInterval      // seconds into the audio file
    public var wallStart: Date
    public var mic: String
    /// Why audio is missing right before this segment ("sleep", "mic disconnected", …), if it is.
    public var gapReason: String?
    public var duration: TimeInterval?     // known once the recording is finished

    public init(outStart: TimeInterval, wallStart: Date, mic: String, gapReason: String? = nil, duration: TimeInterval? = nil) {
        self.outStart = outStart
        self.wallStart = wallStart
        self.mic = mic
        self.gapReason = gapReason
        self.duration = duration
    }

    public var wallEnd: Date { wallStart.addingTimeInterval(duration ?? 0) }
}

/// A recording in progress, `active/<id>.json` next to `active/<id>.caf`.
/// Rewritten whenever a segment starts, so a crash loses nothing.
public struct RecordingState: Codable, Equatable, Sendable {
    public var id: String
    public var start: Date
    public var segments: [Segment]

    public init(id: String, start: Date, segments: [Segment] = []) { self.id = id; self.start = start; self.segments = segments }

    public static func newID(_ now: Date = Date()) -> String { Fmt.formatter("yyyyMMdd-HHmmss").string(from: now) + "-" + String(UUID().uuidString.prefix(4)) }

    public func save(_ paths: Paths) throws {
        try Coding.encoder.encode(self).write(to: paths.activeState(id), options: .atomic)
    }

    /// Recordings left in `active/` (the app stopped before encoding them), except `excluding`.
    /// A CAF without its JSON still counts: its start is taken from the file.
    public static func leftovers(_ paths: Paths, excluding: String? = nil) -> [RecordingState] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: paths.active.path)) ?? []
        return names.filter { $0.hasSuffix(".caf") }.sorted().compactMap { name in
            let id = String(name.dropLast(4))
            guard id != excluding else { return nil }
            if let d = try? Data(contentsOf: paths.activeState(id)), let st = try? Coding.decoder.decode(RecordingState.self, from: d) { return st }
            let attrs = try? FileManager.default.attributesOfItem(atPath: paths.activeAudio(id).path)
            return RecordingState(id: id, start: (attrs?[.creationDate] as? Date) ?? Date())
        }
    }
}

/// One transcription, `work/<id>/job.json`; the id is the base name shared by the .m4a and the .txt.
public struct Job: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case queued, transcribing, failed }
    public var id: String
    public var start: Date
    public var end: Date
    public var recording: String           // path of the .m4a
    public var segments: [Segment]
    public var notes: [String]
    public var status: Status
    public var error: String?
    public var createdAt: Date
}

public enum OtonError: Error, CustomStringConvertible, Equatable {
    case tooShort
    case noSpeech
    case wolfgangMissing(String)
    case wolfgangFailed(String)

    public var description: String {
        switch self {
        case .tooShort: return "recording too short, discarded"
        case .noSpeech: return "no speech recognised"
        case .wolfgangMissing(let p): return "Wolfgang not found at \(p)"
        case .wolfgangFailed(let e): return "Wolfgang failed: \(e)"
        }
    }
}

enum Coding {
    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }
    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

public struct Transcriber: Sendable {
    public let paths: Paths
    public var settings: Settings

    public init(paths: Paths, settings: Settings) {
        self.paths = paths
        self.settings = settings
    }

    public func workDir(_ id: String) -> URL { paths.work.appendingPathComponent(id, isDirectory: true) }

    // MARK: stop → .m4a + job

    /// Turns the finished (or crash-interrupted) CAF in `active/` into `recordings/<base>.m4a` and a queued job.
    /// Recordings under a second are discarded (`OtonError.tooShort`).
    public func finalizeRecording(_ state: RecordingState, notes: [String] = []) throws -> Job {
        let fm = FileManager.default
        let audio = paths.activeAudio(state.id)
        let total = AudioFormat.duration(of: audio)
        guard total >= 1 else {
            discard(state)
            throw OtonError.tooShort
        }
        var segs = state.segments.isEmpty ? [Segment(outStart: 0, wallStart: state.start, mic: "?")] : state.segments
        for i in segs.indices {
            let next = i + 1 < segs.count ? segs[i + 1].outStart : total
            segs[i].duration = max(0, min(next, total) - segs[i].outStart)
        }
        segs.removeAll { ($0.duration ?? 0) < 0.05 }
        guard let first = segs.first, let last = segs.last else { discard(state); throw OtonError.tooShort }

        let lib = Library(paths: paths)
        let id = lib.newBase(start: first.wallStart, end: last.wallEnd)
        let dest = lib.recordingURL(id)
        try AudioFormat.encodeM4A(from: audio, to: dest)

        let job = Job(id: id, start: first.wallStart, end: last.wallEnd, recording: dest.path, segments: segs, notes: notes,
                      status: .queued, error: nil, createdAt: Date())
        try fm.createDirectory(at: workDir(id), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try save(job)
        discard(state)
        return job
    }

    public func discard(_ state: RecordingState) {
        try? FileManager.default.removeItem(at: paths.activeAudio(state.id))
        try? FileManager.default.removeItem(at: paths.activeState(state.id))
    }

    // MARK: jobs on disk

    public func save(_ job: Job) throws {
        try Coding.encoder.encode(job).write(to: workDir(job.id).appendingPathComponent("job.json"), options: .atomic)
    }

    public func load(_ id: String) -> Job? {
        guard let d = try? Data(contentsOf: workDir(id).appendingPathComponent("job.json")) else { return nil }
        return try? Coding.decoder.decode(Job.self, from: d)
    }

    /// Unfinished and failed jobs, oldest first.
    public func pending() -> [Job] {
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: paths.work.path)) ?? []
        return ids.sorted().compactMap(load)
    }

    // MARK: transcription

    /// Wolfgang → final transcript in `transcriptions/`. The work dir goes away on success and on "no speech";
    /// on any other error the job is kept as failed (retry with `ot retry`). The .m4a is always kept.
    public func run(_ jobIn: Job) throws -> URL {
        var job = jobIn
        do {
            job.status = .transcribing
            job.error = nil
            try save(job)
            let audio = workDir(job.id).appendingPathComponent("audio.m4a")
            if !FileManager.default.fileExists(atPath: audio.path) {
                let src = URL(fileURLWithPath: job.recording)
                do { try FileManager.default.linkItem(at: src, to: audio) } catch { try FileManager.default.copyItem(at: src, to: audio) }
            }
            let text = try runWolfgang(audio)
            let url = Library(paths: paths).transcriptURL(job.id)
            try Data(postProcess(wolfgangText: text, job: job).utf8).write(to: url, options: .atomic)
            try? FileManager.default.removeItem(at: workDir(job.id))
            return url
        } catch OtonError.noSpeech {
            try? FileManager.default.removeItem(at: workDir(job.id))
            throw OtonError.noSpeech
        } catch {
            job.status = .failed
            job.error = "\(error)"
            try? save(job)
            throw error
        }
    }

    /// `wolfgang --audio-format transcript --audio speech --timestamps --yes --json <file>`; Wolfgang has no
    /// output-dir flag and writes `wolfgang_output/` next to its input, hence the work dir.
    public func runWolfgang(_ audio: URL) throws -> String {
        guard FileManager.default.isExecutableFile(atPath: settings.wolfgangPath) else { throw OtonError.wolfgangMissing(settings.wolfgangPath) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: settings.wolfgangPath)
        p.arguments = ["--audio-format", "transcript", "--audio", "speech", "--timestamps", "--yes", "--json", audio.path]
        p.currentDirectoryURL = audio.deletingLastPathComponent()
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        // Read stderr concurrently so a chatty Wolfgang can't block on a full pipe.
        var errData = Data()
        let errDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); errDone.signal() }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        errDone.wait()
        p.waitUntilExit()

        let events = WolfgangEvents.parse(String(decoding: data, as: UTF8.self))
        guard let file = events.file else {
            let tail = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw OtonError.wolfgangFailed(tail.isEmpty ? "no result (exit \(p.terminationStatus))" : tail)
        }
        // Wolfgang reports "no speech" only as text ("Da hab ich niemanden reden hören.").
        if !file.ok, let e = file.error, e.contains("niemanden reden") { throw OtonError.noSpeech }
        guard file.ok, let output = file.outputs.first else { throw OtonError.wolfgangFailed(file.error ?? "unknown error") }
        let root = events.outputRoot.map { URL(fileURLWithPath: $0) } ?? audio.deletingLastPathComponent().appendingPathComponent("wolfgang_output")
        return try String(contentsOf: root.appendingPathComponent(output), encoding: .utf8)
    }
}

/// Wolfgang's `--json` output: one JSON object per line (`plan`, `file`, `done`).
public struct WolfgangEvents {
    public struct FileEvent { public var ok: Bool; public var error: String?; public var outputs: [String] }
    public var outputRoot: String?
    public var file: FileEvent?

    public static func parse(_ text: String) -> WolfgangEvents {
        var r = WolfgangEvents()
        for line in text.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any], let ev = obj["event"] as? String else { continue }
            switch ev {
            case "plan": r.outputRoot = obj["output_root"] as? String
            case "file": r.file = FileEvent(ok: obj["ok"] as? Bool ?? false, error: obj["error"] as? String, outputs: obj["outputs"] as? [String] ?? [])
            default: break
            }
        }
        return r
    }
}

// MARK: post-processing

/// A stretch without audio between two segments.
public struct Gap: Equatable, Sendable {
    public var from: Date
    public var to: Date
    public var reason: String
    public var marker: String { "[gap \(Fmt.hhmm(from))–\(Fmt.hhmm(to)), \(reason)]" }
}

public func gaps(in segments: [Segment]) -> [Gap] {
    zip(segments, segments.dropFirst()).compactMap { a, b in
        b.wallStart.timeIntervalSince(a.wallEnd) > 1.5 ? Gap(from: a.wallEnd, to: b.wallStart, reason: b.gapReason ?? "no audio") : nil
    }
}

/// Maps a file offset (what Wolfgang's [hh:mm:ss] means) to the wall clock, and the segment it's in.
public func wallClock(forOffset t: TimeInterval, segments: [Segment]) -> (Date, Int)? {
    guard !segments.isEmpty else { return nil }
    var idx = 0
    for (k, s) in segments.enumerated() where s.outStart <= t + 0.001 { idx = k }
    let s = segments[idx]
    return (s.wallStart.addingTimeInterval(min(max(0, t - s.outStart), s.duration ?? .infinity)), idx)
}

/// Parses "[01:02:03]" or "[02:03]" at the start of a line.
func parseLeadingTimestamp(_ line: Substring) -> (TimeInterval, Substring)? {
    guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return nil }
    let parts = line[line.index(after: line.startIndex)..<close].split(separator: ":").map { Double($0) }
    guard (2...3).contains(parts.count), parts.allSatisfy({ $0 != nil }) else { return nil }
    let v = parts.map { $0! }
    return (v.count == 3 ? v[0] * 3600 + v[1] * 60 + v[2] : v[0] * 60 + v[1], line[line.index(after: close)...])
}

/// Wolfgang's text (German header + relative [hh:mm:ss]) → our header, wall-clock [HH:mm], gap markers.
public func postProcess(wolfgangText: String, job: Job) -> String {
    let segs = job.segments
    var pending = gaps(in: segs)
    var body: [String] = []
    for raw in wolfgangText.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("Transkript von") { continue }
        guard let (t, rest) = parseLeadingTimestamp(Substring(line)), let (wall, idx) = wallClock(forOffset: t, segments: segs) else {
            if !(body.isEmpty && line.isEmpty) { body.append(line) }
            continue
        }
        while let g = pending.first, g.to <= segs[idx].wallStart.addingTimeInterval(0.5) {
            if body.last?.isEmpty == false { body.append("") }
            body.append(g.marker)
            body.append("")
            pending.removeFirst()
        }
        body.append("[\(Fmt.hhmm(wall))]\(rest)")
    }
    while body.last?.isEmpty == true { body.removeLast() }
    return transcriptHeader(job) + "\n\n" + (body.isEmpty ? "(no speech recognised)" : body.joined(separator: "\n")) + "\n"
}

public func transcriptHeader(_ job: Job) -> String {
    let audio = job.segments.reduce(0) { $0 + ($1.duration ?? 0) }
    var lines = ["oton transcript",
                 "Date: \(Fmt.formatter("yyyy-MM-dd").string(from: job.start)), \(Fmt.hhmm(job.start))–\(Fmt.hhmm(job.end)) (\(Fmt.duration(audio)))"]
    var mics: [String] = []
    for s in job.segments where !mics.contains(s.mic) { mics.append(s.mic) }
    if !mics.isEmpty { lines.append("Mic: " + mics.joined(separator: ", then ")) }
    let gs = gaps(in: job.segments)
    if !gs.isEmpty { lines.append("Gaps: " + gs.map { "\(Fmt.hhmm($0.from))–\(Fmt.hhmm($0.to)) (\($0.reason))" }.joined(separator: ", ")) }
    for n in job.notes { lines.append("Note: \(n)") }
    return lines.joined(separator: "\n")
}
