import Foundation

/// All on-disk locations.
/// - `~/Documents/oton/`: what I keep (recordings, transcriptions).
/// - `~/Library/Application Support/oton/`: app internals (settings, prompt, socket, the recording in progress, work dirs).
public struct Paths: Sendable {
    public let support: URL
    public let documents: URL

    public init(support: URL, documents: URL) {
        self.support = support
        self.documents = documents
    }

    /// `OTON_DEV_ROOT=/some/dir` moves everything below that folder (development: keeps ~/Documents clean).
    public static var standard: Paths {
        if let dev = ProcessInfo.processInfo.environment["OTON_DEV_ROOT"], !dev.isEmpty {
            let root = URL(fileURLWithPath: dev, isDirectory: true)
            return Paths(support: root.appendingPathComponent("support"), documents: root.appendingPathComponent("documents"))
        }
        let fm = FileManager.default
        return Paths(support: fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("oton", isDirectory: true),
                     documents: fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("oton", isDirectory: true))
    }

    public var recordings: URL { documents.appendingPathComponent("recordings", isDirectory: true) }
    public var transcriptions: URL { documents.appendingPathComponent("transcriptions", isDirectory: true) }

    /// Recordings in progress (or not yet encoded): a crash-safe `<id>.caf` plus `<id>.json`,
    /// turned into an .m4a in `recordings/` on stop.
    public var active: URL { support.appendingPathComponent("active", isDirectory: true) }
    public func activeAudio(_ id: String) -> URL { active.appendingPathComponent(id + ".caf") }
    public func activeState(_ id: String) -> URL { active.appendingPathComponent(id + ".json") }
    /// One folder per transcription job (Wolfgang writes its output next to its input).
    public var work: URL { support.appendingPathComponent("work", isDirectory: true) }
    public var settings: URL { support.appendingPathComponent("settings.json") }
    public var prompt: URL { support.appendingPathComponent("prompt.md") }
    public var socket: URL { support.appendingPathComponent("ot.sock") }
    public var lock: URL { support.appendingPathComponent("app.lock") }
    public var log: URL { support.appendingPathComponent("oton.log") }

    public func prepare() throws {
        let fm = FileManager.default
        for dir in [support, active, work] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        for dir in [documents, recordings, transcriptions] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        // Temporary audio never reaches the backup; the m4a in recordings/ does.
        for dir in [active, work] {
            var url = dir
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        }
    }
}
