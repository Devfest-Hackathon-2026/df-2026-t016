import Foundation
import XCTest
@testable import TraceKit

/// T07: チャンクの作成（`ChunkBuilder`）・送信（`ChunkSender`）・開始の登録（`SessionStarter`）の試験。
/// 受付API はモック（`MockTransport`）にする。
final class ChunkTests: XCTestCase {
    private let sid = "s_AAAAAAAAAAAAAAAA"
    private let t0 = Date(timeIntervalSince1970: 1_793_000_000)
    private lazy var startCert = Data(#"{"sid":"\#(sid)","type":"start","v":1}"#.utf8)

    // MARK: - ChunkBuilder

    func testWholeImagesAreOrderedAndFinalImageIsIncluded() throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        let builder = try makeBuilder(store: store, count: 0)
        let images = ["a", "b", "c"].map { String(repeating: $0, count: 64) }
        builder.noteStartImage(images[0])
        images.forEach { builder.noteWholeImage($0) }
        try builder.finish(drained(editorMs: 1000, activeMs: 500), now: t0.addingTimeInterval(5),
                           fps: 2, memMB: 30, degraded: false, end: images[2])
        let headers = try ChunkSender.queueFiles(store: store, sid: sid).map {
            try header(of: JSONDecoder().decode(QueueItem.self, from: Data(contentsOf: $0)))
        }
        XCTAssertEqual(headers.map { $0.images?.whole }, images)
        XCTAssertEqual(headers.map(\.final), [false, false, true])
        XCTAssertEqual(headers.first?.images?.start, images[0])
        XCTAssertEqual(headers.last?.images?.end, images[2])
        XCTAssertEqual(headers.reduce(0) { $0 + ($1.stats.editorMs ?? 0) }, 1000)
        XCTAssertEqual(headers.reduce(0) { $0 + ($1.stats.activeMs ?? 0) }, 500)
    }

    func testFinalWholeUsesLatestEvenWithinSixtySecondsAndDoesNotRepeatSentImage() throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        let builder = try makeBuilder(store: store, count: 0)
        let first = String(repeating: "a", count: 64)
        let end = String(repeating: "b", count: 64)
        builder.noteWholeImage(first)
        _ = try builder.append(drained(), now: t0.addingTimeInterval(5), fps: 2, memMB: 30, degraded: false)
        try builder.finish(drained(), now: t0.addingTimeInterval(10), fps: 2, memMB: 30, degraded: false, end: end)
        let final = try header(of: JSONDecoder().decode(QueueItem.self, from: Data(contentsOf: builder.queueURL(1))))
        XCTAssertEqual(final.images?.whole, end)
        XCTAssertEqual(final.images?.end, end)

