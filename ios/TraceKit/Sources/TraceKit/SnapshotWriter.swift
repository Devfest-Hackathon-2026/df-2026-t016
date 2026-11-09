import Foundation

/// 画像の端末署名を作るもの。録画拡張では `DeviceKey`（T07 で、開始の登録に使った鍵を渡す）。
public protocol ImageSigning {
    func signImage(sid: String, sha256: String) throws -> Data
}

extension DeviceKey: ImageSigning {}

/// 撮った画像を App Group に保存する（共通仕様8章）。
/// - `sessions/{sid}/images/{sha}.jpg`: JPEG
/// - `sessions/{sid}/images/{sha}.sig`: 画像の端末署名（b64）。撮ったときに作る
/// - `sessions/{sid}/images/{sha}.pending`: 開始・終了・途中の全体画像を送る印。受信後に消す。
public final class SnapshotWriter {
    public let store: AppGroupStore
    public let sid: String
    private let signer: ImageSigning

    public init(store: AppGroupStore, sid: String, signer: ImageSigning) throws {
        self.store = store
        self.sid = sid
        self.signer = signer
        try store.prepareSession(sid)
    }

    public func imageURL(_ sha: String) -> URL {
        store.directory(.images, sid: sid).appendingPathComponent("\(sha).jpg")
    }

    public func signatureURL(_ sha: String) -> URL {
        store.directory(.images, sid: sid).appendingPathComponent("\(sha).sig")
    }

    public func pendingURL(_ sha: String) -> URL {
        store.directory(.images, sid: sid).appendingPathComponent("\(sha).pending")
    }

    /// JPEG と署名を保存して、sha を返す。同じ画像がすでにあれば、上書きしない。
    @discardableResult
    public func save(_ jpeg: Data) throws -> String {
        let sha = Canonical.sha256Hex(jpeg)
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: imageURL(sha).path) {
            try jpeg.write(to: imageURL(sha), options: .atomic)
        }
        if !fileManager.fileExists(atPath: signatureURL(sha).path) {
            let signature = try signer.signImage(sid: sid, sha256: sha)
            try Data(Canonical.base64(signature).utf8).write(to: signatureURL(sha), options: .atomic)
        }
        return sha
    }

    /// 送る画像にする（開始画面・終了画面に決まったとき）。
    public func markPending(_ sha: String) throws {
        try Data().write(to: pendingURL(sha), options: .atomic)
    }

    /// 使わなくなった全体画像（`whole.json` の `latest` から外れたもの）を消す。送る印が付いているものは消さない。
    public func remove(_ sha: String) {
        guard !FileManager.default.fileExists(atPath: pendingURL(sha).path) else { return }
        store.remove(imageURL(sha))
        store.remove(signatureURL(sha))
    }
}

extension AppGroupStore {
    /// 【11/6】`sessions/{sid}/whole.json`（撮った全体画像の一覧。録画拡張が書き、本体アプリが読む）。
    public func wholeURL(sid: String) -> URL {
        sessionDirectory(sid).appendingPathComponent("whole.json")
    }

    public func wholeRecord(sid: String) -> WholeRecord? {
        guard let data = try? Data(contentsOf: wholeURL(sid: sid)) else { return nil }
        return try? JSONDecoder().decode(WholeRecord.self, from: data)
    }

    public func setWholeRecord(_ value: WholeRecord, sid: String) throws {
        try Canonical.encodeSorted(value).write(to: wholeURL(sid: sid), options: .atomic)
    }
}
