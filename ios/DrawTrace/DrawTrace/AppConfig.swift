import Foundation

/// 設定値（ios/Config/Base.xcconfig → ios/Config/AppInfo.plist → Info.plist）。
enum AppConfig {
    /// 受付API の URL（`API_BASE_URL`）。
    static var apiBaseURL: URL? { url(forKey: "APIBaseURL") }

    /// 検証ページの URL（`HOSTING_URL`）。
    static var hostingURL: URL? { url(forKey: "HostingURL") }

    private static func url(forKey key: String) -> URL? {
        guard
            let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
            !value.isEmpty,
            !value.contains("$("),
            let url = URL(string: value),
            url.scheme == "https" || url.scheme == "http"
        else { return nil }
        return url
    }
}
