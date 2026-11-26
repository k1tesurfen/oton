import AppKit
import Foundation
import OtonCore

// Single instance: a second copy (e.g. launched by hand while the LaunchAgent runs) exits cleanly.
try? Paths.standard.prepare()
let lockFD = open(Paths.standard.lock.path, O_CREAT | O_RDWR, 0o600)
if lockFD < 0 || flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
    FileHandle.standardError.write(Data("oton is already running.\n".utf8))
    exit(0)
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller = Controller()
    var statusItem: StatusItem?
    var server: SocketServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let c = controller
        // UNUserNotificationCenter crashes outside an app bundle (e.g. `swift run` during development).
        if Bundle.main.bundleIdentifier != nil {
            c.notifier = Notifier { path in
                let r = c.copy(path: path, prompt: true)
                if !r.ok { c.notifier?.post(title: "oton", body: r.message) }
            }
        }
        let up = Updater()
        up.controller = c
        c.updater = up
        c.notifier?.onUpdate = { up.install { r in if !r.ok { c.notifier?.post(title: "oton", body: r.message) } } }
        statusItem = StatusItem(controller: c)
        c.onStateChange = { [weak self] in self?.statusItem?.refresh() }
        c.start()
        Setup.registerOnFirstStart()
        up.onChange = { [weak self] in self?.statusItem?.refresh() }
        if Bundle.main.bundleURL.pathExtension == "app" { up.start() }

        // Socket requests arrive on background threads; all state lives on the main thread.
        server = SocketServer(path: c.paths.socket.path) { req, emit in
            DispatchQueue.main.async { c.handle(req, emit: emit) }
        }
        do { try server?.start() } catch { log("socket: \(error)") }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.shutdown()
        server?.stop()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
signal(SIGPIPE, SIG_IGN)
app.run()
