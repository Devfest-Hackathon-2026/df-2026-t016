import Foundation

/// 開始の登録の送り先。ふだんは `APIClient`、試験ではモック。
public protocol SessionStartTransport: AnyObject {
    func start(sid: String, startToken: String, devicePubKey: String) async throws -> StartResponse
}

extension APIClient: SessionStartTransport {}

/// 開始の登録が済んだセッション。
public struct StartedSession: Equatable {
    public var sid: String
    public var workId: String
    /// 開始証のバイト列（`ChunkBuilder` の最初の `prev` は、これのハッシュ）。
    public var startCert: Data
    /// 開始証の KMS 署名（DER）。
    public var startSig: Data
}

public enum SessionStartError: Error, Equatable, CustomStringConvertible {
    /// 受付API が返した開始証が、この録画のもの（sid・端末の公開鍵）ではない。
    case certificateMismatch(String)
    /// 応答の base64 や JSON が読めない。
    case badResponse(String)

    public var description: String {
        switch self {
        case .certificateMismatch(let detail): return "開始証がこの録画のものではありません（\(detail)）"
        case .badResponse(let detail): return "開始の応答が読めません（\(detail)）"
        }
    }
}

/// 録画拡張の `broadcastStarted` で、端末の鍵を受付API に登録して開始証を受け取る（tasks/T07_録画拡張_送信.md の1）。
public enum SessionStarter {
    /// 通信エラーと 5xx のときに待つ秒数（3回まで再送する）。
    public static let retryDelays: [TimeInterval] = [1, 2, 4]

    /// 開始証を受け取り、`sessions/{sid}/start.json` に保存する。
    /// - 同じ鍵・同じトークンで再送する（受付API は保存済みの開始証を返すので、応答が失われても続けられる）。
    /// - `TOKEN_INVALID`・`TOKEN_EXPIRED`・`TOKEN_USED` などは再送せずに投げる。
    public static func start(
        session: SessionInfo,
        key: DeviceKey,
        store: AppGroupStore,
        transport: SessionStartTransport,
        retryDelays: [TimeInterval] = SessionStarter.retryDelays,
        sleep: (TimeInterval) async -> Void = { seconds in
            _ = try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
    ) async throws -> StartedSession {
        var attempt = 0
        while true {
            let response: StartResponse
            do {
                response = try await transport.start(
                    sid: session.sid, startToken: session.startToken, devicePubKey: key.publicKeyX963Base64
                )
            } catch let error as APIError where error.isRetryable && attempt < retryDelays.count {
                await sleep(retryDelays[attempt])
                attempt += 1
                continue
            }
            return try save(response, session: session, key: key, store: store)
        }
    }

    /// 開始証がこの録画のものかを確かめてから保存する。
    static func save(
        _ response: StartResponse, session: SessionInfo, key: DeviceKey, store: AppGroupStore
    ) throws -> StartedSession {
        guard let cert = Canonical.fromBase64(response.startCert), let sig = Canonical.fromBase64(response.sig) else {
            throw SessionStartError.badResponse("base64")
        }
        struct Certificate: Decodable { let sid: String; let devicePubKey: String }
        guard let parsed = try? JSONDecoder().decode(Certificate.self, from: cert) else {
            throw SessionStartError.badResponse("startCert の JSON")
        }
        guard parsed.sid == session.sid else {
            throw SessionStartError.certificateMismatch("sid")
        }
        guard parsed.devicePubKey == key.publicKeyX963Base64 else {
            throw SessionStartError.certificateMismatch("devicePubKey")
        }
        try store.prepareSession(session.sid)
        try Canonical.encodeSorted(response).write(to: store.startURL(sid: session.sid), options: .atomic)
        return StartedSession(sid: session.sid, workId: session.workId, startCert: cert, startSig: sig)
    }
}

extension AppGroupStore {
    /// `sessions/{sid}/start.json`（`{"startCert","sig"}`）。
    public func startURL(sid: String) -> URL {
        sessionDirectory(sid).appendingPathComponent("start.json")
    }
}
