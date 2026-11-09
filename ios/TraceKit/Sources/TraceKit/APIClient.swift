import Foundation

// 受付API の呼び出し（tasks/00_共通仕様.md の5章）。
// ID トークンは呼ぶ側（本体アプリ）から渡す。TraceKit は Firebase に依存しない。

/// `POST /v1/works/{workId}/sessions`（#5）の応答。
public struct CreateSessionResponse: Codable, Equatable {
    public var sid: String
    public var startToken: String
    public var expiresAt: String
}

/// `POST /v1/sessions/{sid}/start`（#6）の応答。`startCert` は開始証のバイト列（base64）、`sig` は KMS の DER 署名（base64）。
public struct StartResponse: Codable, Equatable {
    public var startCert: String
    public var sig: String
}

/// `POST /v1/sessions/{sid}/chunks`（#7）の応答。`receipt` は受領証のバイト列（base64）、`sig` は KMS の DER 署名（base64）。
public struct ReceiptResponse: Codable, Equatable {
    public var receipt: String
    public var sig: String
}

/// `PUT /v1/sessions/{sid}/images/{sha256}`（#8）の応答。
public struct ImageResponse: Codable, Equatable {
    public var sha256: String
}

/// `PUT /v1/works/{workId}/png`（#9）の応答。
public struct PNGResponse: Codable, Equatable {
    public var sha256: String
    public var width: Int
    public var height: Int
}

/// 作品の詳細（#2〜#4 の応答。共通仕様5章）。本体アプリが使う項目だけを読む（ほかの項目は無視する）。
public struct WorkDetail: Codable, Equatable {
    public struct Session: Codable, Equatable {
        public var sid: String
        public var status: String
        public var chunkCount: Int
        public var startedAt: String?
        public var lastReceivedAt: String?
        public var `final`: Bool

        public init(sid: String, status: String, chunkCount: Int = 0, startedAt: String? = nil,
                    lastReceivedAt: String? = nil, final: Bool = false) {
            self.sid = sid
            self.status = status
            self.chunkCount = chunkCount
            self.startedAt = startedAt
            self.lastReceivedAt = lastReceivedAt
            self.final = final
        }
    }

    public var workId: String
    public var title: String
    public var displayName: String
    /// `draft`・`recording`・`recorded`・`finalizing`・`finalized`
    public var status: String
    /// いちばん新しい記録（セッション）。
    public var session: Session?
    /// 【T14】作品のすべての記録（作った順）。T14 より前の受付API では返らないので、`allSessions` を使う。
    public var sessions: [Session]?
    public var png: PNGResponse?
    public var publicId: String?
    public var match: AppearanceMatch?
    public var explanation: WorkExplanation?
    public var createdAt: String
}

extension WorkDetail {
    /// すべての記録（作った順）。`sessions` が無い応答では `session` だけ。
    public var allSessions: [Session] {
        if let sessions { return sessions }
        return session.map { [$0] } ?? []
    }

    /// 開始した記録（未開始の `created` を除く）。
    public var startedSessions: [Session] { allSessions.filter { $0.status != "created" } }
}

public struct AppearanceMatch: Codable, Equatable {
    public var result: String
    public var score: Double?
    public var reason: String?

    public var title: String {
        switch result {
        case "match": return "一致"
        case "mismatch": return "不一致"
        default: return "未確認"
        }
    }
}

public struct WorkExplanation: Codable, Equatable {
    public var text: String
    public var included: Bool
}

public struct FinalizeResponse: Decodable, Equatable {
    public struct Manifest: Decodable, Equatable {
        public struct SessionResult: Decodable, Equatable {
            public var sid: String
            public var status: String
        }
        /// 確定記録 v:1 の結果（`completed`・`aborted`）。v:2 では nil。
        public var status: String?
        /// 【T14】確定記録 v:2 の記録ごとの結果。
        public var sessions: [SessionResult]?
        public var match: AppearanceMatch

        /// すべての記録が正常終了なら `completed`、どれかが異常終了なら `aborted`（v:1・v:2 のどちらでも）。
        public var resultStatus: String {
            if let sessions, !sessions.isEmpty {
                return sessions.allSatisfy { $0.status == "completed" } ? "completed" : "aborted"
            }
            return status ?? "completed"
        }
    }
    public var publicId: String
    public var manifest: Manifest
    public var explanation: WorkExplanation?
}

public enum AuthorDeclaration {
    /// 版1の文言（前の版のアプリの確定・確定の途中からの再開で使う）
    public static let text = "この作品は手描きで制作しました（AI による生成・補助は使っていません）。"
    /// 【11/8】版2の詳細の上限（受付API と同じ）
    public static let maxDetail = 400
}