        let another = try ChunkBuilder(sid: "s_other", store: store, signer: testKey(), startCert: startCert, recordingStartedAt: t0)
        another.noteWholeImage(first)
        _ = try another.append(drained(), now: t0, fps: 2, memMB: 30, degraded: false)
        try another.finish(drained(), now: t0, fps: 2, memMB: 30, degraded: false, end: first)
        let same = try header(of: JSONDecoder().decode(QueueItem.self, from: Data(contentsOf: another.queueURL(1))))
        XCTAssertNil(same.images?.whole)
        XCTAssertEqual(same.images?.end, first)
    }

    func testThreeChunksChainPrevAndVerify() throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        let key = try testKey()
        let builder = try ChunkBuilder(sid: sid, store: store, signer: key, startCert: startCert, recordingStartedAt: t0)
        let items = try (1...3).map { index in
            try builder.append(
                drained(tiles: [index], editorMs: 5000, activeMs: 1500),
                now: t0.addingTimeInterval(Double(index) * 5), fps: 2, memMB: 31, degraded: false
            )
        }

        XCTAssertEqual(
            ChunkSender.queueFiles(store: store, sid: sid).map(\.lastPathComponent),
            ["000000.json", "000001.json", "000002.json"]
        )
        var prev = Canonical.sha256Hex(startCert)
        for (index, item) in items.enumerated() {
            let headerBytes = try XCTUnwrap(Canonical.fromBase64(item.header))
            let header = try JSONDecoder().decode(ChunkHeader.self, from: headerBytes)
            XCTAssertEqual(header.seq, index)
            XCTAssertEqual(item.seq, index)
            XCTAssertEqual(header.sid, sid)
            XCTAssertEqual(header.prev, prev, "seq \(index) の prev")
            XCTAssertTrue(DeviceKey.verifyRS(
                publicKeyX963: key.publicKeyX963,
                signature: try XCTUnwrap(Canonical.fromBase64(item.sig)),
                data: headerBytes
            ))
            let body = try XCTUnwrap(Canonical.fromBase64(item.body))
            XCTAssertEqual(header.body, Canonical.sha256Hex(body))
            XCTAssertEqual(header.bodyLen, body.count)
            let decodedBody = try JSONDecoder().decode(ChunkBody.self, from: body)
            XCTAssertEqual(decodedBody.frames, [1])
            XCTAssertEqual(TileBitmap.indices(try XCTUnwrap(Canonical.fromBase64(decodedBody.tiles))), [index + 1])
            XCTAssertEqual(header.stats, ChunkStats(
                fps: 2, changedTiles: 1, resend: false, memMB: 31, degraded: false, editorMs: 5000, activeMs: 1500
            ))
            XCTAssertFalse(header.final)
            XCTAssertNil(header.images)
            XCTAssertEqual(header.tStart, Canonical.timeString(t0.addingTimeInterval(Double(index) * 5)))
            XCTAssertEqual(header.tEnd, Canonical.timeString(t0.addingTimeInterval(Double(index + 1) * 5)))
            // キューのファイルは、返した値と同じ
            let onDisk = try JSONDecoder().decode(QueueItem.self, from: Data(contentsOf: builder.queueURL(index)))
            XCTAssertEqual(onDisk, item)
            // ヘッダの JSON: キーが並び、images は無ければ出さない
            let text = String(decoding: headerBytes, as: UTF8.self)
            XCTAssertTrue(text.hasPrefix(#"{"body":"#), text)
            XCTAssertFalse(text.contains("images"), text)
            XCTAssertTrue(text.contains(#""editorMs":5000"#), text)
            prev = Canonical.sha256Hex(headerBytes)
        }
        XCTAssertEqual(builder.prevHash, prev)
        XCTAssertEqual(builder.seq, 3)
    }

    func testStartImageGoesInOnceAndEndInFinal() throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        let builder = try ChunkBuilder(
            sid: sid, store: store, signer: try testKey(), startCert: startCert, recordingStartedAt: t0
        )
        let start = String(repeating: "a", count: 64)
        let end = String(repeating: "c", count: 64)
        builder.noteStartImage(start)
        builder.noteStartImage(String(repeating: "b", count: 64))  // 2回目は無視する
        let first = try header(of: builder.append(drained(), now: t0.addingTimeInterval(5), fps: 2, memMB: 30, degraded: false))
        let second = try header(of: builder.append(drained(), now: t0.addingTimeInterval(10), fps: 2, memMB: 30, degraded: false))
        let last = try header(of: builder.append(
            drained(), now: t0.addingTimeInterval(12), fps: 1, memMB: 30, degraded: true, end: end, final: true
        ))
        XCTAssertEqual(first.images, ChunkImages(start: start))
        XCTAssertNil(second.images)
        XCTAssertEqual(last.images, ChunkImages(end: end))
        XCTAssertTrue(last.final)
        XCTAssertTrue(last.stats.degraded)
        XCTAssertEqual(last.stats.fps, 1)
        XCTAssertTrue(builder.finalBuilt)
        XCTAssertThrowsError(try builder.append(drained(), now: t0.addingTimeInterval(15), fps: 2, memMB: 30, degraded: false)) {
            XCTAssertEqual($0 as? ChunkBuilder.BuildError, .finalAlreadyBuilt)
        }
    }

    func testStartAndEndCanShareTheFinalChunk() throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        let builder = try ChunkBuilder(
            sid: sid, store: store, signer: try testKey(), startCert: startCert, recordingStartedAt: t0
        )
        let sha = String(repeating: "d", count: 64)
        builder.noteStartImage(sha)
        let last = try header(of: builder.append(
            drained(), now: t0.addingTimeInterval(3), fps: 2, memMB: 30, degraded: false, end: sha, final: true
        ))
        XCTAssertEqual(last.images, ChunkImages(start: sha, end: sha))
    }

    func testTimeNeverGoesBackwards() throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        let builder = try ChunkBuilder(
            sid: sid, store: store, signer: try testKey(), startCert: startCert, recordingStartedAt: t0
        )
        _ = try builder.append(drained(), now: t0.addingTimeInterval(5), fps: 2, memMB: 30, degraded: false)
        // 端末の時計が戻っても、tStart ≤ tEnd を保つ
        let back = try header(of: builder.append(drained(), now: t0.addingTimeInterval(2), fps: 2, memMB: 30, degraded: false))
        XCTAssertEqual(back.tStart, Canonical.timeString(t0.addingTimeInterval(5)))
        XCTAssertEqual(back.tEnd, Canonical.timeString(t0.addingTimeInterval(5)))
    }

    func testQueueLimit() throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        let builder = try ChunkBuilder(
            sid: sid, store: store, signer: try testKey(), startCert: startCert, recordingStartedAt: t0, maxChunks: 2
        )
        _ = try builder.append(drained(), now: t0.addingTimeInterval(5), fps: 2, memMB: 30, degraded: false)
        _ = try builder.append(drained(), now: t0.addingTimeInterval(10), fps: 2, memMB: 30, degraded: false)
        XCTAssertThrowsError(try builder.append(drained(), now: t0.addingTimeInterval(15), fps: 2, memMB: 30, degraded: false)) {
            XCTAssertEqual($0 as? ChunkBuilder.BuildError, .queueFull(2))
        }
        XCTAssertEqual(ChunkSender.queueFiles(store: store, sid: sid).count, 2)
        XCTAssertEqual(ChunkBuilder.maxChunks, 5000)
    }

    // MARK: - ChunkSender

    func testSenderSendsImagesFirstThenChunksInOrder() async throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        let builder = try makeBuilder(store: store, count: 3)
        let image = try writeImage(store: store, bytes: Data([0xFF, 0xD8, 1, 2, 3]))
        let mock = MockTransport()
        let sender = ChunkSender(store: store, sid: sid, transport: mock)
        XCTAssertEqual(sender.sentSeq, -1)
        XCTAssertEqual(sender.queuedCount, 3)
        XCTAssertEqual(sender.pendingImageCount, 1)

        let result = await sender.sendPass()
        XCTAssertEqual(result, .drained)
        XCTAssertEqual(mock.calls, ["image:\(image.sha)", "chunk:0", "chunk:1", "chunk:2"])
        XCTAssertEqual(mock.sentImages.first?.jpeg, image.bytes)
        XCTAssertEqual(mock.sentImages.first?.sig, image.sig)
        XCTAssertEqual(sender.sentSeq, 2)
        XCTAssertTrue(sender.isDrained)
        XCTAssertEqual(builder.seq, 3)
        // 受領証の控え。画像は印だけを外し、JPEG と署名は残す
        XCTAssertEqual(ChunkSender.lastReceiptSeq(store: store, sid: sid), 2)
        let saved = try JSONDecoder().decode(
            ReceiptResponse.self, from: Data(contentsOf: ChunkSender.receiptURL(store: store, sid: sid, seq: 1))
        )
        XCTAssertEqual(saved, MockTransport.receipt(sid: sid, item: mock.sentChunks[1]))
        let folder = store.directory(.images, sid: sid)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(image.sha).jpg").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(image.sha).sig").path))
        // 新しく作った送信も、控えから続きの seq を知る
        XCTAssertEqual(ChunkSender(store: store, sid: sid, transport: mock).sentSeq, 2)
    }

    func testNetworkErrorsResendTheSameBytes() async throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        _ = try makeBuilder(store: store, count: 1)
        let mock = MockTransport()
        mock.chunkSteps = [
            APIError(status: 0, code: "NETWORK", message: "offline"),
            APIError(status: 503, code: "INTERNAL", message: "busy"),
            nil,
        ]
        let sender = ChunkSender(store: store, sid: sid, transport: mock)

        guard case .retryLater(let first) = await sender.sendPass() else { return XCTFail("1回目は再送待ち") }
        XCTAssertEqual(first.code, "NETWORK")
        XCTAssertEqual(sender.consecutiveFailures, 1)
        XCTAssertEqual(sender.queuedCount, 1)
        guard case .retryLater = await sender.sendPass() else { return XCTFail("2回目も再送待ち") }
        XCTAssertEqual(sender.consecutiveFailures, 2)
        let third = await sender.sendPass()
        XCTAssertEqual(third, .drained)
        XCTAssertEqual(sender.consecutiveFailures, 0)
        XCTAssertEqual(mock.sentChunks.count, 3)
        XCTAssertTrue(mock.sentChunks.allSatisfy { $0 == mock.sentChunks[0] }, "3回とも同じバイト列")
        XCTAssertEqual(sender.sentSeq, 0)
    }

    func testStopsOnNonRetryableChunkError() async throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        _ = try makeBuilder(store: store, count: 2)
        let mock = MockTransport()
        mock.chunkSteps = [APIError(status: 409, code: "PREV_MISMATCH", message: "prev")]
        let sender = ChunkSender(store: store, sid: sid, transport: mock)
        var fatalCodes: [String] = []
        sender.onFatal = { fatalCodes.append($0.code) }

        await sender.run(idleInterval: 0.01)  // 止まるまで戻らない
        XCTAssertEqual(fatalCodes, ["PREV_MISMATCH"])
        XCTAssertEqual(sender.fatal?.code, "PREV_MISMATCH")
        XCTAssertEqual(mock.calls, ["chunk:0"], "後のチャンクは送らない")
        XCTAssertEqual(sender.queuedCount, 2, "キューは消さない")

        // 「再送しない」エラー（400 など）でも止まる
        let other = MockTransport()
        other.chunkSteps = [APIError(status: 400, code: "BAD_REQUEST", message: "bad")]
        let result = await ChunkSender(store: store, sid: sid, transport: other).sendPass()
        XCTAssertEqual(result, .fatal(APIError(status: 400, code: "BAD_REQUEST", message: "bad")))
    }

    func testReceiptForAnotherHeaderStops() async throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        _ = try makeBuilder(store: store, count: 1)
        let mock = MockTransport()
        mock.receiptHeaderOverride = String(repeating: "0", count: 64)
        let sender = ChunkSender(store: store, sid: sid, transport: mock)
        guard case .fatal(let error) = await sender.sendPass() else { return XCTFail("止まるはず") }
        XCTAssertEqual(error.code, "RECEIPT_MISMATCH")
        XCTAssertEqual(sender.queuedCount, 1)
        XCTAssertNil(ChunkSender.lastReceiptSeq(store: store, sid: sid))
    }

    func testImageThatCannotBeResentIsSkipped() async throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        _ = try makeBuilder(store: store, count: 1)
        let image = try writeImage(store: store, bytes: Data([0xFF, 0xD8, 9]))
        let mock = MockTransport()
        mock.imageSteps = [APIError(status: 413, code: "TOO_LARGE", message: "big")]
        let sender = ChunkSender(store: store, sid: sid, transport: mock)
        let result = await sender.sendPass()
        XCTAssertEqual(result, .drained)
        XCTAssertEqual(mock.calls, ["image:\(image.sha)", "chunk:0"])
        XCTAssertEqual(sender.pendingImageCount, 0)
        XCTAssertNotNil(sender.lastError)
    }

    func testImageNetworkErrorWaitsBeforeChunks() async throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        _ = try makeBuilder(store: store, count: 1)
        let image = try writeImage(store: store, bytes: Data([0xFF, 0xD8, 7]))
        let mock = MockTransport()
        mock.imageSteps = [APIError(status: 0, code: "NETWORK", message: "offline")]
        let sender = ChunkSender(store: store, sid: sid, transport: mock)
        guard case .retryLater = await sender.sendPass() else { return XCTFail("再送待ち") }
        XCTAssertEqual(mock.calls, ["image:\(image.sha)"], "画像を送れるまでチャンクは送らない")
        let pass1 = await sender.sendPass()
        XCTAssertEqual(pass1, .drained)
        XCTAssertEqual(mock.calls, ["image:\(image.sha)", "image:\(image.sha)", "chunk:0"])
    }

    func testFinalChunkIsSentLastAfterTheEndImage() async throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        let builder = try makeBuilder(store: store, count: 2)
        let mock = MockTransport()
        let sender = ChunkSender(store: store, sid: sid, transport: mock)
        let pass2 = await sender.sendPass()
        XCTAssertEqual(pass2, .drained)

        // 録画を終える: 終了画面に印を付けてから、最終チャンクを作る
        let end = try writeImage(store: store, bytes: Data([0xFF, 0xD8, 0xEE]))
        _ = try builder.append(
            drained(), now: t0.addingTimeInterval(12), fps: 2, memMB: 30, degraded: false, end: end.sha, final: true
        )
        let pass3 = await sender.sendPass()
        XCTAssertEqual(pass3, .drained)
        XCTAssertEqual(mock.calls, ["chunk:0", "chunk:1", "image:\(end.sha)", "chunk:2"])
        let last = try header(of: try XCTUnwrap(mock.sentChunks.last))
        XCTAssertTrue(last.final)
        XCTAssertEqual(last.images?.end, end.sha)
        XCTAssertEqual(last.prev, Canonical.sha256Hex(try XCTUnwrap(Canonical.fromBase64(mock.sentChunks[1].header))))
    }

    func testFlushReturnsAfterMaxAttempts() async throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        _ = try makeBuilder(store: store, count: 1)
        let mock = MockTransport()
        mock.chunkSteps = [APIError(status: 0, code: "NETWORK", message: "offline")]
        let sender = ChunkSender(store: store, sid: sid, transport: mock)
        guard case .retryLater = await sender.flush(maxAttempts: 1) else { return XCTFail("送れないまま返る") }
        let pass4 = await sender.flush(maxAttempts: 1)
        XCTAssertEqual(pass4, .drained)
        XCTAssertTrue(sender.isDrained)
    }

    func testStopBeforeRunReturnsImmediately() async throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        _ = try makeBuilder(store: store, count: 1)
        let mock = MockTransport()
        let sender = ChunkSender(store: store, sid: sid, transport: mock)
        sender.stop()
        await sender.run(idleInterval: 0.01)
        XCTAssertEqual(mock.calls, [])
    }

    func testBackoffDelays() {
        XCTAssertEqual((0..<8).map(ChunkSender.delay(forAttempt:)), [1, 2, 4, 8, 16, 30, 30, 30])
    }

    func testShouldAppSend() {
        let now = Date(timeIntervalSince1970: 1_793_000_100)
        func status(_ state: BroadcastState, sid: String? = "s_X", ago: TimeInterval) -> BroadcastStatus {
            BroadcastStatus(sid: sid, state: state, updatedAt: Canonical.timeString(now.addingTimeInterval(-ago)))
        }
        XCTAssertTrue(ChunkSender.shouldAppSend(status: nil, sid: "s_X", now: now))
        XCTAssertTrue(ChunkSender.shouldAppSend(status: status(.recording, sid: "s_Other", ago: 1), sid: "s_X", now: now))
        XCTAssertFalse(ChunkSender.shouldAppSend(status: status(.recording, ago: 1), sid: "s_X", now: now))
        XCTAssertFalse(ChunkSender.shouldAppSend(status: status(.finishing, ago: 29), sid: "s_X", now: now))
        XCTAssertTrue(ChunkSender.shouldAppSend(status: status(.recording, ago: 30), sid: "s_X", now: now))
        XCTAssertTrue(ChunkSender.shouldAppSend(status: status(.finished, ago: 1), sid: "s_X", now: now))
        XCTAssertTrue(ChunkSender.shouldAppSend(status: status(.error, ago: 1), sid: "s_X", now: now))
    }

    // MARK: - SessionStarter

    func testStarterRetriesNetworkErrorsAndSavesTheCertificate() async throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        let key = try testKey()
        let mock = MockTransport()
        mock.startSteps = [
            APIError(status: 0, code: "NETWORK", message: "offline"),
            APIError(status: 502, code: "HTTP_502", message: "gateway"),
            nil,
        ]
        mock.startResponse = startResponse(devicePubKey: key.publicKeyX963Base64)
        var slept: [TimeInterval] = []
        let started = try await SessionStarter.start(
            session: sessionInfo(), key: key, store: store, transport: mock, sleep: { slept.append($0) }
        )
        XCTAssertEqual(slept, [1, 2])
        XCTAssertEqual(mock.startCalls, 3)
        XCTAssertEqual(mock.startKeys, Array(repeating: key.publicKeyX963Base64, count: 3), "同じ鍵で再送する")
        XCTAssertEqual(started.sid, sid)
        XCTAssertEqual(started.startCert, Canonical.fromBase64(try XCTUnwrap(mock.startResponse).startCert))
        let saved = try JSONDecoder().decode(StartResponse.self, from: Data(contentsOf: store.startURL(sid: sid)))
        XCTAssertEqual(saved, mock.startResponse)

        // 開始証から作ったチャンクの最初の prev は、開始証のバイト列のハッシュ
        let builder = try ChunkBuilder(
            sid: sid, store: store, signer: key, startCert: started.startCert, recordingStartedAt: t0
        )
        XCTAssertEqual(builder.prevHash, Canonical.sha256Hex(started.startCert))
    }

    func testStarterDoesNotRetryTokenErrors() async throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        let mock = MockTransport()
        mock.startSteps = [APIError(status: 410, code: "TOKEN_EXPIRED", message: "expired")]
        var slept: [TimeInterval] = []
        do {
            _ = try await SessionStarter.start(
                session: sessionInfo(), key: try testKey(), store: store, transport: mock, sleep: { slept.append($0) }
            )
            XCTFail("投げるはず")
        } catch let error as APIError {
            XCTAssertEqual(error.code, "TOKEN_EXPIRED")
        }
        XCTAssertEqual(mock.startCalls, 1)
        XCTAssertEqual(slept, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.startURL(sid: sid).path))
    }

    func testStarterGivesUpAfterThreeRetries() async throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        let mock = MockTransport()
        mock.startSteps = Array(repeating: APIError(status: 0, code: "NETWORK", message: "offline"), count: 4)
        var slept: [TimeInterval] = []
        do {
            _ = try await SessionStarter.start(
                session: sessionInfo(), key: try testKey(), store: store, transport: mock, sleep: { slept.append($0) }
            )
            XCTFail("投げるはず")
        } catch let error as APIError {
            XCTAssertEqual(error.code, "NETWORK")
        }
        XCTAssertEqual(mock.startCalls, 4)
        XCTAssertEqual(slept, [1, 2, 4])
    }

    func testStarterRejectsCertificateForAnotherKey() async throws {
        let (store, cleanup) = try makeStore()
        defer { cleanup() }
        let mock = MockTransport()
        mock.startResponse = startResponse(devicePubKey: DeviceKey().publicKeyX963Base64)
        do {
            _ = try await SessionStarter.start(
                session: sessionInfo(), key: try testKey(), store: store, transport: mock, sleep: { _ in }
            )
            XCTFail("投げるはず")
        } catch let error as SessionStartError {
            XCTAssertEqual(error, .certificateMismatch("devicePubKey"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.startURL(sid: sid).path))
    }

    // MARK: - 手伝い

    private func testKey() throws -> DeviceKey {
        try DeviceKey(rawRepresentation: Data(repeating: 1, count: 32))
    }

    private func drained(tiles: [Int] = [], editorMs: Int = 5000, activeMs: Int = 0) -> ActivityAccumulator.Drained {
        let accumulator = ActivityAccumulator()
        accumulator.add(FrameResult(
            frameTime: t0, adoptedTiles: tiles, differingCount: tiles.count, isFirst: false, isGlobalChange: false
        ))
        accumulator.addEditorTime(milliseconds: editorMs)
        accumulator.addActiveTime(milliseconds: activeMs)
        return accumulator.drain()
    }

    private func header(of item: QueueItem) throws -> ChunkHeader {
        try JSONDecoder().decode(ChunkHeader.self, from: try XCTUnwrap(Canonical.fromBase64(item.header)))
    }

    private func makeBuilder(store: AppGroupStore, count: Int) throws -> ChunkBuilder {
        let builder = try ChunkBuilder(
            sid: sid, store: store, signer: try testKey(), startCert: startCert, recordingStartedAt: t0
        )
        for index in 0..<count {
            _ = try builder.append(
                drained(tiles: [index]), now: t0.addingTimeInterval(Double(index + 1) * 5),
                fps: 2, memMB: 30, degraded: false
            )
        }
        return builder
    }

    /// 撮った画像と同じ形で置く（`{sha}.jpg`・`.sig`・`.pending`）。
    private func writeImage(store: AppGroupStore, bytes: Data) throws -> (sha: String, bytes: Data, sig: Data) {
        let writer = try SnapshotWriter(store: store, sid: sid, signer: try testKey())
        let sha = try writer.save(bytes)
        try writer.markPending(sha)
        let sig = try XCTUnwrap(Canonical.fromBase64(
            try String(contentsOf: writer.signatureURL(sha), encoding: .utf8)
        ))
        return (sha, bytes, sig)
    }

    private func sessionInfo() -> SessionInfo {
        SessionInfo(
            sid: sid, workId: "w_BBBBBBBBBBBBBBBB", startToken: "token",
            apiBaseURL: "https://api.example.com", createdAt: Canonical.timeString(t0)
        )
    }

    private func startResponse(devicePubKey: String) -> StartResponse {
        let cert = #"{"checked":["startToken"],"devicePubKey":"\#(devicePubKey)","issuedAt":"2026-11-06T00:00:00.000Z","sid":"\#(sid)","type":"start","v":1,"workId":"w_BBBBBBBBBBBBBBBB"}"#
        return StartResponse(startCert: Canonical.base64(Data(cert.utf8)), sig: Canonical.base64(Data([0x30, 0x06])))
    }

    private func makeStore() throws -> (AppGroupStore, () -> Void) {
        let suite = "TraceKitTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = AppGroupStore(defaults: defaults, containerURL: folder)
        return (store, {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        })
    }
}

