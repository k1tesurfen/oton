import Foundation
import OtonCore

let usage = """
ot – control oton (menu-bar recorder → Wolfgang transcript → Gemini)

  ot [status]               recording? which mic? anything transcribing?
  ot start                  start recording on the preferred mic
  ot stop                   stop; transcribes, notification with "Copy for Gemini" when ready
  ot toggle                 start or stop
  ot copy                   latest transcription + Gemini prompt → clipboard
  ot copy <n> [--prompt]    transcription n from `ot list`, plain unless --prompt
       [--open]             also open Gemini in the browser
  ot list                   transcriptions, newest first
  ot mic                    inputs, and which one is recorded
  ot mic <n|name>           prefer this mic (remembered; switches a running recording)
  ot retry [id]             re-run a failed transcription
  ot reveal [recordings]    open the transcriptions (or recordings) folder
  ot update                 install a newer release from GitHub (oton restarts)
  ot launch                 start the app after a Quit
  ot reload                 re-read settings.json

  --json  machine-readable output (one JSON line per event)
"""

var args = Array(CommandLine.arguments.dropFirst())
func flag(_ name: String) -> Bool {
    if let i = args.firstIndex(of: name) { args.remove(at: i); return true }
    return false
}

let json = flag("--json")
let socketPath = Paths.standard.socket.path

func fail(_ msg: String, code: Int32 = 1) -> Never {
    if json { FileHandle.standardOutput.write(Wire.encode(Response.failure(msg))) } else { FileHandle.standardError.write(Data("ot: \(msg)\n".utf8)) }
    exit(code)
}

func isRunning() -> Bool { (try? SocketClient.send(Request(cmd: "status"), path: socketPath, onResponse: { _ in })) != nil }

/// Opens oton.app (found by bundle id, wherever it's installed) and waits until it answers.
func launch() -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = ["-g", "-b", "local.oton"]
    p.standardError = FileHandle.nullDevice
    try? p.run()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { fail("oton.app not found; install it from https://github.com/k1tesurfen/oton", code: 2) }
    for _ in 0..<40 {
        if isRunning() { return true }
        usleep(250_000)
    }
    return false
}

/// Sends a request (launching the app first if needed); prints human text or raw JSON lines.
@discardableResult
func send(_ req: Request) -> Response {
    var final: Response?
    func attempt() throws {
        try SocketClient.send(req, path: socketPath) { r in
            if json { FileHandle.standardOutput.write(Wire.encode(r)) }
            else {
                let text = r.ok ? r.message : "error: \(r.error ?? r.message)" + (r.hint.map { "\nhint: \($0)" } ?? "")
                (r.ok ? FileHandle.standardOutput : FileHandle.standardError).write(Data((text + "\n").utf8))
            }
            if r.final { final = r }
        }
    }
    do {
        do { try attempt() } catch SocketError.notRunning {
            guard launch() else { fail("oton doesn't answer; check ~/Library/Application Support/oton/oton.log", code: 2) }
            try attempt()
        }
    } catch {
        fail("\(error)")
    }
    guard let r = final else { fail("no answer") }
    if !r.ok { exit(1) }
    return r
}

/// Like `send`, but silent and without launching: for Alfred's live list.
func query(_ req: Request) -> Response? {
    var r: Response?
    try? SocketClient.send(req, path: socketPath) { r = $0 }
    return r
}

// MARK: Alfred (Script Filter JSON). The workflow calls `ot alfred "{query}"` and runs `ot <arg>` on ↩.

struct AlfredItem: Encodable {
    var title: String
    var subtitle: String
    var arg: String?
    var valid: Bool
    var autocomplete: String?
    var mods: [String: Mod]?
    struct Mod: Encodable { var arg: String; var subtitle: String; var valid = true }
}

