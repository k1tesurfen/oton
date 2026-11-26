import Foundation

/// All on-disk locations.
/// - `~/oton/`: what I keep (recordings, transcriptions). Its own folder in the home directory: not Documents,
///   which may be synced to iCloud ("Desktop & Documents Folders") and is shown localized ("Dokumente").
/// - `~/Library/Application Support/oton/`: app internals (settings, prompt, socket, the recording in progress, work dirs).
public struct Paths: Sendable {
    public let support: URL
    public let home: URL

    public init(support: URL, home: URL) {
        self.support = support
        self.home = home
    }

    /// `OTON_DEV_ROOT=/some/dir` moves everything below that folder (development: keeps ~/oton clean).
    public static var standard: Paths {
        if let dev = ProcessInfo.processInfo.environment["OTON_DEV_ROOT"], !dev.isEmpty {
            let root = URL(fileURLWithPath: dev, isDirectory: true)
            return Paths(support: root.appendingPathComponent("support"), home: root.appendingPathComponent("home"))
        }
        let fm = FileManager.default
        return Paths(support: fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("oton", isDirectory: true),
                     home: fm.homeDirectoryForCurrentUser.appendingPathComponent("oton", isDirectory: true))
    }

    public var recordings: URL { home.appendingPathComponent("recordings", isDirectory: true) }
    public var transcriptions: URL { home.appendingPathComponent("transcriptions", isDirectory: true) }

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

    /// oton 0.2.0 kept recordings and transcriptions in ~/Documents/oton: move them once to ~/oton.
    /// Returns what happened, for the log.
    public static func migrateFromDocuments(to paths: Paths, old: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                                                .appendingPathComponent("oton", isDirectory: true)) -> String? {
        let fm = FileManager.default
        guard paths.home != old, fm.fileExists(atPath: old.path) else { return nil }
        do {
            if !fm.fileExists(atPath: paths.home.path) {
                try fm.moveItem(at: old, to: paths.home)
                return "moved \(old.path) to \(paths.home.path)"
            }
            // Both exist: move file by file, never overwrite.
            var moved = 0
            for sub in ["recordings", "transcriptions"] {
                let from = old.appendingPathComponent(sub), to = paths.home.appendingPathComponent(sub)
                try fm.createDirectory(at: to, withIntermediateDirectories: true)
                for name in (try? fm.contentsOfDirectory(atPath: from.path)) ?? [] where !fm.fileExists(atPath: to.appendingPathComponent(name).path) {
                    try fm.moveItem(at: from.appendingPathComponent(name), to: to.appendingPathComponent(name))
                    moved += 1
                }
            }
            // Clean up only what's empty now (rmdir never deletes contents).
            for sub in ["recordings", "transcriptions", ""] {
                let dir = old.appendingPathComponent(sub)
                try? fm.removeItem(at: dir.appendingPathComponent(".DS_Store"))
                rmdir(dir.path)
            }
            return "moved \(moved) file(s) from \(old.path) to \(paths.home.path)"
        } catch {
            return "could not move \(old.path): \(error)"
        }
    }

    public func prepare() throws {
        let fm = FileManager.default
        for dir in [support, active, work] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        for dir in [home, recordings, transcriptions] {
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