/// 受付API のモック。`*Steps` の先頭から1つずつ使う（`nil` は成功）。空なら成功。
final class MockTransport: ChunkTransport, SessionStartTransport {
    struct SentImage: Equatable { let sha: String; let jpeg: Data; let sig: Data }

    var chunkSteps: [APIError?] = []
    var imageSteps: [APIError?] = []
    var startSteps: [APIError?] = []
    var startResponse: StartResponse?
    /// 受領証の `header` を、わざと違う値にする。
    var receiptHeaderOverride: String?

    private(set) var calls: [String] = []
    private(set) var sentChunks: [QueueItem] = []
    private(set) var sentImages: [SentImage] = []
    private(set) var startCalls = 0
    private(set) var startKeys: [String] = []

    func sendChunk(sid: String, item: QueueItem) async throws -> ReceiptResponse {
        calls.append("chunk:\(item.seq)")
        sentChunks.append(item)
        if !chunkSteps.isEmpty, let error = chunkSteps.removeFirst() {
            throw error
        }
        return Self.receipt(sid: sid, item: item, header: receiptHeaderOverride)
    }

    func putImage(sid: String, sha256: String, jpeg: Data, deviceSig: Data) async throws -> ImageResponse {
        calls.append("image:\(sha256)")
        sentImages.append(SentImage(sha: sha256, jpeg: jpeg, sig: deviceSig))
        if !imageSteps.isEmpty, let error = imageSteps.removeFirst() {
            throw error
        }
        return ImageResponse(sha256: sha256)
    }