func alfred(_ q: String) -> Never {
    var items: [AlfredItem] = []
    let words = q.split(separator: " ").map(String.init)
    let verb = words.first?.lowercased() ?? ""
    let rest = words.dropFirst().joined(separator: " ")

    guard let st = query(Request(cmd: "status")) else {
        items = [AlfredItem(title: "oton is not running", subtitle: "↩ start it", arg: "launch", valid: true)]
        FileHandle.standardOutput.write(Wire.encode(["items": items]))
        exit(0)
    }
    let recording = st.data?["recording"]?.bool ?? false
    let mic = st.data?["mic"]?.string ?? "no usable mic"
    let elapsed = Fmt.clock(st.data?["elapsed"]?.number ?? 0)
    let busy = (st.data?["transcribing"]?.number ?? 0) > 0
    let latest = st.data?["latest"]?.string

    let startItem = AlfredItem(title: "Start recording", subtitle: "on \(mic)", arg: "start", valid: !recording, autocomplete: "start")
    let stopItem = AlfredItem(title: recording ? "Stop recording (\(elapsed))" : "Not recording",
                              subtitle: recording ? "then transcribe with Wolfgang; notification when ready" : "ot start", arg: "stop", valid: recording, autocomplete: "stop")
    let copyItem = AlfredItem(title: busy ? "Still transcribing…" : "Copy latest for Gemini",
                              subtitle: busy ? "wait for the notification" : (latest.map { "\($0) · transcript + prompt · ⌘↩ also open Gemini" } ?? "no transcriptions yet"),
                              arg: "copy", valid: !busy && latest != nil, autocomplete: "copy",
                              mods: ["cmd": .init(arg: "copy --open", subtitle: "Copy and open Gemini")])

    func matches(_ word: String) -> Bool { !verb.isEmpty && word.hasPrefix(verb) }

    switch verb {
    case "start": items = [startItem]
    case "stop": items = [stopItem]
    case "copy", "c": items = [copyItem]
    case "list", "l":
        let filter = rest.lowercased()
        for t in query(Request(cmd: "list"))?.data?["transcripts"]?.array?.prefix(20) ?? [] {
            let n = Int(t["n"]?.number ?? 0)
            let title = t["title"]?.string ?? "?"
            if !filter.isEmpty && !title.lowercased().contains(filter) { continue }
            items.append(AlfredItem(title: title, subtitle: "↩ copy with prompt · ⌘↩ plain transcript", arg: "copy \(n) --prompt", valid: true,
                                    mods: ["cmd": .init(arg: "copy \(n)", subtitle: "Copy the plain transcript")]))
        }
        if items.isEmpty { items.append(AlfredItem(title: "No transcriptions yet", subtitle: "ot start, then ot stop", arg: nil, valid: false)) }
    case "mic", "m":
        for m in query(Request(cmd: "mic-list"))?.data?.array ?? [] {
            let n = Int(m["n"]?.number ?? 0)
            let current = m["current"]?.bool ?? false
            items.append(AlfredItem(title: (current ? "✓ " : "") + (m["name"]?.string ?? "?"), subtitle: "\(m["state"]?.string ?? "") · ↩ prefer this mic",
                                    arg: "mic \(n)", valid: true))
        }
    default:
        let head = st.message.split(separator: "\n").map(String.init)
        if verb.isEmpty {
            items.append(AlfredItem(title: head.first ?? "", subtitle: head.dropFirst().joined(separator: " · "), arg: nil, valid: false))
            items.append(recording ? stopItem : startItem)
            items.append(copyItem)
            items.append(AlfredItem(title: "Transcriptions", subtitle: "ot list", arg: nil, valid: false, autocomplete: "list "))
            items.append(AlfredItem(title: "Microphone: \(mic)", subtitle: "ot mic", arg: nil, valid: false, autocomplete: "mic "))
        } else {
            // Partial words: "st" offers start/stop, "co" copy, …
            if matches("start") && !recording { items.append(startItem) }
            if matches("stop") && recording { items.append(stopItem) }
            if matches("copy") { items.append(copyItem) }
            if matches("list") { items.append(AlfredItem(title: "Transcriptions", subtitle: "ot list", arg: nil, valid: false, autocomplete: "list ")) }
            if matches("mic") { items.append(AlfredItem(title: "Microphone: \(mic)", subtitle: "ot mic", arg: nil, valid: false, autocomplete: "mic ")) }
            if items.isEmpty { items.append(AlfredItem(title: "start · stop · copy · list · mic", subtitle: head.first ?? "", arg: nil, valid: false, autocomplete: "")) }
        }
    }
    FileHandle.standardOutput.write(Wire.encode(["items": items]))
    exit(0)
}

// MARK: dispatch

let cmd = args.isEmpty ? "status" : args.removeFirst()
switch cmd {
case "status", "start", "stop", "toggle", "list", "reload": send(Request(cmd: cmd))
case "copy":
    let prompt = flag("--prompt") ? true : nil
    let open = flag("--open")
    var n: Int?
    if let first = args.first { guard let v = Int(first), v >= 1 else { fail("copy takes a number from `ot list`") }; n = v }
    send(Request(cmd: "copy", n: n, prompt: prompt, open: open))
case "mic", "mics":
    if args.isEmpty || args == ["list"] { send(Request(cmd: "mic-list")) } else { send(Request(cmd: "mic-set", name: args.joined(separator: " "))) }
case "retry": send(Request(cmd: "retry", id: args.first))
case "update": send(Request(cmd: "update"))
case "reveal", "open": send(Request(cmd: "reveal", name: args.first))
case "launch":
    if isRunning() { print("oton is running.") } else if launch() { print("oton started.") } else { fail("started, but oton doesn't answer yet; see ~/Library/Application Support/oton/oton.log") }
case "alfred": alfred(args.joined(separator: " "))
case "help", "-h", "--help": print(usage)
default: fail("unknown command \(cmd); see ot help")
}
exit(0)
