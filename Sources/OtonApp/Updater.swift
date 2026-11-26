import AppKit
import Foundation
import OtonCore
import Security

/// Self-update from GitHub releases (`oton.app.zip`). A new build is only installed if its code signature
/// satisfies this app's own designated requirement, i.e. same bundle id and the same "oton Local" certificate.
/// That keeps the microphone permission, and nothing else can slip in through the update.
final class Updater {
    weak var controller: Controller?
    private(set) var available: AvailableUpdate?
    private(set) var installing = false
    private var notified: String?
    var onChange: (() -> Void)?

    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { self.check() }
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in self?.check() }
    }

    /// Asks GitHub; notifies once per new version (not when `quiet`).
    func check(quiet: Bool = false, done: ((AvailableUpdate?) -> Void)? = nil) {
        var req = URLRequest(url: UpdateCheck.latestRelease, timeoutInterval: 20)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("oton/\(Setup.version)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, _, error in
            let found = data.flatMap { UpdateCheck.parse($0, current: Setup.version) }
            DispatchQueue.main.async {
                if let error { log("update check failed: \(error.localizedDescription)") }
                self.available = found
                if let u = found, !quiet, self.notified != u.version {
                    self.notified = u.version
                    log("update available: \(u.version)")
                    self.controller?.notifier?.postUpdate(version: u.version)
                }
                self.onChange?()
                done?(found)
            }
        }.resume()
    }

    /// Download, verify, replace /Applications/oton.app, restart. Refuses while recording or transcribing.
    func install(_ done: @escaping (Response) -> Void) {
        guard let u = available else { return done(.failure("oton \(Setup.version) is the latest version")) }
        guard !installing else { return done(.success("already updating to \(u.version)")) }
        if let c = controller, c.isRecording || c.isBusy {
            return done(.failure("not while recording or transcribing", hint: "update afterwards: menu → Update, or ot update"))
        }
        let target = Bundle.main.bundleURL
        guard target.pathExtension == "app" else { return done(.failure("not running from oton.app (development build)")) }
        guard FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path) || FileManager.default.isWritableFile(atPath: target.path) else {
            NSWorkspace.shared.open(u.pageURL)
            return done(.failure("no permission to replace \(target.path); download the DMG instead"))
        }
        installing = true
        onChange?()
        log("downloading \(u.version)")
        URLSession.shared.downloadTask(with: u.zipURL) { tmp, resp, error in
            let result: Result<URL, Error> = Result {
                guard let tmp, (resp as? HTTPURLResponse)?.statusCode == 200 else {
                    throw err(error?.localizedDescription ?? "download failed (\((resp as? HTTPURLResponse)?.statusCode ?? 0))")
                }
                return try Self.unpackAndVerify(tmp, version: u.version)
            }
            DispatchQueue.main.async {
                switch result {
                case .failure(let e):
                    self.installing = false
                    self.onChange?()
                    log("update failed: \(e.localizedDescription)")
                    done(.failure("update failed: \(e.localizedDescription)"))
                case .success(let newApp):
                    do {
                        _ = try FileManager.default.replaceItemAt(target, withItemAt: newApp)
                    } catch {
                        self.installing = false
                        self.onChange?()
                        log("update: cannot replace app: \(error)")
                        return done(.failure("cannot replace \(target.path): \(error.localizedDescription)"))
                    }
                    log("updated to \(u.version); restarting")
                    done(.success("updated to oton \(u.version); restarting"))
                    Self.relaunch(target)
                }
            }
        }.resume()
    }

    /// Unzips into a fresh folder next to nothing else and checks the signature and version.
    static func unpackAndVerify(_ zip: URL, version: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oton-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, dir.path]
        try p.run()
        p.waitUntilExit()
        let app = dir.appendingPathComponent("oton.app")
        guard p.terminationStatus == 0, FileManager.default.fileExists(atPath: app.path) else { throw err("the download contains no oton.app") }

        // Same signer as the running app (designated requirement: bundle id + certificate).
        var me: SecCode?
        var meStatic: SecStaticCode?
        var myReq: SecRequirement?
        var newCode: SecStaticCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &meStatic) == errSecSuccess, let meStatic,
              SecCodeCopyDesignatedRequirement(meStatic, [], &myReq) == errSecSuccess, let myReq else { throw err("cannot read this app's signature") }
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &newCode) == errSecSuccess, let newCode else { throw err("cannot read the new app's signature") }
        let st = SecStaticCodeCheckValidity(newCode, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate), myReq)
        guard st == errSecSuccess else { throw err("the new app isn't signed like this one (\(st)); not installed") }

        let v = Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        guard v == version else { throw err("the download is version \(v ?? "?"), expected \(version)") }
        return app
    }

    /// Waits until this process is gone (single-instance lock), then opens the new app.
    static func relaunch(_ app: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; sleep 0.5; /usr/bin/open \"$0\"", app.path]
        try? p.run()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.delegate.flatMap { $0 as? AppDelegate }?.controller.shutdown()
            exit(0)
        }
    }
}

private func err(_ msg: String) -> NSError { NSError(domain: "oton.update", code: 1, userInfo: [NSLocalizedDescriptionKey: msg]) }