    func start(sid: String, startToken: String, devicePubKey: String) async throws -> StartResponse {
        startCalls += 1
        startKeys.append(devicePubKey)
        if !startSteps.isEmpty, let error = startSteps.removeFirst() {
            throw error
        }
        guard let startResponse else { throw APIError(status: 500, code: "INTERNAL", message: "no response") }
        return startResponse
    }

    /// 受付API と同じ形の受領証（署名はダミー）。
    static func receipt(sid: String, item: QueueItem, header: String? = nil) -> ReceiptResponse {
        struct Receipt: Encodable {
            let v = 1
            let type = "receipt"
            let sid: String
            let seq: Int
            let header: String
            let receivedAt = "2026-11-06T00:00:00.000Z"
        }
        let headerHash = header ?? Canonical.sha256Hex(Canonical.fromBase64(item.header) ?? Data())
        let bytes = (try? Canonical.encodeSorted(Receipt(sid: sid, seq: item.seq, header: headerHash))) ?? Data()
        return ReceiptResponse(receipt: Canonical.base64(bytes), sig: Canonical.base64(Data([0x30, 0x06])))
    }
}

/// T07 で足した APIClient の呼び出し（#2・#4・#12）。
final class APIClientWorkTests: XCTestCase {
    private var client: APIClient!

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        client = APIClient(baseURL: URL(string: "https://api.example.com")!, session: URLSession(configuration: configuration))
        StubURLProtocol.reset()
    }

    func testCreateWorkDecodesTheDetail() async throws {
        StubURLProtocol.respond(201, """
        {"createdAt":"2026-11-06T00:00:00.000Z","displayName":"N","explanation":null,"match":null,"png":null,\
        "publicId":null,"session":null,"status":"draft","title":"T","workId":"w_X"}
        """)
        let work = try await client.createWork(title: "T", displayName: "N", idToken: "tok")
        XCTAssertEqual(work.workId, "w_X")
        XCTAssertEqual(work.status, "draft")
        XCTAssertNil(work.session)
        let request = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/v1/works")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertEqual(StubURLProtocol.lastBody.map { String(decoding: $0, as: UTF8.self) }, #"{"displayName":"N","title":"T"}"#)
    }

    func testGetWorkReadsTheSession() async throws {
        StubURLProtocol.respond(200, """
        {"createdAt":"2026-11-06T00:00:00.000Z","displayName":"N","explanation":null,"match":null,\
        "png":{"height":2,"sha256":"aa","width":3},"publicId":null,\
        "session":{"chunkCount":12,"final":true,"lastReceivedAt":"2026-11-06T00:01:00.000Z","sid":"s_A",\
        "startedAt":"2026-11-06T00:00:01.000Z","status":"completed"},"status":"recorded","title":"T","workId":"w_X"}
        """)
        let work = try await client.getWork(workId: "w_X", idToken: "tok")
        XCTAssertEqual(work.status, "recorded")
        XCTAssertEqual(work.session?.chunkCount, 12)
        XCTAssertEqual(work.session?.final, true)
        XCTAssertEqual(work.session?.status, "completed")
        XCTAssertEqual(StubURLProtocol.lastRequest?.httpMethod, "GET")
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/v1/works/w_X")
    }

    func testDeleteWorkAcceptsNoContent() async throws {
        StubURLProtocol.respond(204, "")
        try await client.deleteWork(workId: "w_X", idToken: "tok")
        XCTAssertEqual(StubURLProtocol.lastRequest?.httpMethod, "DELETE")
        XCTAssertEqual(StubURLProtocol.lastRequest?.url?.path, "/v1/works/w_X")
    }
}