/// 【11/8】作者の申告の版2: AI の使い方（受付API の `aiUse`）。
public enum AIUse: String, Codable, CaseIterable, Identifiable, Sendable {
    case notUsed = "none"
    case partial
    case major

    public var id: String { rawValue }

    /// 選ぶときの短いラベル
    public var label: String {
        switch self {
        case .notUsed: return "使用していません"
        case .partial: return "部分的に使用"
        case .major: return "大部分で使用"
        }
    }

    /// 確定記録に入る文言（受付API の DECLARATION_TEXTS と同じ）
    public var text: String {
        switch self {
        case .notUsed: return "この作品は AI を使用していません。"
        case .partial: return "この作品は AI を部分的に使用しています。"
        case .major: return "この作品は AI を大部分で使用しています。"
        }
    }
}

/// 【11/8】確定のときに送る作者の申告（版2）。`detail` は任意（空でもよい、400字まで）。
public struct AuthorDeclarationInput: Encodable, Equatable, Sendable {
    public var aiUse: AIUse
    public var detail: String

    public init(aiUse: AIUse, detail: String = "") {
        self.aiUse = aiUse
        self.detail = detail
    }
}

/// 【11/8】`GET /v1/me`・`PUT /v1/me` の応答（アカウント。ID は Firebase の uid）。
public struct AccountInfo: Decodable, Equatable, Sendable {
    public var uid: String
    public var displayName: String?
    public var createdAt: String?
    public var workCount: Int
    public var workLimit: Int
}

/// 本文の無い応答（`204`）。
public struct NoContent: Decodable, Equatable {
    public init() {}
}

/// 受付API のエラー。通信エラーは `status == 0`、`code == "NETWORK"`。
public struct APIError: Error, Equatable, CustomStringConvertible {
    /// 端末の扱い（共通仕様5章のエラーコードの表）。
    public enum DeviceAction: Equatable {
        /// 間隔を広げながら再送する（通信エラーと 5xx）
        case retry
        /// 録画を止める
        case stopRecording
        /// 再送しない
        case doNotResend
    }

    public let status: Int
    public let code: String
    public let message: String
    /// `STILL_RECORDING` のときだけ入る。
    public let retryAfterSec: Int?

    public init(status: Int, code: String, message: String, retryAfterSec: Int? = nil) {
        self.status = status
        self.code = code
        self.message = message
        self.retryAfterSec = retryAfterSec
    }

    static let stopRecordingCodes: Set<String> = [
        "SEQ_CONFLICT", "SEQ_GAP", "PREV_MISMATCH", "SESSION_CLOSED",
        "SIGNATURE_INVALID", "HASH_MISMATCH", "LIMIT_EXCEEDED",
    ]

    public var deviceAction: DeviceAction {
        if status == 0 || status >= 500 { return .retry }
        if Self.stopRecordingCodes.contains(code) { return .stopRecording }
        return .doNotResend
    }

    public var isRetryable: Bool { deviceAction == .retry }

    public var description: String {
        status == 0 ? "通信エラー: \(message)" : "\(status) \(code): \(message)"
    }

    /// 本体アプリの表示用。サーバの内部メッセージは画面にそのまま出さない。
    public var userMessage: String {
        if status == 0 || status >= 500 { return "通信できませんでした。もう一度お試しください" }
        switch code {
        case "CONFIG": return "受付APIの接続先が設定されていません。Developerタブで確認してください"
        case "DECLARATION_REQUIRED": return "作者の申告で、AI の使い方を選んでください"
        case "UNAUTHENTICATED": return "ログインできませんでした。もう一度お試しください"
        case "APP_CHECK_FAILED": return "アプリを確認できませんでした（App Check）。もう一度準備してください"
        case "FORBIDDEN": return "この作品を開く権限がありません"
        case "NOT_FOUND": return "作品が見つからないか、削除されました"
        case "SESSION_EXISTS": return "録画中の記録があります。録画を止めて、少し待ってから追加してください"
        case "TOKEN_INVALID", "TOKEN_EXPIRED", "TOKEN_USED": return "録画の準備をし直してください"
        case "STILL_RECORDING": return "最後の記録を待っています"
        case "ALREADY_FINALIZED", "SESSION_CLOSED": return "提出（確定）が始まっています。作品を開き直してください"
        case "TOO_LARGE": return "ファイルが大きすぎます。PNG は30MB以下で選んでください"
        case "UNSUPPORTED_MEDIA": return "PNG形式の画像を選んでください"
        case "LIMIT_EXCEEDED": return "受付の上限に達しました（作品は20まで、1つの作品の記録は30回まで）。不要な試験用の作品を削除してください"
        case "BAD_RESPONSE": return "応答を読み取れませんでした。もう一度お試しください"
        case "SEQ_CONFLICT", "SEQ_GAP", "PREV_MISMATCH", "SIGNATURE_INVALID", "HASH_MISMATCH", "RECEIPT_MISMATCH":
            return "記録を送れませんでした。Developerタブで状態を確認してください"
        default: return "処理を完了できませんでした（\(code)）。もう一度お試しください"
        }
    }
}

