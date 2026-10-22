import Foundation

/// GitHub'daki en son sürümün bilgisi.
public struct ReleaseInfo: Equatable, Sendable {
    public let version: String
    public let notes: String
    public let pageURL: URL
    /// İndirilecek uygulama arşivi; sürümde yoksa nil (o zaman yalnızca sayfa açılır).
    public let assetURL: URL?
}

/// GitHub Releases API yanıtını okur ve sürümleri karşılaştırır.
public enum UpdateFeed {
    public static let repository = "batuhanbecel/dpi-kalkan"
    public static let assetName = "DPI-Kalkan.zip"
    public static var latestURL: URL {
        URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    }

    /// `/releases/latest` yanıtından sürüm bilgisini çıkarır.
    public static func parse(_ data: Data) -> ReleaseInfo? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:))
        else { return nil }
        let assets = json["assets"] as? [[String: Any]] ?? []
        let asset = assets.first { $0["name"] as? String == assetName }?["browser_download_url"] as? String
        return ReleaseInfo(
            version: normalize(tag),
            notes: json["body"] as? String ?? "",
            pageURL: page,
            assetURL: asset.flatMap(URL.init(string:))
        )
    }

    /// "v1.10.0" > "1.9.2" gibi sayısal karşılaştırma; eksik parçalar 0 sayılır.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = components(candidate), b = components(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static func normalize(_ tag: String) -> String {
        tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
    }

    private static func components(_ version: String) -> [Int] {
        normalize(version).split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }
}
