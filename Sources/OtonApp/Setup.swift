import AppKit
import Foundation
import ServiceManagement

/// One-time setup steps, all reachable from the menu so nobody needs a terminal.
enum Setup {
    static let cliLink = "/usr/local/bin/ot"
    static let wolfgangDownload = URL(string: "https://github.com/k1tesurfen/wolfgang/releases/latest")!

    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }
    static var cliInBundle: String { Bundle.main.bundlePath + "/Contents/MacOS/ot" }

    // MARK: open at login (System Settings → General → Login Items)

    static var opensAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    static func setOpensAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            log("open at login: \(on)")
        } catch {
            log("open at login \(on) failed: \(error)")
        }
    }

    /// First start of an installed copy: open at login unless I turned that off before.
    static func registerOnFirstStart() {
        let key = "didOfferLoginItem"
        guard Bundle.main.bundlePath.hasPrefix("/Applications/"), !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        if SMAppService.mainApp.status != .enabled { setOpensAtLogin(true) }
    }

    // MARK: command line tool

    static var cliInstalled: Bool { (try? FileManager.default.destinationOfSymbolicLink(atPath: cliLink)) == cliInBundle }

    /// Links /usr/local/bin/ot into the bundle; macOS asks for an admin password.
    static func installCLI() -> String? {
        let cmd = "mkdir -p /usr/local/bin && ln -sf '\(cliInBundle)' '\(cliLink)'"
        let script = "do shell script \"\(cmd)\" with administrator privileges"
        var err: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&err)
        if let err, (err[NSAppleScript.errorNumber] as? Int) != -128 {   // -128: cancelled
            return err[NSAppleScript.errorMessage] as? String ?? "failed"
        }
        return cliInstalled ? nil : (err == nil ? "failed" : "cancelled")
    }

    // MARK: Alfred

    static var alfredWorkflow: URL? { Bundle.main.url(forResource: "oton", withExtension: "alfredworkflow") }

    static func installAlfredWorkflow() {
        if let url = alfredWorkflow { NSWorkspace.shared.open(url) }
    }
}
