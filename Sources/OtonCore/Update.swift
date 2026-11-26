import Foundation

/// Self-update: the latest GitHub release, if it's newer than this version and carries `oton.app.zip`.
public struct AvailableUpdate: Equatable, Sendable {
    public var version: String
    public var zipURL: URL
    public var pageURL: URL

    public init(version: String, zipURL: URL, pageURL: URL) {
        self.version = version
        self.zipURL = zipURL
        self.pageURL = pageURL
    }
}

public enum UpdateCheck {
    public static let latestRelease = URL(string: "https://api.github.com/repos/k1tesurfen/oton/releases/latest")!
    public static let assetName = "oton.app.zip"

    /// "0.10.1" > "0.9.3"; a leading "v" is ignored; missing parts count as 0. Non-numeric versions ("dev") never update.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ v: String) -> [Int]? {
            let s = v.hasPrefix("v") ? String(v.dropFirst()) : v
            let p = s.split(separator: ".").map { Int($0) }
            return p.isEmpty || p.contains(nil) ? nil : p.map { $0! }
        }
        guard let a = parts(candidate), let b = parts(current) else { return false }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Reads GitHub's `releases/latest` JSON. nil: not newer, a draft/prerelease, or no `oton.app.zip` asset.
    public static func parse(_ data: Data, current: String) -> AvailableUpdate? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String,
              (obj["draft"] as? Bool) != true, (obj["prerelease"] as? Bool) != true,
              isNewer(tag, than: current),
              let assets = obj["assets"] as? [[String: Any]],
              let zip = assets.first(where: { $0["name"] as? String == assetName })?["browser_download_url"] as? String,
              let zipURL = URL(string: zip),
              let page = URL(string: obj["html_url"] as? String ?? "https://github.com/k1tesurfen/oton/releases/latest")
        else { return nil }
        return AvailableUpdate(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, zipURL: zipURL, pageURL: page)
    }
}
