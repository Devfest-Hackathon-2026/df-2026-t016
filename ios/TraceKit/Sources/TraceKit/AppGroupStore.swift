import Foundation

/// App Group の UserDefaults とファイル置き場（tasks/00_共通仕様.md の8章）。
/// 本体アプリと録画拡張の両方から使う。
public final class AppGroupStore {
    public static let defaultGroupID = "group.com.ggdevfest2026.drawtrace"

    public enum Key {
        public static let sessionCurrent = "session.current"
        public static let broadcastStatus = "broadcast.status"
        public static let broadcastDebug = "broadcast.debug"
    }

    /// `sessions/{sid}/` の下のフォルダ。
    public enum Folder: String, CaseIterable {
        case queue, images, receipts
    }

    public let defaults: UserDefaults
    public let containerURL: URL

    /// App Group を開く。entitlements に App Group が入っていなければ `nil`。
    public convenience init?(groupID: String = AppGroupStore.defaultGroupID) {
        guard
            let defaults = UserDefaults(suiteName: groupID),
            let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)
        else { return nil }
        self.init(defaults: defaults, containerURL: url)
    }

    /// 試験用。任意の UserDefaults とフォルダを使う。
    public init(defaults: UserDefaults, containerURL: URL) {
        self.defaults = defaults
        self.containerURL = containerURL
    }

    // MARK: - UserDefaults（JSON 文字列で入れる）

    public func readJSON<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let string = defaults.string(forKey: key), let data = string.data(using: .utf8) else {
            return nil
        }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    public func writeJSON<T: Encodable>(_ value: T, forKey key: String) throws {
        let data = try Canonical.encodeSorted(value)
        defaults.set(String(decoding: data, as: UTF8.self), forKey: key)
    }

    /// そのキーの生の文字列（表示や調査用）。
    public func rawString(forKey key: String) -> String? {
        defaults.string(forKey: key)
    }

    public func removeValue(forKey key: String) {
        defaults.removeObject(forKey: key)
    }

    public var sessionCurrent: SessionInfo? {
        readJSON(SessionInfo.self, forKey: Key.sessionCurrent)
    }

    public func setSessionCurrent(_ value: SessionInfo) throws {
        try writeJSON(value, forKey: Key.sessionCurrent)
    }

    public var broadcastStatus: BroadcastStatus? {
        readJSON(BroadcastStatus.self, forKey: Key.broadcastStatus)
    }

    public func setBroadcastStatus(_ value: BroadcastStatus) throws {
        try writeJSON(value, forKey: Key.broadcastStatus)
    }

    public var broadcastDebug: BroadcastDebug? {
        readJSON(BroadcastDebug.self, forKey: Key.broadcastDebug)
    }

    public func setBroadcastDebug(_ value: BroadcastDebug) throws {
        try writeJSON(value, forKey: Key.broadcastDebug)
    }


    // MARK: - ファイル

    public func sessionDirectory(_ sid: String) -> URL {
        containerURL
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(sid, isDirectory: true)
    }

    public func directory(_ folder: Folder, sid: String) -> URL {
        sessionDirectory(sid).appendingPathComponent(folder.rawValue, isDirectory: true)
    }

    /// `sessions/{sid}/` と、その下の queue・images・receipts を作る。
    @discardableResult
    public func prepareSession(_ sid: String) throws -> URL {
        let fileManager = FileManager.default
        for folder in Folder.allCases {
            try fileManager.createDirectory(at: directory(folder, sid: sid), withIntermediateDirectories: true)
        }
        return sessionDirectory(sid)
    }

    /// フォルダの中のファイルを、名前の順に返す（`seq:06d` の名前なら seq の順になる）。
    public func files(in folder: Folder, sid: String) -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory(folder, sid: sid),
            includingPropertiesForKeys: nil
        )) ?? []
        return urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    public func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    public func removeSession(_ sid: String) {
        remove(sessionDirectory(sid))
    }
}
