import Foundation
import Testing
@testable import OtonCore

func at(_ h: Int, _ m: Int, _ s: Int = 0, day: Int = 26) -> Date {
    Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: day, hour: h, minute: m, second: s))!
}

func tempPaths() throws -> Paths {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("oton-test-\(UUID().uuidString)")
    let p = Paths(support: root.appendingPathComponent("support"), home: root.appendingPathComponent("docs"))
    try p.prepare()
    return p
}

func cleanup(_ p: Paths) { try? FileManager.default.removeItem(at: p.support.deletingLastPathComponent()) }

@Suite struct LibraryTests {
    @Test func names() {
        #expect(Library.baseName(start: at(10, 40), end: at(11, 25)) == "26-11-26_1040-1125_45m_oton")
        #expect(Library.baseName(start: at(9, 0), end: at(10, 5)) == "26-11-26_0900-1005_1h05m_oton")
        #expect(Library.baseName(start: at(9, 0), end: at(9, 0, 20)) == "26-11-26_0900-0900_1m_oton")
        let (s, e) = Library.parse("26-11-26_2340-0010_30m_oton-2.txt")!
        #expect(s == at(23, 40))
        #expect(e == at(0, 10, day: 27))
        #expect(Library.parse("26-11-25_0940-1025_45m_continuum.txt") == nil)
    }

    @Test func uniqueBaseAndNewestFirst() throws {
        let p = try tempPaths()
        defer { cleanup(p) }
        let lib = Library(paths: p)
        let a = lib.newBase(start: at(10, 0), end: at(10, 30))
        try Data().write(to: lib.recordingURL(a))
        let b = lib.newBase(start: at(10, 0), end: at(10, 30))
        #expect(b == a + "-2")
        try Data("x".utf8).write(to: lib.transcriptURL(a))
        try Data("y".utf8).write(to: lib.transcriptURL(lib.newBase(start: at(14, 0), end: at(14, 10))))
        #expect(lib.transcripts().map(\.name) == ["26-11-26_1400-1410_10m_oton.txt", "26-11-26_1000-1030_30m_oton.txt"])
        #expect(lib.transcripts().first?.title == "Thu 26.11. 14:00–14:10 (10m)")
    }

    @Test func prompt() {
        let info = TranscriptInfo(number: 1, name: "x", path: "/x", start: at(10, 40), end: at(11, 25))
        let out = Prompt.render(template: "Gespräch vom {{date}}, {{time}}.\n{{transcript}}", transcript: "[10:40] Hallo", info: info)
        #expect(out == "Gespräch vom 26.11.2026, 10:40–11:25 Uhr.\n[10:40] Hallo")
        #expect(Prompt.render(template: "Prompt", transcript: "T", info: info) == "Prompt\n\nT")
    }

    @Test func clock() {
        #expect(Fmt.clock(247) == "4:07")
        #expect(Fmt.clock(3753) == "1:02:33")
    }
}

@Suite struct PathsTests {
    @Test func homeIsItsOwnFolder() {
        let p = Paths.standard
        if ProcessInfo.processInfo.environment["OTON_DEV_ROOT"] == nil {
            #expect(p.home == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("oton", isDirectory: true))
        }
        #expect(p.recordings.lastPathComponent == "recordings")
        #expect(!p.recordings.path.contains("/Documents/"))
    }
}

@Suite struct MigrationTests {
    func file(_ url: URL, _ text: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    @Test func movesWholeFolderWhenNewOneIsMissing() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oton-mig-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("Documents/oton")
        let p = Paths(support: root.appendingPathComponent("support"), home: root.appendingPathComponent("oton"))
        try file(old.appendingPathComponent("recordings/a.m4a"), "A")
        #expect(Paths.migrateFromDocuments(to: p, old: old)?.hasPrefix("moved ") == true)
        #expect(try String(contentsOf: p.recordings.appendingPathComponent("a.m4a"), encoding: .utf8) == "A")
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(Paths.migrateFromDocuments(to: p, old: old) == nil)   // nothing left to do
    }

    @Test func mergesWithoutOverwritingOrDeleting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("oton-mig-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let old = root.appendingPathComponent("Documents/oton")
        let p = Paths(support: root.appendingPathComponent("support"), home: root.appendingPathComponent("oton"))
        try file(old.appendingPathComponent("recordings/a.m4a"), "old A")
        try file(old.appendingPathComponent("transcriptions/b.txt"), "B")
        try file(p.recordings.appendingPathComponent("a.m4a"), "new A")
        #expect(Paths.migrateFromDocuments(to: p, old: old) == "moved 1 file(s) from \(old.path) to \(p.home.path)")
        #expect(try String(contentsOf: p.recordings.appendingPathComponent("a.m4a"), encoding: .utf8) == "new A")   // not overwritten
        #expect(try String(contentsOf: p.transcriptions.appendingPathComponent("b.txt"), encoding: .utf8) == "B")
        #expect(try String(contentsOf: old.appendingPathComponent("recordings/a.m4a"), encoding: .utf8) == "old A")   // clash stays put
        #expect(!FileManager.default.fileExists(atPath: old.appendingPathComponent("transcriptions").path))     // emptied → removed
    }
}
