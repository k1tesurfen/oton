import Foundation

public enum MicKind: String, Codable, Sendable {
    case builtIn = "built-in", usb, bluetooth, virtual, aggregate, continuity, other
}

/// An input device as far as the choice is concerned (the app fills it from CoreAudio).
public struct Mic: Equatable, Sendable {
    public var name: String
    public var uid: String
    public var kind: MicKind

    public init(name: String, uid: String, kind: MicKind) {
        self.name = name
        self.uid = uid
        self.kind = kind
    }
}

func sameName(_ a: String, _ b: String) -> Bool { a.caseInsensitiveCompare(b) == .orderedSame }

/// Which mic to record:
/// 1. the most recently chosen mic that's connected (any kind: choosing it is explicit),
/// 2. otherwise any USB mic,
/// 3. otherwise the built-in mic.
/// The built-in mic is never used with the lid closed: it stays listed but records digital silence.
/// Bluetooth and virtual devices are only used when chosen explicitly.
/// Names, not UIDs: a USB device's UID changes with the port.
public func pickMic(_ mics: [Mic], preferred: [String], lidClosed: Bool) -> Mic? {
    func usable(_ m: Mic) -> Bool { !(m.kind == .builtIn && lidClosed) }
    for name in preferred {
        if let m = mics.first(where: { sameName($0.name, name) }), usable(m) { return m }
    }
    if let m = mics.first(where: { $0.kind == .usb }) { return m }
    if !lidClosed, let m = mics.first(where: { $0.kind == .builtIn }) { return m }
    return nil
}

/// Moves `name` to the front of the preference list.
public func remember(_ name: String, in list: [String], keep: Int = 10) -> [String] {
    Array(([name] + list.filter { !sameName($0, name) }).prefix(keep))
}

public enum MicMatch: Equatable, Sendable {
    case found(String)
    case none
    case ambiguous([String])
}

/// Resolves what was typed after `ot mic`: a number from `ot mic` (1-based), an exact name, or a unique substring.
public func matchMic(_ query: String, in names: [String]) -> MicMatch {
    let q = query.trimmingCharacters(in: .whitespaces)
    if let n = Int(q) { return n >= 1 && n <= names.count ? .found(names[n - 1]) : .none }
    if let exact = names.first(where: { sameName($0, q) }) { return .found(exact) }
    let hits = names.filter { $0.range(of: q, options: .caseInsensitive) != nil }
    switch hits.count {
    case 0: return .none
    case 1: return .found(hits[0])
    default: return .ambiguous(hits)
    }
}
