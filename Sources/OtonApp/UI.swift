import AppKit
import OtonCore
import UserNotifications

final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    /// Copies the transcript at the path with the prompt.
    let onCopy: (String) -> Void
    var onUpdate: (() -> Void)?

    init(onCopy: @escaping (String) -> Void) {
        self.onCopy = onCopy
        super.init()
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        let copy = UNNotificationAction(identifier: "COPY", title: "Copy for Gemini", options: [])
        let update = UNNotificationAction(identifier: "UPDATE", title: "Update", options: [])
        c.setNotificationCategories([UNNotificationCategory(identifier: "READY", actions: [copy], intentIdentifiers: []),
                                     UNNotificationCategory(identifier: "UPDATE", actions: [update], intentIdentifiers: [])])
        c.requestAuthorization(options: [.alert, .sound]) { ok, err in
            if !ok { log("notifications not allowed \(err.map { "\($0)" } ?? "")") }
            DispatchQueue.main.async { self.allowed = ok }
        }
    }

    /// Whether macOS lets us show notifications (re-checked by `refreshPermission`).
    private(set) var allowed = true

    func refreshPermission() {
        UNUserNotificationCenter.current().getNotificationSettings { s in
            let ok = s.authorizationStatus == .authorized || s.authorizationStatus == .provisional
            DispatchQueue.main.async { self.allowed = ok }
        }
    }

    func post(title: String, body: String) { add(title: title, body: body, category: nil, info: [:]) }

    func postReady(title: String, body: String, path: String) { add(title: title, body: body, category: "READY", info: ["path": path]) }

    func postUpdate(version: String) {
        add(title: "oton \(version) is available", body: "You have \(Setup.version). Update now, or later from the menu.", category: "UPDATE", info: [:])
    }

    private func add(title: String, body: String, category: String?, info: [String: String]) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = info
        if let category { content.categoryIdentifier = category }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        // The "Copy for Gemini" button, or a click on the notification itself.
        let content = response.notification.request.content
        if content.categoryIdentifier == "READY", let path = content.userInfo["path"] as? String,
           response.actionIdentifier == "COPY" || response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            DispatchQueue.main.async { self.onCopy(path) }
        }
        if content.categoryIdentifier == "UPDATE",
           response.actionIdentifier == "UPDATE" || response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            DispatchQueue.main.async { self.onUpdate?() }
        }
        done()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .sound])
    }
}

/// Left click: start/stop. Right click (or ⌃/⌥ click): the menu.
/// Only the mark, at a fixed width: the menu bar never relayouts while recording (a ticking clock made macOS
/// re-place its orange mic indicator every second). The running time is in the tooltip.
final class StatusItem: NSObject, NSMenuDelegate, NSViewToolTipOwner {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var shown: Look?
    let menu = NSMenu()
    let controller: Controller

    init(controller: Controller) {
        self.controller = controller
        super.init()
        menu.delegate = self
        if let b = item.button {
            b.target = self
            b.action = #selector(clicked)
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
            b.imagePosition = .imageOnly
            // Text computed when the tooltip appears, so it shows the current recording time.
            b.addToolTip(b.bounds, owner: self, userData: nil)
        }
        refresh()
    }

    @objc func clicked() {
        let ev = NSApp.currentEvent
        if ev?.type == .rightMouseUp || ev?.modifierFlags.contains(.control) == true || ev?.modifierFlags.contains(.option) == true {
            item.menu = menu
            item.button?.performClick(nil)   // returns when the menu closes
            item.menu = nil
        } else {
            run { $0.toggle($1) }
        }
    }

    enum Look { case idle, recording, waiting, transcribing }

