import Foundation
import Testing
@testable import OtonCore

@Suite struct UpdateTests {
    @Test func versions() {
        #expect(UpdateCheck.isNewer("0.3.0", than: "0.2.1"))
        #expect(UpdateCheck.isNewer("v0.10.0", than: "0.9.9"))
        #expect(UpdateCheck.isNewer("1.0", than: "0.9.9"))
        #expect(!UpdateCheck.isNewer("0.2.1", than: "0.2.1"))
        #expect(!UpdateCheck.isNewer("0.2", than: "0.2.0"))
        #expect(!UpdateCheck.isNewer("0.2.0", than: "0.2.1"))
        #expect(!UpdateCheck.isNewer("0.3.0", than: "dev"))
        #expect(!UpdateCheck.isNewer("nightly", than: "0.2.1"))
    }

    func release(tag: String, assets: [String], prerelease: Bool = false) -> Data {
        let a = assets.map { ["name": $0, "browser_download_url": "https://github.com/k1tesurfen/oton/releases/download/\(tag)/\($0)"] }
        return try! JSONSerialization.data(withJSONObject: ["tag_name": tag, "draft": false, "prerelease": prerelease,
                                                            "html_url": "https://github.com/k1tesurfen/oton/releases/tag/\(tag)", "assets": a])
    }

    @Test func parsesGitHubRelease() {
        let u = UpdateCheck.parse(release(tag: "v0.3.0", assets: ["oton.dmg", "oton.app.zip"]), current: "0.2.1")
        #expect(u?.version == "0.3.0")
        #expect(u?.zipURL.absoluteString == "https://github.com/k1tesurfen/oton/releases/download/v0.3.0/oton.app.zip")
        #expect(UpdateCheck.parse(release(tag: "v0.3.0", assets: ["oton.dmg"]), current: "0.2.1") == nil)           // no zip: DMG only
        #expect(UpdateCheck.parse(release(tag: "v0.2.1", assets: ["oton.app.zip"]), current: "0.2.1") == nil)       // not newer
        #expect(UpdateCheck.parse(release(tag: "v0.3.0", assets: ["oton.app.zip"], prerelease: true), current: "0.2.1") == nil)
        #expect(UpdateCheck.parse(Data("{\"message\":\"API rate limit exceeded\"}".utf8), current: "0.2.1") == nil)
    }
}
