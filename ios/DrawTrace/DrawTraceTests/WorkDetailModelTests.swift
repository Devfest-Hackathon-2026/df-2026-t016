import Foundation
import TraceKit
import XCTest
@testable import DrawTrace

final class WorkDetailModelTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var store: AppGroupStore!
    private var suite: String!
    private var client: APIClient!

    override func setUpWithError() throws {
        suite = "work-detail-tests-\(UUID())"
        defaults = UserDefaults(suiteName: suite)!
        root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        store = AppGroupStore(defaults: defaults, containerURL: root)
        try store.prepareSession("s_A")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AppAPIStub.self]
        client = APIClient(baseURL: URL(string: "https://test.invalid")!, session: URLSession(configuration: config))
        AppAPIStub.requests = []
        AppAPIStub.respond = { _ in (200, Data()) }
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    private func json(status: String = "recording", png: Bool = true) throws -> Data {
        var value: [String: Any] = [
            "workId": "w_A", "title": "作品", "displayName": "作者", "status": status,
            "createdAt": "2026-11-06T00:00:00.000Z",
            "session": ["sid": "s_A", "status": "recording", "chunkCount": 2, "final": false,
                        "startedAt": "2026-11-06T00:01:00.000Z", "lastReceivedAt": "2026-11-06T00:02:00.000Z"]
        ]
        if png { value["png"] = ["sha256": "aa", "width": 10, "height": 20] }
        if status == "finalized" { value["publicId"] = "p_A" }
        return try JSONSerialization.data(withJSONObject: value)
    }

    @MainActor private func model(status: String = "recording", sent: Bool = false) throws -> WorkDetailModel {
        defaults.set(sent, forKey: "work.sent.s_A")
        let work = try JSONDecoder().decode(WorkDetail.self, from: json(status: status))
        let api = client!
        let library = LibraryModel(store: store, preferences: defaults, connect: { (api, "test-token") })
        return WorkDetailModel(work: work, library: library)
    }

    @MainActor func testFreshExtensionRetainsOwnershipOfSending() async throws {
        try store.setBroadcastStatus(BroadcastStatus(sid: "s_A", state: .finishing))
        let model = try model()
        await model.finishSending()
        XCTAssertFalse(defaults.bool(forKey: "work.sent.s_A"))
        XCTAssertTrue(AppAPIStub.requests.isEmpty)
        XCTAssertTrue(model.progressMessage.contains("録画拡張"))
    }

    @MainActor func testLateQueueItemsInvalidateTheSavedSendingCompletion() throws {
        try Data("{}".utf8).write(to: store.directory(.queue, sid: "s_A").appendingPathComponent("000002.json"))
        let model = try model(status: "recorded", sent: true)
        XCTAssertTrue(model.needsSending)
        XCTAssertEqual(model.phase, .sending)
        XCTAssertFalse(defaults.bool(forKey: "work.sent.s_A"))
    }

    @MainActor func testRegisteredSessionCannotShowAnUnusedRecordButton() throws {
        try store.setSessionCurrent(SessionInfo(sid: "s_A", workId: "w_A", startToken: "token",
                                               apiBaseURL: "https://test.invalid", createdAt: Canonical.timeString()))
        defaults.set(Canonical.timeString(Date().addingTimeInterval(600)), forKey: "work.expiry.s_A")
        try Data("{}".utf8).write(to: store.startURL(sid: "s_A"))
        let model = try model(status: "draft")
        XCTAssertFalse(model.readyToRecord)
        // 録画拡張の状態が無くても、開始した記録は残りを送る画面に出す（【T14】記録の一覧には戻らない）
        XCTAssertEqual(model.phase, .sending)
        XCTAssertEqual(model.startedSids, ["s_A"])
    }

    @MainActor func testSessionPreparationSurvivesTheFollowingReadFailing() async throws {
        AppAPIStub.respond = { request in
            if request.url!.path.hasSuffix("/sessions") {
                return (201, Data("{\"sid\":\"s_B\",\"startToken\":\"token\",\"expiresAt\":\"\(Canonical.timeString(Date().addingTimeInterval(600)))\"}".utf8))
            }
            return (503, Data(#"{"error":{"code":"INTERNAL"}}"#.utf8))
        }
        // 【T14】前の記録（s_A）を送り終えていないと、次の記録は作らない。ここでは送り終えた後
        let model = try model(status: "draft", sent: true)
        await model.prepare()
        XCTAssertEqual(model.sid, "s_B")
        XCTAssertEqual(store.sessionCurrent?.sid, "s_B")
        XCTAssertTrue(model.readyToRecord)
    }

    @MainActor func testWholePublicationChoicePersistsWhenReopening() throws {
        let first = try model(sent: true)
        first.showWhole = false
        let reopened = try model(sent: true)
        XCTAssertFalse(reopened.showWhole)
    }

    @MainActor func testWholePublicationChoiceIsSentWhenFinalizing() async throws {
        var record = WholeRecord()
        record.items = [WholeItem(sha: "whole", frameTime: Canonical.timeString(), rect: [])]
        try store.setWholeRecord(record, sid: "s_A")
        let finalized = try json(status: "finalized")
        AppAPIStub.respond = { request in
            if request.url!.path.hasSuffix("/finalize") {
                return (200, Data(#"{"publicId":"p_A","manifest":{"status":"completed","match":{"result":"match"}}}"#.utf8))
            }
            return (200, finalized)
        }
        let model = try model(sent: true)
        model.beginSubmit()
        model.showWhole = false
        model.aiUse = .notUsed
        await model.finalize()
        let request = try XCTUnwrap(AppAPIStub.requests.first { $0.url!.path.hasSuffix("/finalize") })
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: try XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["showWhole"] as? Bool, false)
        XCTAssertEqual(model.phase, .finalized)
    }

    @MainActor func testMissingLocalStatusCanAdvanceAfterServerRefresh() async throws {
        let response = try json()
        AppAPIStub.respond = { _ in (200, response) }
        let model = try model()
        await model.finishSending()
        XCTAssertTrue(defaults.bool(forKey: "work.sent.s_A"))
        // 【T14】止めた後は記録の一覧に戻り、提出は「提出へ」を押してから
        XCTAssertEqual(model.phase, .ready)
        model.beginSubmit()
        XCTAssertEqual(model.phase, .submit)
    }

    @MainActor func testDeclarationAndEndImageChoiceAreBothRequired() async throws {
        var record = WholeRecord()
        record.end = "end"
        try store.setWholeRecord(record, sid: "s_A")
        try Data([1]).write(to: store.directory(.images, sid: "s_A").appendingPathComponent("end.jpg"))
        let model = try model(sent: true)
        model.beginSubmit()
        await model.finalize()
        XCTAssertTrue(AppAPIStub.requests.isEmpty)
        model.aiUse = .notUsed
        await model.finalize()
        XCTAssertTrue(AppAPIStub.requests.isEmpty)
        XCTAssertFalse(model.busy)
    }

    /// 【11/8】詳細は前後の空白を取って送る。上限（Unicode のスカラー数で400）を超えると確定しない
    @MainActor func testDeclarationDetailIsTrimmedAndLimited() async throws {
        let finalized = try json(status: "finalized")
        AppAPIStub.respond = { request in
            if request.url!.path.hasSuffix("/finalize") {
                return (200, Data(#"{"publicId":"p_A","manifest":{"status":"completed","match":{"result":"match"}},"explanation":null}"#.utf8))
            }
            return (200, finalized)
        }
        let model = try model(sent: true)
        model.beginSubmit()
        model.aiUse = .partial
        model.declarationDetail = String(repeating: "あ", count: 401)
        XCTAssertFalse(model.declarationReady)
        await model.finalize()
        XCTAssertTrue(AppAPIStub.requests.filter { $0.url!.path.hasSuffix("/finalize") }.isEmpty)
        model.declarationDetail = "  背景に使用\n  "
        XCTAssertTrue(model.declarationReady)
        await model.finalize()
        let body = AppAPIStub.requests.filter { $0.url!.path.hasSuffix("/finalize") }.map { String(decoding: $0.httpBody ?? Data(), as: UTF8.self) }
        XCTAssertEqual(body, [#"{"declaration":{"aiUse":"partial","detail":"背景に使用"},"showWhole":true,"useEndImage":true}"#])
    }

    @MainActor func testCannotFinalizeBeforeRemainingRecordsAreSent() async throws {
        let model = try model()
        model.aiUse = .notUsed
        await model.finalize()
        XCTAssertTrue(AppAPIStub.requests.isEmpty)
    }

    @MainActor func testStillRecordingRetriesWithSameEndImageChoice() async throws {
        let finalized = try json(status: "finalized")
        var attempts = 0
        AppAPIStub.respond = { request in
            if request.url!.path.hasSuffix("/finalize") {
                attempts += 1
                if attempts == 1 { return (409, Data(#"{"error":{"code":"STILL_RECORDING","retryAfterSec":1}}"#.utf8)) }
                return (200, Data(#"{"publicId":"p_A","manifest":{"status":"aborted","match":{"result":"unverified","reason":"選択により未確認"}},"explanation":null}"#.utf8))
            }
            return (200, finalized)
        }
        let model = try model(sent: true)
        model.beginSubmit()
        model.aiUse = .notUsed
        model.useEndImage = false
        await model.finalize()
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(model.work.status, "finalized")
        XCTAssertEqual(model.completionStatus, "aborted")
        XCTAssertEqual(model.retrySeconds, 0)
        let bodies = AppAPIStub.requests.filter { $0.url!.path.hasSuffix("/finalize") }.map { String(decoding: $0.httpBody ?? Data(), as: UTF8.self) }
        // 【11/8】作者の申告は版2（AI の使い方と詳細）で送る
        XCTAssertEqual(bodies, Array(repeating: #"{"declaration":{"aiUse":"none","detail":""},"showWhole":true,"useEndImage":false}"#, count: 2))
    }

    @MainActor func testCountdownCancellationStopsAutomaticRetry() async throws {
        AppAPIStub.respond = { _ in (409, Data(#"{"error":{"code":"STILL_RECORDING","retryAfterSec":30}}"#.utf8)) }
        let model = try model(sent: true)
        model.beginSubmit()
        model.aiUse = .notUsed
        let task = Task { await model.finalize() }
        for _ in 0..<20 {
            if model.retrySeconds > 0 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertGreaterThan(model.retrySeconds, 0)
        task.cancel()
        await task.value
        XCTAssertFalse(model.busy)
        XCTAssertEqual(model.retrySeconds, 0)
        XCTAssertEqual(AppAPIStub.requests.count, 1)
    }

    @MainActor func testFinalizingResumesWithoutNewDeclaration() async throws {
        let finalized = try json(status: "finalized")
        AppAPIStub.respond = { request in
            if request.url!.path.hasSuffix("/finalize") {
                return (200, Data(#"{"publicId":"p_A","manifest":{"status":"completed","match":{"result":"match"}},"explanation":null}"#.utf8))
            }
            return (200, finalized)
        }
        let model = try model(status: "finalizing")
        await model.finalize(resuming: true)
        XCTAssertNil(model.aiUse)
        XCTAssertEqual(model.work.status, "finalized")
    }

    @MainActor func testNonPNGIsRejectedBeforeUpload() async throws {
        let model = try model(sent: true)
        model.beginSubmit()
        await model.upload(png: Data([0xFF, 0xD8]))
        XCTAssertTrue(AppAPIStub.requests.isEmpty)
        XCTAssertEqual(model.errorMessage, "PNG形式の画像を選んでください")
    }

    // MARK: - T14 記録が複数

    private func twoRecords(secondStatus: String) throws -> WorkDetail {
        let value: [String: Any] = [
            "workId": "w_A", "title": "作品", "displayName": "作者", "status": "recorded",
            "createdAt": "2026-11-06T00:00:00.000Z",
            "session": ["sid": "s_B", "status": secondStatus, "chunkCount": 1, "final": secondStatus == "completed"],
            "sessions": [
                ["sid": "s_A", "status": "completed", "chunkCount": 2, "final": true,
                 "startedAt": "2026-11-06T00:01:00.000Z", "lastReceivedAt": "2026-11-06T00:30:00.000Z"],
                ["sid": "s_B", "status": secondStatus, "chunkCount": 1, "final": secondStatus == "completed",
                 "startedAt": "2026-11-07T00:01:00.000Z", "lastReceivedAt": "2026-11-07T00:20:00.000Z"]
            ]
        ]
        return try JSONDecoder().decode(WorkDetail.self, from: JSONSerialization.data(withJSONObject: value))
    }

    @MainActor func testCannotAddARecordBeforeThePreviousOneIsSent() async throws {
        let model = try model(status: "recorded", sent: false)
        XCTAssertFalse(model.canAddRecord)
        await model.prepare()
        XCTAssertTrue(AppAPIStub.requests.isEmpty)
        XCTAssertEqual(model.errorMessage, "前の記録の送信が終わっていません。残りを送ってから追加してください")
    }

    @MainActor func testStoppedRecordReturnsToListAndAddsTheNextRecord() async throws {
        AppAPIStub.respond = { request in
            if request.url!.path.hasSuffix("/sessions") {
                return (201, Data("{\"sid\":\"s_B\",\"startToken\":\"token\",\"expiresAt\":\"\(Canonical.timeString(Date().addingTimeInterval(600)))\"}".utf8))
            }
            return (503, Data(#"{"error":{"code":"INTERNAL"}}"#.utf8))
        }
        let model = try model(status: "recorded", sent: true)
        XCTAssertEqual(model.phase, .ready)
        XCTAssertTrue(model.canAddRecord)
        XCTAssertEqual(model.summaries.map(\.sid), ["s_A"])
        await model.prepare()
        XCTAssertEqual(model.sid, "s_B")
        XCTAssertTrue(model.readyToRecord)
        XCTAssertEqual(model.work.allSessions.map(\.sid), ["s_A", "s_B"])
        XCTAssertEqual(model.summaries.map(\.sid), ["s_A"])  // 未開始の記録は一覧に出さない
        XCTAssertEqual(model.phase, .ready)
    }

    @MainActor func testSubmitWaitsUntilEveryRecordIsSent() throws {
        defaults.set(true, forKey: "work.sent.s_A")
        try store.prepareSession("s_B")
        let api = client!
        let library = LibraryModel(store: store, preferences: defaults, connect: { (api, "test-token") })
        let model = WorkDetailModel(work: try twoRecords(secondStatus: "completed"), library: library)
        XCTAssertEqual(model.startedSids, ["s_A", "s_B"])
        XCTAssertEqual(model.phase, .sending)
        XCTAssertFalse(model.canSubmit)
        XCTAssertFalse(model.canAddRecord)
        defaults.set(true, forKey: "work.sent.s_B")
        model.refreshLocal()
        XCTAssertEqual(model.phase, .ready)
        XCTAssertTrue(model.canSubmit)
        model.beginSubmit()
        XCTAssertEqual(model.phase, .submit)
        model.endSubmit()
        XCTAssertEqual(model.phase, .ready)
    }

    @MainActor func testEndImageAndPublishedImagesSpanAllRecords() throws {
        defaults.set(true, forKey: "work.sent.s_A")
        defaults.set(true, forKey: "work.sent.s_B")
        try store.prepareSession("s_B")
        var first = WholeRecord()
        first.items = [WholeItem(sha: "a", frameTime: "2026-11-06T00:10:00.000Z", rect: [])]
        first.end = "a"
        try store.setWholeRecord(first, sid: "s_A")
        var second = WholeRecord()
        second.items = [WholeItem(sha: "b", frameTime: "2026-11-07T00:10:00.000Z", rect: [])]
        second.end = "b"
        try store.setWholeRecord(second, sid: "s_B")
        try Data([1]).write(to: store.directory(.images, sid: "s_B").appendingPathComponent("b.jpg"))
        let api = client!
        let library = LibraryModel(store: store, preferences: defaults, connect: { (api, "test-token") })
        let model = WorkDetailModel(work: try twoRecords(secondStatus: "completed"), library: library)
        XCTAssertEqual(model.wholeImages.map(\.item.sha), ["a", "b"])
        XCTAssertEqual(model.wholeImages.map(\.summary.index), [0, 1])
        XCTAssertEqual(model.endImageURL?.lastPathComponent, "b.jpg")  // 最後の記録の終了画像
        XCTAssertEqual(model.days.count, 2)
    }

    @MainActor func testDeletingAnOldWorkKeepsAnotherCurrentSession() async throws {
        try store.prepareSession("s_B")
        try store.setSessionCurrent(SessionInfo(sid: "s_B", workId: "w_B", startToken: "token", apiBaseURL: "", createdAt: Canonical.timeString()))
        try store.setBroadcastStatus(BroadcastStatus(sid: "s_B", state: .recording))
        AppAPIStub.respond = { _ in (204, Data()) }
        let model = try model(status: "recorded")
        let deleted = await model.delete()
        XCTAssertTrue(deleted)
        XCTAssertEqual(store.sessionCurrent?.sid, "s_B")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.sessionDirectory("s_B").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.sessionDirectory("s_A").path))
    }
}

private final class AppAPIStub: URLProtocol {
    static var requests: [URLRequest] = []
    static var respond: (URLRequest) -> (Int, Data) = { _ in (200, Data()) }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var captured = request
        if let stream = captured.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            captured.httpBody = data
        }
        Self.requests.append(captured)
        let (status, data) = Self.respond(captured)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