    /// Called every second while recording; touches the button only when the look changes.
    func refresh() {
        let c = controller
        let look: Look = c.isRecording ? (c.waitingForMic ? .waiting : .recording) : (c.isBusy ? .transcribing : .idle)
        guard look != shown else { return }
        shown = look
        item.button?.image = Self.icon(look)
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        let c = controller
        let line: String
        if let r = c.rec {
            line = "● " + Fmt.clock(c.elapsed) + " since " + Fmt.hhmm(r.start) + (c.waitingForMic ? ", waiting for a mic" : " on " + (c.recorder?.device?.name ?? "?"))
        } else {
            line = c.status().message.split(separator: "\n").first.map(String.init) ?? "oton"
        }
        return line + "\nclick: " + (c.isRecording ? "stop" : "start") + " · right-click: menu"
    }

    /// The oton mark (Resources/icon/oton.svg) as a monochrome template: a thick O, with the dot while recording.
    /// Waiting for a mic: hollow dot. Transcribing: dimmed O.
    static func icon(_ look: Look) -> NSImage {
        let img = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { r in
            // Proportions from the SVG (outer 299×300, inner 173×204, dot 89 on a 600-high O).
            let k = r.height / 600
            let c = NSPoint(x: r.midX, y: r.midY)
            func oval(_ rx: CGFloat, _ ry: CGFloat) -> NSRect { NSRect(x: c.x - rx * k, y: c.y - ry * k, width: 2 * rx * k, height: 2 * ry * k) }
            let ring = NSBezierPath(ovalIn: oval(299, 300))
            ring.append(NSBezierPath(ovalIn: oval(173, 204)).reversed)
            NSColor.black.withAlphaComponent(look == .transcribing ? 0.4 : 1).setFill()
            ring.fill()
            switch look {
            case .recording: NSBezierPath(ovalIn: oval(105, 105)).fill()
            case .waiting:
                let dot = NSBezierPath(ovalIn: oval(90, 90))
                dot.lineWidth = 30 * k
                NSColor.black.setStroke()
                dot.stroke()
            default: break
            }
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "oton"
        return img
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        controller.notifier?.refreshPermission()   // for the next time the menu opens
        menu.removeAllItems()
        let c = controller
        for line in c.status().message.split(separator: "\n") {
            let i = NSMenuItem(title: String(line), action: nil, keyEquivalent: "")
            i.isEnabled = false
            menu.addItem(i)
        }
        if let u = c.updater?.available {
            let i = add(menu, c.updater?.installing == true ? "Updating to oton \(u.version)…" : "Update to oton \(u.version)…", #selector(update))
            i.isEnabled = c.updater?.installing != true
        }
        menu.addItem(.separator())
        add(menu, c.isRecording ? "Stop recording" : "Start recording", #selector(toggle))
        let copy = add(menu, "Copy latest for Gemini", #selector(copyLatest))
        copy.isEnabled = !c.isBusy && !Library(paths: c.paths).transcripts().isEmpty

        let recent = NSMenu()
        for t in Library(paths: c.paths).transcripts().prefix(8) {
            let i = NSMenuItem(title: t.title, action: #selector(copyPath(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = t.path
            i.toolTip = "Copy with the prompt"
            recent.addItem(i)
        }
        let recentItem = NSMenuItem(title: "Recent transcriptions", action: nil, keyEquivalent: "")
        recentItem.submenu = recent
        recentItem.isEnabled = recent.numberOfItems > 0
        menu.addItem(recentItem)

        let mics = NSMenu()
        for row in c.micRows() {
            let i = NSMenuItem(title: row.dev.name, action: #selector(chooseMic(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = row.dev.name
            i.state = row.current ? .on : .off
            if row.dev.isBuiltIn && c.lidClosed { i.title += " (lid closed)"; i.isEnabled = false }
            mics.addItem(i)
        }
        let micItem = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        micItem.submenu = mics
        menu.addItem(micItem)

        if c.transcriber.pending().contains(where: { $0.status == .failed }) {
            add(menu, "Retry failed transcription", #selector(retry))
        }
        // Things that need fixing before oton fully works.
        if !c.wolfgangOK { add(menu, "⚠︎ Get Wolfgang (needed for transcription)…", #selector(getWolfgang)) }
        if c.notifier?.allowed == false { add(menu, "⚠︎ Allow notifications (for the Copy button)…", #selector(allowNotifications)) }
        menu.addItem(.separator())
        add(menu, "Open recordings", #selector(openRecordings))
        add(menu, "Open transcriptions", #selector(openTranscriptions))
        add(menu, "Edit prompt…", #selector(editPrompt))

        let setup = NSMenu()
        let login = add(setup, "Open at login", #selector(toggleLogin))
        login.state = Setup.opensAtLogin ? .on : .off
        let cli = add(setup, Setup.cliInstalled ? "Command line tool `ot` installed" : "Install command line tool `ot`…", #selector(installCLI))
        cli.isEnabled = !Setup.cliInstalled
        add(setup, "Install Alfred workflow (keyword: ot)…", #selector(installAlfred)).isEnabled = Setup.alfredWorkflow != nil
        setup.addItem(.separator())
        add(setup, "Check for updates", #selector(checkUpdates))
        add(setup, "oton \(Setup.version) on GitHub…", #selector(openGitHub))
        let setupItem = NSMenuItem(title: "Setup", action: nil, keyEquivalent: "")
        setupItem.submenu = setup
        menu.addItem(setupItem)
        menu.addItem(.separator())
        add(menu, "Quit oton", #selector(quit))
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ sel: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = self
        menu.addItem(i)
        return i
    }

    /// Errors become a notification; everything else shows in the icon.
    private func run(_ f: (Controller, @escaping (Response) -> Void) -> Void) {
        f(controller) { [weak self] resp in
            guard resp.final, !resp.ok else { return }
            self?.controller.notifier?.post(title: "oton", body: resp.message + (resp.hint.map { " (\($0))" } ?? ""))
        }
    }

    @objc func toggle() { run { $0.toggle($1) } }
    @objc func copyLatest() { run { $1($0.copy(n: nil, prompt: nil, open: false)) } }
    @objc func copyPath(_ sender: NSMenuItem) { if let p = sender.representedObject as? String { run { $1($0.copy(path: p, prompt: true)) } } }
    @objc func chooseMic(_ sender: NSMenuItem) { if let n = sender.representedObject as? String { run { $1($0.chooseMic(n)) } } }
    @objc func retry() { run { $1($0.retry(id: nil)) } }
    @objc func openRecordings() { NSWorkspace.shared.open(controller.paths.recordings) }
    @objc func openTranscriptions() { NSWorkspace.shared.open(controller.paths.transcriptions) }
    @objc func editPrompt() { NSWorkspace.shared.open(controller.paths.prompt) }
    @objc func getWolfgang() { NSWorkspace.shared.open(Setup.wolfgangDownload) }
    @objc func allowNotifications() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=local.oton")!)
    }
    @objc func toggleLogin() { Setup.setOpensAtLogin(!Setup.opensAtLogin) }
    @objc func installCLI() {
        if let e = Setup.installCLI() { controller.notifier?.post(title: "oton", body: "Command line tool not installed: \(e)") }
        else { controller.notifier?.post(title: "oton", body: "Installed: type `ot help` in a terminal.") }
    }
    @objc func installAlfred() { Setup.installAlfredWorkflow() }
    @objc func update() { run { c, done in c.updater?.install(done) ?? done(.failure("no updater")) } }
    @objc func checkUpdates() {
        controller.updater?.check(quiet: true) { [weak self] u in
            self?.controller.notifier?.post(title: "oton", body: u.map { "oton \($0.version) is available: right-click → Update." } ?? "oton \(Setup.version) is the latest version.")
        }
    }
    @objc func openGitHub() { NSWorkspace.shared.open(URL(string: "https://github.com/k1tesurfen/oton")!) }
    @objc func quit() {
        controller.shutdown()
        exit(0)
    }
}