public final class APIClient {
    public let baseURL: URL
    private let session: URLSession

    /// `baseURL` は Cloud Run の URL。
    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    // MARK: - API

    /// #1 `GET /v1/healthz`
    public func healthz() async throws -> Bool {
        struct Health: Decodable { let ok: Bool }
        let response: Health = try await send("GET", "/v1/healthz")
        return response.ok
    }

    /// #2 `POST /v1/works`
    public func createWork(title: String, displayName: String, idToken: String) async throws -> WorkDetail {
        struct Request: Encodable { let title: String; let displayName: String }
        return try await send("POST", "/v1/works", json: Request(title: title, displayName: displayName), idToken: idToken)
    }

    /// #3 `GET /v1/works`
    public func listWorks(idToken: String) async throws -> [WorkDetail] {
        struct Response: Decodable { let works: [WorkDetail] }
        let response: Response = try await send("GET", "/v1/works", idToken: idToken)
        return response.works
    }

    /// #4 `GET /v1/works/{workId}`
    public func getWork(workId: String, idToken: String) async throws -> WorkDetail {
        try await send("GET", "/v1/works/\(workId)", idToken: idToken)
    }

    /// #12 `DELETE /v1/works/{workId}`（作品のデータをすべて消す）
    public func deleteWork(workId: String, idToken: String) async throws {
        let _: NoContent = try await send("DELETE", "/v1/works/\(workId)", idToken: idToken)
    }

    /// #5 `POST /v1/works/{workId}/sessions`
    /// 【T12】`appCheckToken` は Firebase App Check の使い切りのトークン。あれば `X-Firebase-AppCheck` で送る。
    public func createSession(workId: String, idToken: String, appCheckToken: String? = nil) async throws -> CreateSessionResponse {
        try await send("POST", "/v1/works/\(workId)/sessions", json: EmptyJSON(), idToken: idToken,
                       headers: appCheckToken.map { ["X-Firebase-AppCheck": $0] } ?? [:])
    }

    /// #6 `POST /v1/sessions/{sid}/start`。同じトークン・同じ公開鍵で再送すると、保存済みの開始証が返る。
    public func start(sid: String, startToken: String, devicePubKey: String) async throws -> StartResponse {
        struct Request: Encodable { let startToken: String; let devicePubKey: String }
        return try await send(
            "POST", "/v1/sessions/\(sid)/start",
            json: Request(startToken: startToken, devicePubKey: devicePubKey)
        )
    }

    /// #7 `POST /v1/sessions/{sid}/chunks`。`header`・`body` は送るバイト列そのもの、`sig` は r‖s。
    public func sendChunk(sid: String, header: Data, sig: Data, body: Data) async throws -> ReceiptResponse {
        struct Request: Encodable { let header: String; let sig: String; let body: String }
        return try await send(
            "POST", "/v1/sessions/\(sid)/chunks",
            json: Request(header: Canonical.base64(header), sig: Canonical.base64(sig), body: Canonical.base64(body))
        )
    }

    /// `QueueItem`（App Group の送信待ち）をそのまま送る。
    public func sendChunk(sid: String, item: QueueItem) async throws -> ReceiptResponse {
        guard
            let header = Canonical.fromBase64(item.header),
            let sig = Canonical.fromBase64(item.sig),
            let body = Canonical.fromBase64(item.body)
        else {
            throw APIError(status: 0, code: "BAD_QUEUE_ITEM", message: "送信待ちのチャンクの base64 が読めない")
        }
        return try await sendChunk(sid: sid, header: header, sig: sig, body: body)
    }

    /// #8 `PUT /v1/sessions/{sid}/images/{sha256}`。`deviceSig` は `image:{sid}:{sha256}` への r‖s 署名。
    public func putImage(sid: String, sha256: String, jpeg: Data, deviceSig: Data) async throws -> ImageResponse {
        try await send(
            "PUT", "/v1/sessions/\(sid)/images/\(sha256)",
            body: jpeg, contentType: "image/jpeg",
            headers: ["X-Device-Sig": Canonical.base64(deviceSig)]
        )
    }

    /// #9 `PUT /v1/works/{workId}/png`
    public func putPNG(workId: String, png: Data, idToken: String) async throws -> PNGResponse {
        try await send("PUT", "/v1/works/\(workId)/png", body: png, contentType: "image/png", idToken: idToken)
    }

