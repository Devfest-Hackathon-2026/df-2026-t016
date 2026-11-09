import CryptoKit
import Foundation

/// エンコードの決まり（tasks/00_共通仕様.md の3章）。
public enum Canonical {
    /// キーを並べ、スラッシュをエスケープしない JSON。署名する対象のバイト列はこれで作る。
    public static func encodeSorted<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    /// SHA-256 の小文字の16進（64文字）。
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 標準の base64（パディングあり）。
    public static func base64(_ data: Data) -> String {
        data.base64EncodedString()
    }

    public static func fromBase64(_ string: String) -> Data? {
        Data(base64Encoded: string)
    }

    /// base64url（パディングなし）。ID やトークンに使う。
    public static func base64url(_ data: Data) -> String {
        base64(data)
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static let timeFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    /// 時刻の文字列（UTC、ミリ秒まで）。例: `2026-11-06T00:12:34.567Z`
    public static func timeString(_ date: Date = Date()) -> String {
        timeFormatter.string(from: date)
    }

    public static func parseTime(_ string: String) -> Date? {
        timeFormatter.date(from: string)
    }
}
