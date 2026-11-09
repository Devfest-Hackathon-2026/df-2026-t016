import Foundation
import XCTest
@testable import TraceKit

/// APIClient の試験。通信はせず、URLProtocol で要求を受け止めて決まった応答を返す。
final class APIClientTests: XCTestCase {
    private var client: APIClient!

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        client = APIClient(baseURL: URL(string: "https://api.example.com/")!, session: URLSession(configuration: configuration))
        StubURLProtocol.reset()
    }

    func testHealthz() async throws {
        StubURLProtocol.respond(200, #"{"ok":true}"#)
        let ok = try await client.healthz()
        XCTAssertTrue(ok)
        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "https://api.example.com/v1/healthz")
    }

    func testCreateSessionSendsBearerAndEmptyJSON() async throws {
        StubURLProtocol.respond(201, #"{"expiresAt":"2026-11-06T00:10:00.000Z","sid":"s_A","startToken":"tok"}"#)
        let response = try await client.createSession(workId: "w_X", idToken: "id-token")
        XCTAssertEqual(response, CreateSessionResponse(sid: "s_A", startToken: "tok", expiresAt: "2026-11-06T00:10:00.000Z"))
        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/v1/works/w_X/sessions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer id-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(StubURLProtocol.lastBody.map { String(decoding: $0, as: UTF8.self) }, "{}")
        XCTAssertNil(request.value(forHTTPHeaderField: "X-Firebase-AppCheck"))
    }

    /// 【T12】App Check のトークンがあれば X-Firebase-AppCheck で送る（本文は変えない）
    func testCreateSessionSendsAppCheckToken() async throws {
        StubURLProtocol.respond(201, #"{"expiresAt":"2026-11-06T00:10:00.000Z","sid":"s_A","startToken":"tok"}"#)
        _ = try await client.createSession(workId: "w_X", idToken: "id-token", appCheckToken: "app-check-token")
        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Firebase-AppCheck"), "app-check-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer id-token")
        XCTAssertEqual(StubURLProtocol.lastBody.map { String(decoding: $0, as: UTF8.self) }, "{}")
    }

    /// 【T12】APP_CHECK_FAILED は再送しない（トークンを取り直して準備し直す）
    func testAppCheckFailedIsNotRetried() async throws {
        StubURLProtocol.respond(401, #"{"error":{"code":"APP_CHECK_FAILED","message":"App Check token is required"}}"#)
        do {
            _ = try await client.createSession(workId: "w_X", idToken: "id-token")
            XCTFail("401 を投げるはず")
        } catch let error as APIError {
            XCTAssertEqual(error.code, "APP_CHECK_FAILED")
            XCTAssertEqual(error.deviceAction, .doNotResend)
            XCTAssertTrue(error.userMessage.contains("App Check"))
        }
    }

    func testStartSendsTokenAndPublicKey() async throws {
        StubURLProtocol.respond(200, #"{"sig":"c2ln","startCert":"Y2VydA=="}"#)
        let response = try await client.start(sid: "s_A", startToken: "tok", devicePubKey: "BAAA")
        XCTAssertEqual(response.startCert, "Y2VydA==")
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/v1/sessions/s_A/start")
        XCTAssertEqual(
            StubURLProtocol.lastBody.map { String(decoding: $0, as: UTF8.self) },
            #"{"devicePubKey":"BAAA","startToken":"tok"}"#
        )
        XCTAssertNil(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"))
    }

    func testSendChunkEncodesBase64() async throws {
        StubURLProtocol.respond(200, #"{"receipt":"cmVj","sig":"c2ln"}"#)
        let header = Data(#"{"seq":0}"#.utf8)
        let sig = Data(repeating: 7, count: 64)
        let body = Data(#"{"v":1}"#.utf8)
        let item = QueueItem(seq: 0, header: header, sig: sig, body: body)
        let response = try await client.sendChunk(sid: "s_A", item: item)
        XCTAssertEqual(response, ReceiptResponse(receipt: "cmVj", sig: "c2ln"))
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/v1/sessions/s_A/chunks")

        struct Sent: Decodable { let header: String; let sig: String; let body: String }
        let sent = try JSONDecoder().decode(Sent.self, from: try XCTUnwrap(StubURLProtocol.lastBody))
        XCTAssertEqual(Data(base64Encoded: sent.header), header)
        XCTAssertEqual(Data(base64Encoded: sent.sig), sig)
        XCTAssertEqual(Data(base64Encoded: sent.body), body)
    }

    func testPutImageSendsRawJPEGAndDeviceSig() async throws {
        let sha = String(repeating: "a", count: 64)
        StubURLProtocol.respond(200, #"{"sha256":"\#(sha)"}"#)
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3])
        let signature = Data(repeating: 9, count: 64)
        let response = try await client.putImage(sid: "s_A", sha256: sha, jpeg: jpeg, deviceSig: signature)
        XCTAssertEqual(response.sha256, sha)
        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.url?.path, "/v1/sessions/s_A/images/\(sha)")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "image/jpeg")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Device-Sig"), signature.base64EncodedString())
        XCTAssertEqual(StubURLProtocol.lastBody, jpeg)
    }

    func testPutPNG() async throws {
        StubURLProtocol.respond(200, #"{"height":20,"sha256":"bb","width":10}"#)
        let response = try await client.putPNG(workId: "w_X", png: Data([0x89, 0x50]), idToken: "id-token")
        XCTAssertEqual(response, PNGResponse(sha256: "bb", width: 10, height: 20))
        XCTAssertEqual(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Content-Type"), "image/png")
        XCTAssertEqual(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer id-token")
    }

    func testListWorksDecodesFinalizedFieldsAndBearer() async throws {
        StubURLProtocol.respond(200, #"{"works":[{"workId":"w_X","title":"絵","displayName":"作者","status":"finalized","createdAt":"2026-11-06T00:00:00.000Z","session":null,"png":{"sha256":"bb","width":10,"height":20},"publicId":"p_X","match":{"result":"unverified","score":null,"reason":"終了画面がない"},"explanation":{"text":"補足","included":false,"model":"m"}}]}"#)
        let works = try await client.listWorks(idToken: "id-token")
        XCTAssertEqual(works.count, 1)
        XCTAssertEqual(works[0].png?.width, 10)
        XCTAssertEqual(works[0].match?.title, "未確認")
        XCTAssertEqual(works[0].explanation?.included, false)
        XCTAssertEqual(StubURLProtocol.lastRequest?.httpMethod, "GET")
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/v1/works")
        XCTAssertEqual(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer id-token")
    }

    func testFinalizeSendsPublicationChoiceAndAllowsSlowProcessing() async throws {
        StubURLProtocol.respond(200, #"{"publicId":"p_X","manifest":{"status":"aborted","match":{"result":"unverified","reason":"作者が終了画面を照合に使わないことを選んだ","score":null}},"explanation":null}"#)
        let result = try await client.finalize(workId: "w_X", declarationAccepted: true, useEndImage: false, showWhole: false, idToken: "id-token")
        XCTAssertEqual(result.manifest.status, "aborted")
        XCTAssertEqual(result.manifest.resultStatus, "aborted")
        XCTAssertEqual(StubURLProtocol.lastRequest?.timeoutInterval, 120)
        XCTAssertEqual(result.manifest.match.title, "未確認")
        XCTAssertEqual(StubURLProtocol.lastRequest?.httpMethod, "POST")
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/v1/works/w_X/finalize")
        XCTAssertEqual(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer id-token")
        XCTAssertEqual(StubURLProtocol.lastBody.map { String(decoding: $0, as: UTF8.self) }, #"{"declarationAccepted":true,"showWhole":false,"useEndImage":false}"#)
    }

    /// 【11/8】作者の申告の版2。AI の使い方と詳細を送り、declarationAccepted は送らない
    func testFinalizeSendsDeclarationV2() async throws {
        StubURLProtocol.respond(200, #"{"publicId":"p_X","manifest":{"status":"completed","match":{"result":"match","reason":null,"score":0.9}},"explanation":null}"#)
        _ = try await client.finalize(workId: "w_X", declaration: AuthorDeclarationInput(aiUse: .partial, detail: "背景に使用"),
                                      useEndImage: true, showWhole: true, idToken: "id-token")
        XCTAssertEqual(StubURLProtocol.lastBody.map { String(decoding: $0, as: UTF8.self) },
                       #"{"declaration":{"aiUse":"partial","detail":"背景に使用"},"showWhole":true,"useEndImage":true}"#)
        XCTAssertEqual(AIUse.notUsed.rawValue, "none")
        XCTAssertEqual(AIUse.allCases.map(\.text), ["この作品は AI を使用していません。", "この作品は AI を部分的に使用しています。", "この作品は AI を大部分で使用しています。"])
    }

    /// 【11/8】アカウント（#15・#16）
    func testAccountEndpoints() async throws {
        StubURLProtocol.respond(200, #"{"uid":"u1","displayName":"描き手","createdAt":"2026-11-08T00:00:00.000Z","workCount":2,"workLimit":20}"#)
        let me = try await client.putMe(displayName: "描き手", idToken: "id-token")
        XCTAssertEqual(me.displayName, "描き手")
        XCTAssertEqual(me.workCount, 2)
        XCTAssertEqual(StubURLProtocol.lastRequest?.httpMethod, "PUT")
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/v1/me")
        XCTAssertEqual(StubURLProtocol.lastBody.map { String(decoding: $0, as: UTF8.self) }, #"{"displayName":"描き手"}"#)
        StubURLProtocol.respond(200, #"{"uid":"u1","displayName":null,"createdAt":null,"workCount":0,"workLimit":20}"#)
        let empty = try await client.getMe(idToken: "id-token")
        XCTAssertNil(empty.displayName)
        XCTAssertEqual(StubURLProtocol.lastRequest?.httpMethod, "GET")
    }


    /// 【T14】確定記録 v:2 は記録ごとの結果を持ち、どれかが異常終了なら aborted。作品の詳細は sessions を持つ。
    func testFinalizeV2AndWorkSessions() async throws {
        StubURLProtocol.respond(200, #"{"publicId":"p_X","manifest":{"v":2,"sessions":[{"sid":"s_1","status":"completed"},{"sid":"s_2","status":"aborted"}],"match":{"result":"unverified","reason":"終了画面がない","score":null}},"explanation":null}"#)
        let result = try await client.finalize(workId: "w_X", declarationAccepted: true, useEndImage: true, idToken: "id-token")
        XCTAssertNil(result.manifest.status)
        XCTAssertEqual(result.manifest.sessions?.map(\.sid), ["s_1", "s_2"])
        XCTAssertEqual(result.manifest.resultStatus, "aborted")

        StubURLProtocol.respond(200, #"{"workId":"w_X","title":"絵","displayName":"作者","status":"recorded","createdAt":"2026-11-06T00:00:00.000Z","session":{"sid":"s_2","status":"completed","chunkCount":2,"startedAt":null,"lastReceivedAt":null,"final":true},"sessions":[{"sid":"s_1","status":"completed","chunkCount":5,"startedAt":null,"lastReceivedAt":null,"final":true},{"sid":"s_2","status":"completed","chunkCount":2,"startedAt":null,"lastReceivedAt":null,"final":true},{"sid":"s_3","status":"created","chunkCount":0,"startedAt":null,"lastReceivedAt":null,"final":false}],"png":null,"publicId":null,"match":null,"explanation":null}"#)
        let work = try await client.getWork(workId: "w_X", idToken: "id-token")
        XCTAssertEqual(work.allSessions.map(\.sid), ["s_1", "s_2", "s_3"])
        XCTAssertEqual(work.startedSessions.map(\.sid), ["s_1", "s_2"])
    }
    func testExplanationUsesIncludeRequestAndIncludedResponse() async throws {
        StubURLProtocol.respond(200, #"{"included":false}"#)
        let included = try await client.setExplanation(workId: "w_X", include: false, idToken: "id-token")
        XCTAssertFalse(included)
        XCTAssertEqual(StubURLProtocol.lastRequest?.httpMethod, "PUT")
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/v1/works/w_X/explanation")
        XCTAssertEqual(StubURLProtocol.lastBody.map { String(decoding: $0, as: UTF8.self) }, #"{"include":false}"#)
    }

    // MARK: - エラー

    private func error(of operation: () async throws -> Void) async -> APIError? {
        do {
            try await operation()
            return nil
        } catch let error as APIError {
            return error
        } catch {
            XCTFail("APIError 以外のエラー: \(error)")
            return nil
        }
    }

    func testErrorCodesMapToDeviceActions() async throws {
        let cases: [(Int, String, APIError.DeviceAction)] = [
            (409, "SEQ_GAP", .stopRecording),
            (409, "PREV_MISMATCH", .stopRecording),
            (422, "SIGNATURE_INVALID", .stopRecording),
            (429, "LIMIT_EXCEEDED", .stopRecording),
            (401, "TOKEN_INVALID", .doNotResend),
            (410, "TOKEN_EXPIRED", .doNotResend),
            (400, "BAD_REQUEST", .doNotResend),
            (503, "INTERNAL", .retry),
        ]
        for (status, code, action) in cases {
            StubURLProtocol.respond(status, #"{"error":{"code":"\#(code)","message":"m"}}"#)
            let apiError = await error { _ = try await self.client.healthz() }
            XCTAssertEqual(apiError?.status, status, code)
            XCTAssertEqual(apiError?.code, code)
            XCTAssertEqual(apiError?.deviceAction, action, code)
        }
    }

    func testStillRecordingCarriesRetryAfter() async throws {
        StubURLProtocol.respond(409, #"{"error":{"code":"STILL_RECORDING","message":"wait","retryAfterSec":42}}"#)
        let apiError = await error { _ = try await self.client.healthz() }
        XCTAssertEqual(apiError?.code, "STILL_RECORDING")
        XCTAssertEqual(apiError?.retryAfterSec, 42)
    }

    func testNonJSONErrorAndNetworkError() async throws {
        StubURLProtocol.respond(502, "Bad Gateway")
        let gateway = await error { _ = try await self.client.healthz() }
        XCTAssertEqual(gateway?.code, "HTTP_502")
        XCTAssertEqual(gateway?.deviceAction, .retry)

        StubURLProtocol.fail(URLError(.notConnectedToInternet))
        let network = await error { _ = try await self.client.healthz() }
        XCTAssertEqual(network?.status, 0)
        XCTAssertEqual(network?.code, "NETWORK")
        XCTAssertEqual(network?.isRetryable, true)
    }
}

/// 要求を受け止めて、決まった応答を返す URLProtocol。
final class StubURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var response: (status: Int, body: Data)?
    private static var failure: Error?
    private static var _lastRequest: URLRequest?
    private static var _lastBody: Data?

    static var lastRequest: URLRequest? { lock.withLock { _lastRequest } }
    static var lastBody: Data? { lock.withLock { _lastBody } }

    static func reset() {
        lock.withLock {
            response = nil
            failure = nil
            _lastRequest = nil
            _lastBody = nil
        }
    }

    static func respond(_ status: Int, _ body: String) {
        lock.withLock {
            response = (status, Data(body.utf8))
            failure = nil
        }
    }

    static func fail(_ error: Error) {
        lock.withLock {
            failure = error
            response = nil
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // URLSession は送る本文を httpBodyStream に移すことがあるので、両方を見る
        let body = request.httpBody ?? request.httpBodyStream.map(Self.readAll)
        let (stub, failure) = Self.lock.withLock { () -> ((status: Int, body: Data)?, Error?) in
            Self._lastRequest = request
            Self._lastBody = body
            return (Self.response, Self.failure)
        }
        if let failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        let (status, data) = stub ?? (500, Data())
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func readAll(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
