import AppKit
import AVFoundation
import Foundation
import OtonCore

/// Owns all state, on the main thread. Encoding and Wolfgang run on background queues.
final class Controller {
    let paths = Paths.standard
    var settings = Settings()
    var settingsError: String?
    var transcriber: Transcriber { Transcriber(paths: paths, settings: settings) }

    // Recording
    var recorder: Recorder?
    var rec: RecordingState?                 // non-nil while recording
    var pendingGap: String?                  // why audio is missing before the next segment
    var waitingForMic = false                // recording, but no usable mic at the moment
    var lidClosed = Lid.isClosed()
    var lastReopen = Date.distantPast
    let assertion = SleepAssertion()

    // After recording
    let encodeQueue = DispatchQueue(label: "oton.encode")
    let transcribeQueue = DispatchQueue(label: "oton.transcribe")
    var encoding = 0                         // recordings being turned into .m4a
    var jobs: [String: Job] = [:]            // queued or transcribing
    var wolfgangOK = true

    var notifier: Notifier?
    var onStateChange: (() -> Void)?
    private var ticks = 0

    var isRecording: Bool { rec != nil }
    var isBusy: Bool { encoding > 0 || !jobs.isEmpty }
    var elapsed: TimeInterval { rec.map { Date().timeIntervalSince($0.start) } ?? 0 }

    // MARK: lifecycle

    func start() {
        if let msg = Paths.migrateFromDocuments(to: paths) { log(msg) }
        try? paths.prepare()
        loadSettings()
        _ = Prompt.template(paths: paths)
        checkWolfgang()
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }

        // Recordings the app couldn't finish (crash, power loss) are encoded and transcribed now.
        let leftovers = RecordingState.leftovers(paths)
        for st in leftovers {
            finalize(st, notes: ["recovered after oton stopped unexpectedly"])
        }
        if !leftovers.isEmpty { log("recovering \(leftovers.count) unfinished recording(s)") }
        for job in transcriber.pending() where job.status != .failed { enqueue(job) }

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.isRecording else { return }
            log("sleep while recording")
            self.recorder?.detach()
            self.pendingGap = "sleep"
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, self.isRecording else { return }
                self.switchMic(gap: self.pendingGap ?? "sleep")
            }
        }
        Devices.watch { [weak self] in self?.devicesChanged() }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        log("started")
    }

    func loadSettings() {
        do { settings = try Settings.load(from: paths.settings); settingsError = nil } catch {
            settings = Settings()
            settingsError = "settings.json is invalid, using defaults: \(error)"
            log(settingsError!)
        }
    }

    func checkWolfgang() {
        let path = settings.wolfgangPath
        DispatchQueue.global().async {
            let out = runProcess(path, ["transcription", "status"])
            let ok = FileManager.default.isExecutableFile(atPath: path) && !out.isEmpty && !out.lowercased().contains("nicht")
            DispatchQueue.main.async { self.wolfgangOK = ok; if !ok { log("Wolfgang or its transcription add-on is missing") } }
        }
    }

    func tick() {
        ticks += 1
        guard isRecording else { return }
        if ticks % 2 == 0 {
            let closed = Lid.isClosed()
            if closed != lidClosed {
                lidClosed = closed
                // Closing the lid silences the built-in mic: move to another one.
                if closed, recorder?.device?.isBuiltIn == true { switchMic(gap: nil, announce: true) }
            }
        }
        if waitingForMic && ticks % 3 == 0 { switchMic(gap: pendingGap) }
        onStateChange?()
    }

    func devicesChanged() {
        lidClosed = Lid.isClosed()
        if isRecording {
            let present = Devices.inputs().map(\.uid)
            if let dev = recorder?.device, !present.contains(dev.uid) {
                log("\(dev.name) disconnected while recording")
                switchMic(gap: "mic disconnected", announce: true)
            } else if waitingForMic {
                switchMic(gap: pendingGap)
            }
        }
        onStateChange?()
    }

    // MARK: recording

    func startRecording(_ done: @escaping (Response) -> Void) {
        if let r = rec { return done(.success("already recording since \(Fmt.hhmm(r.start)) (\(Fmt.clock(elapsed)))")) }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                DispatchQueue.main.async { ok ? self.startRecording(done) : done(.failure("microphone access denied")) }
            }
            return
        default:
            return done(.failure("oton has no microphone access", hint: "System Settings → Privacy & Security → Microphone → oton"))
        }
        lidClosed = Lid.isClosed()
        guard let dev = Devices.pick(preferred: settings.preferredMics, lidClosed: lidClosed) else {
            return done(.failure(lidClosed ? "no usable mic (lid closed, built-in mic is off)" : "no usable mic",
                                 hint: "connect a mic or choose one: ot mic"))
        }
        let now = Date()
        let st = RecordingState(id: RecordingState.newID(now), start: now)
        do {
            let r = try Recorder(url: paths.activeAudio(st.id))
            try r.attach(dev)
            recorder = r
        } catch {
            transcriber.discard(st)
            log("cannot start: \(error)")
            return done(.failure("cannot record: \(error.localizedDescription)"))
        }
        rec = st
        recorder?.onInterrupted = { [weak self] in
            guard let self else { return }
            // At most one re-open every 3 s, whatever the audio system does.
            let wait = max(0, 3 - Date().timeIntervalSince(self.lastReopen))
            log("audio engine stopped on \(self.recorder?.device?.name ?? "?"); re-opening in \(Int(wait.rounded())) s")
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                guard let self, self.isRecording else { return }
                self.lastReopen = Date()
                self.switchMic(gap: nil)
            }
        }
        recorder?.onError = { msg in log(msg) }
        beginSegment(dev)
        assertion.set(true)
        log("recording on \(dev.name)")
        onStateChange?()
        done(.success("recording on \(dev.name)", data: ["mic": .string(dev.name)]))
    }

    func beginSegment(_ dev: InputDevice) {
        guard var st = rec, let r = recorder else { return }
        st.segments.append(Segment(outStart: r.writtenSeconds, wallStart: Date(), mic: dev.name, gapReason: pendingGap))
        pendingGap = nil
        rec = st
        do { try st.save(paths) } catch { log("cannot save recording state: \(error)") }
    }

    /// (Re)opens the best mic for the running recording. `gap`: why audio is missing until then, if it is.
    /// `announce`: notify when this lands on a different mic (it wasn't my choice).
    func switchMic(gap: String?, announce: Bool = false) {
        guard isRecording, let r = recorder else { return }
        let previous = r.device
        r.detach()
        if let gap { pendingGap = gap }
        lidClosed = Lid.isClosed()
        guard let dev = Devices.pick(preferred: settings.preferredMics, lidClosed: lidClosed) else {
            if !waitingForMic {
                waitingForMic = true
                pendingGap = pendingGap ?? "no mic"
                log("no usable mic; waiting")
                notifier?.post(title: "oton: no microphone", body: "Recording continues as soon as a mic is available. Click the menu bar icon to stop.")
            }
            onStateChange?()
            return
        }
        do {
            try r.attach(dev)
            waitingForMic = false
            beginSegment(dev)
            if previous?.uid != dev.uid {
                log("recording on \(dev.name) (was \(previous?.name ?? "none"))")
                if announce { notifier?.post(title: "oton switched mic", body: "Now recording on \(dev.name).") }
            }
        } catch {
            log("cannot open \(dev.name): \(error)")
            waitingForMic = true
        }
        onStateChange?()
    }

    func stopRecording(_ done: (Response) -> Void) {
        guard let st = rec, let r = recorder else { return done(.failure("not recording")) }
        let secs = elapsed
        r.finish()
        recorder = nil
        rec = nil
        waitingForMic = false
        pendingGap = nil
        assertion.set(false)
        log("stopped after \(Fmt.clock(secs))")
        finalize(st)
        onStateChange?()
        done(.success("stopped after \(Fmt.clock(secs)); transcribing, you'll get a notification"))
    }

    func toggle(_ done: @escaping (Response) -> Void) {
        isRecording ? stopRecording(done) : startRecording(done)
    }

    /// CAF → .m4a in recordings/, then queue it for Wolfgang.
    func finalize(_ st: RecordingState, notes: [String] = []) {
        encoding += 1
        let t = transcriber
        encodeQueue.async {
            let result = Result { try t.finalizeRecording(st, notes: notes) }
            DispatchQueue.main.async {
                self.encoding -= 1
                switch result {
                case .success(let job):
                    log("saved \(job.id).m4a")
                    self.enqueue(job)
                case .failure(OtonError.tooShort):
                    self.notifier?.post(title: "oton", body: "Recording too short, discarded.")
                case .failure(let e):
                    // The CAF stays in active/ and is retried on the next start.
                    log("cannot save recording \(st.id): \(e)")
                    self.notifier?.post(title: "oton: recording not saved", body: "\(e)")
                }
                self.onStateChange?()
            }
        }
        onStateChange?()
    }

    // MARK: transcription

    func enqueue(_ job: Job) {
        jobs[job.id] = job
        onStateChange?()
        let t = transcriber
        transcribeQueue.async {
            let result = Result { try t.run(job) }
            DispatchQueue.main.async { self.finished(job, result) }
        }
    }

    func finished(_ job: Job, _ result: Result<URL, Error>) {
        jobs[job.id] = nil
        let span = "\(Fmt.hhmm(job.start))–\(Fmt.hhmm(job.end)) (\(Fmt.compact(job.end.timeIntervalSince(job.start))))"
        switch result {
        case .success(let url):
            log("transcript ready: \(url.lastPathComponent)")
            notifier?.postReady(title: "Transcript ready", body: "\(span) · copy it with the prompt for Gemini", path: url.path)
        case .failure(OtonError.noSpeech):
            log("\(job.id): no speech")
            notifier?.post(title: "No speech recognised", body: "\(span). The recording is kept in ~/oton/recordings.")
        case .failure(let e):
            log("\(job.id) failed: \(e)")
            notifier?.post(title: "Transcription failed", body: "\(span): \(e). Retry from the menu or with `ot retry`.")
        }
        onStateChange?()
    }

    func retry(id: String?) -> Response {
        let failed = transcriber.pending().filter { $0.status == .failed }
        guard let job = id.flatMap({ i in failed.first { $0.id == i } }) ?? failed.last else { return .failure("no failed transcription to retry") }
        enqueue(job)
        return .success("transcribing \(job.id) again")
    }

    // MARK: copy

    func copy(path: String, prompt: Bool, open: Bool = false) -> Response {
        guard let info = Library(paths: paths).transcript(at: path), let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            return .failure("cannot read \(path)")
        }
        let out = prompt ? Prompt.render(template: Prompt.template(paths: paths), transcript: text, info: info) : text
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(out, forType: .string)
        if open, let url = URL(string: settings.geminiURL) { NSWorkspace.shared.open(url) }
        return .success("copied \(info.timeRange)\(prompt ? " with the prompt" : "")")
    }

    /// No n: the latest, with the prompt (refused while a newer recording is still being transcribed).
    /// With n: that one, plain unless `prompt`.
    func copy(n: Int?, prompt: Bool?, open: Bool) -> Response {
        if n == nil && isBusy {
            return .failure("the latest recording is still being transcribed; nothing copied", hint: "wait for the notification")
        }
        let items = Library(paths: paths).transcripts()
        let idx = (n ?? 1) - 1
        guard idx >= 0, idx < items.count else { return .failure(items.isEmpty ? "no transcriptions yet" : "no transcription \(n!); see ot list") }
        return copy(path: items[idx].path, prompt: prompt ?? (n == nil), open: open)
    }

    // MARK: mics

    /// Connected inputs, with what oton would do with each.
    func micRows() -> [(dev: InputDevice, state: String, current: Bool)] {
        lidClosed = Lid.isClosed()
        let devs = Devices.inputs()
        let current = recorder?.device ?? Devices.pick(preferred: settings.preferredMics, lidClosed: lidClosed)
        return devs.map { d in
            let isCurrent = d.uid == current?.uid
            var state: String
            if isCurrent { state = isRecording ? "recording" : "will record" }
            else if d.isBuiltIn && lidClosed { state = "lid closed, off" }
            else if [.bluetooth, .virtual, .aggregate, .continuity].contains(d.kind) { state = "\(d.kind.rawValue), only when chosen" }
            else { state = "available" }
            return (d, state, isCurrent)
        }
    }

    func micList() -> Response {
        let rows = micRows()
        let lines = rows.enumerated().map { i, r in "\(r.current ? "▸" : " ") \(i + 1). \(r.dev.name) – \(r.state)" }
        let data: JSON = .array(rows.enumerated().map { i, r in
            ["n": .number(Double(i + 1)), "name": .string(r.dev.name), "state": .string(r.state), "current": .bool(r.current), "kind": .string(r.dev.kind.rawValue)]
        })
        return .success(lines.isEmpty ? "no input devices" : lines.joined(separator: "\n"), data: data)
    }

    func setMic(_ query: String) -> Response {
        let names = micRows().map(\.dev.name)
        let name: String
        switch matchMic(query, in: names) {
        case .found(let n): name = n
        case .none: return .failure("no mic matches \"\(query)\"", hint: "see ot mic")
        case .ambiguous(let hits): return .failure("\"\(query)\" matches several mics: \(hits.joined(separator: ", "))", hint: "use the number from ot mic")
        }
        return chooseMic(name)
    }

    /// Remembers `name` as the preferred mic; a running recording switches to it right away.
    func chooseMic(_ name: String) -> Response {
        settings.preferredMics = remember(name, in: settings.preferredMics)
        do { try settings.save(to: paths.settings) } catch { return .failure("cannot save settings: \(error)") }
        log("preferred mic: \(name)")
        var msg = "preferred mic: \(name)"
        if Devices.inputs().first(where: { $0.name == name })?.isBuiltIn == true && Lid.isClosed() {
            msg += " (lid closed: used once the lid is open)"
        }
        if isRecording, let dev = Devices.pick(preferred: settings.preferredMics, lidClosed: Lid.isClosed()), dev.uid != recorder?.device?.uid {
            switchMic(gap: nil)
            msg += "; recording continues on it"
        }
        onStateChange?()
        return .success(msg)
    }

    // MARK: requests (main thread)

    func handle(_ req: Request, emit: @escaping (Response) -> Void) {
        switch req.cmd {
        case "status": emit(status())
        case "start": startRecording(emit)
        case "stop": stopRecording(emit)
        case "toggle": toggle(emit)
        case "copy": emit(copy(n: req.n, prompt: req.prompt, open: req.open ?? false))
        case "list": emit(list())
        case "mic-list": emit(micList())
        case "mic-set": emit(setMic(req.name ?? ""))
        case "retry": emit(retry(id: req.id))
        case "reveal":
            let url = req.name == "recordings" ? paths.recordings : paths.transcriptions
            NSWorkspace.shared.open(url)
            emit(.success(url.path))
        case "reload":
            loadSettings()
            checkWolfgang()
            emit(settingsError.map { .failure($0) } ?? .success("settings reloaded"))
        default:
            emit(.failure("unknown command \(req.cmd)"))
        }
    }

    func status() -> Response {
        lidClosed = Lid.isClosed()
        let failed = transcriber.pending().filter { $0.status == .failed }
        let next = Devices.pick(preferred: settings.preferredMics, lidClosed: lidClosed)
        var lines: [String] = []
        if let r = rec {
            if waitingForMic { lines.append("● recording \(Fmt.clock(elapsed)) since \(Fmt.hhmm(r.start)), waiting for a mic") }
            else { lines.append("● recording \(Fmt.clock(elapsed)) since \(Fmt.hhmm(r.start)) on \(recorder?.device?.name ?? "?")") }
        } else if let next {
            lines.append("○ ready – mic: \(next.name)")
        } else {
            lines.append("○ no usable mic" + (lidClosed ? " (lid closed)" : ""))
        }
        if encoding > 0 || !jobs.isEmpty { lines.append("transcribing \(encoding + jobs.count) recording(s)…") }
        if !failed.isEmpty { lines.append("⚠︎ \(failed.count) failed transcription(s): ot retry") }
        if !wolfgangOK { lines.append("⚠︎ Wolfgang or its transcription add-on is missing") }
        if let e = settingsError { lines.append("⚠︎ \(e)") }
        let latest = Library(paths: paths).transcripts().first
        let data: JSON = [
            "recording": .bool(isRecording),
            "since": rec.map { .string(ISO8601DateFormatter().string(from: $0.start)) } ?? .null,
            "elapsed": .number(elapsed.rounded()),
            "mic": (recorder?.device?.name ?? next?.name).map { .string($0) } ?? .null,
            "waitingForMic": .bool(waitingForMic),
            "transcribing": .number(Double(encoding + jobs.count)),
            "failed": .number(Double(failed.count)),
            "lidClosed": .bool(lidClosed),
            "wolfgangOK": .bool(wolfgangOK),
            "latest": latest.map { .string($0.title) } ?? .null,
        ]
        return .success(lines.joined(separator: "\n"), data: data)
    }

    func list() -> Response {
        let items = Library(paths: paths).transcripts()
        let failed = transcriber.pending().filter { $0.status == .failed }
        var lines = items.prefix(30).map { "\($0.number). \($0.title)" }
        if items.isEmpty { lines.append("no transcriptions yet") }
        for j in failed { lines.append("✗ \(j.id): \(j.error ?? "?")  → ot retry \(j.id)") }
        if isBusy { lines.append("… \(encoding + jobs.count) still transcribing") }
        let data: JSON = [
            "transcripts": .array(items.map { ["n": .number(Double($0.number)), "title": .string($0.title), "name": .string($0.name), "path": .string($0.path)] }),
            "failed": .array(failed.map { ["id": .string($0.id), "error": .string($0.error ?? "")] }),
            "transcribing": .number(Double(encoding + jobs.count)),
        ]
        return .success(lines.joined(separator: "\n"), data: data)
    }

    /// Quit while recording: close the file and encode it now; Wolfgang runs on the next start.
    func shutdown() {
        guard let st = rec, let r = recorder else { return }
        r.finish()
        rec = nil
        recorder = nil
        assertion.set(false)
        _ = try? transcriber.finalizeRecording(st, notes: ["oton quit while recording"])
        log("quit while recording; saved \(st.id)")
    }
}