    /// #10（【11/8】作者の申告の版2）。AI の使い方と詳細を送る。`declarationAccepted` は送らない
    /// （古い受付API に送っても版1の文言で確定されないよう、DECLARATION_REQUIRED で止まる形にする）。
    public func finalize(workId: String, declaration: AuthorDeclarationInput, useEndImage: Bool, showWhole: Bool = true, idToken: String) async throws -> FinalizeResponse {
        struct Request: Encodable { let declaration: AuthorDeclarationInput; let useEndImage: Bool; let showWhole: Bool }
        return try await send("POST", "/v1/works/\(workId)/finalize",
                              json: Request(declaration: declaration, useEndImage: useEndImage, showWhole: showWhole), idToken: idToken,
                              timeout: 120)
    }

    /// 【11/8】#15 `GET /v1/me`
    public func getMe(idToken: String) async throws -> AccountInfo {
        try await send("GET", "/v1/me", idToken: idToken)
    }

    /// 【11/8】#16 `PUT /v1/me`（アカウントを作るか、表示名を変える）
    @discardableResult
    public func putMe(displayName: String, idToken: String) async throws -> AccountInfo {
        struct Request: Encodable { let displayName: String }
        return try await send("PUT", "/v1/me", json: Request(displayName: displayName), idToken: idToken)
    }

    /// #10（版1）。途中の全体画像の公開設定も、確定時に保存する。【11/8】確定の途中からの再開（申告は固定済み）で使う。
    public func finalize(workId: String, declarationAccepted: Bool, useEndImage: Bool, showWhole: Bool = true, idToken: String) async throws -> FinalizeResponse {
        struct Request: Encodable { let declarationAccepted: Bool; let useEndImage: Bool; let showWhole: Bool }
        return try await send("POST", "/v1/works/\(workId)/finalize",
                              json: Request(declarationAccepted: declarationAccepted, useEndImage: useEndImage, showWhole: showWhole), idToken: idToken,
                              timeout: 120)
    }

    /// #11
    @discardableResult
    public func setExplanation(workId: String, include: Bool, idToken: String) async throws -> Bool {
        struct Request: Encodable { let include: Bool }
        struct Response: Decodable { let included: Bool }
        let response: Response = try await send("PUT", "/v1/works/\(workId)/explanation", json: Request(include: include), idToken: idToken)
        return response.included
    }

    // MARK: - 送受信

    private struct EmptyJSON: Encodable {}

    private struct ErrorEnvelope: Decodable {
        struct Detail: Decodable {
            let code: String
            let message: String?
            let retryAfterSec: Int?
        }
        let error: Detail
    }

    private func send<Response: Decodable, Body: Encodable>(
        _ method: String, _ path: String, json: Body, idToken: String? = nil,
        headers: [String: String] = [:], timeout: TimeInterval = 30
    ) async throws -> Response {
        let data = try Canonical.encodeSorted(json)
        return try await send(method, path, body: data, contentType: "application/json", idToken: idToken,
                              headers: headers, timeout: timeout)
    }

    private func send<Response: Decodable>(
        _ method: String, _ path: String,
        body: Data? = nil, contentType: String? = nil,
        idToken: String? = nil, headers: [String: String] = [:], timeout: TimeInterval = 30
    ) async throws -> Response {
        var base = baseURL.absoluteString
        while base.hasSuffix("/") { base.removeLast() }
        guard let url = URL(string: base + path) else {
            throw APIError(status: 0, code: "BAD_URL", message: base + path)
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        if let idToken { request.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization") }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = body

        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: request)
        } catch {
            throw APIError(status: 0, code: "NETWORK", message: error.localizedDescription)
        }
        let (data, response) = result
        guard let http = response as? HTTPURLResponse else {
            throw APIError(status: 0, code: "NETWORK", message: "HTTP の応答ではない")
        }
        if (200..<300).contains(http.statusCode) {
            if data.isEmpty, let none = NoContent() as? Response {
                return none
            }
            do {
                return try JSONDecoder().decode(Response.self, from: data)
            } catch {
                throw APIError(status: http.statusCode, code: "BAD_RESPONSE", message: "応答の JSON が読めない: \(error)")
            }
        }
        if let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data) {
            throw APIError(
                status: http.statusCode,
                code: envelope.error.code,
                message: envelope.error.message ?? "",
                retryAfterSec: envelope.error.retryAfterSec
            )
        }
        let text = String(decoding: data.prefix(200), as: UTF8.self)
        throw APIError(status: http.statusCode, code: "HTTP_\(http.statusCode)", message: text)
    }
}
