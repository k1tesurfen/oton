import Foundation
import IOKit
import IOKit.pwr_mgt
import OtonCore

func log(_ msg: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(msg)\n"
    FileHandle.standardError.write(Data(line.utf8))
    let url = Paths.standard.log
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
    } else {
        try? Data(line.utf8).write(to: url)
    }
}

enum Lid {
    /// `AppleClamshellState` from IOPMrootDomain. Closed lid = the built-in mic records digital silence.
    static func isClosed() -> Bool {
        let root = IORegistryEntryFromPath(kIOMainPortDefault, "IOPower:/IOPowerConnection/IOPMrootDomain")
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        let v = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        return (v as? Bool) ?? false
    }
}

/// "oton: recording", visible in `pmset -g assertions`. Held only while recording.
final class SleepAssertion {
    private var id: IOPMAssertionID = 0
    private(set) var held = false

    func set(_ on: Bool) {
        if on && !held {
            held = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                               IOPMAssertionLevel(kIOPMAssertionLevelOn), "oton: recording" as CFString, &id) == kIOReturnSuccess
        } else if !on && held {
            IOPMAssertionRelease(id)
            held = false
        }
    }
}

func runProcess(_ path: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}
