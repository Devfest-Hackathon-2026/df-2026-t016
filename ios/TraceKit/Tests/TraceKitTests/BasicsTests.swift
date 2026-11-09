import Foundation
import XCTest
@testable import TraceKit

/// 手順A の分の試験。署名とテストベクタの試験は手順B で足す。
final class BasicsTests: XCTestCase {
    func testTimeStringIsUTCWithMilliseconds() {
        XCTAssertEqual(Canonical.timeString(Date(timeIntervalSince1970: 0)), "1970-01-01T00:00:00.000Z")
        XCTAssertEqual(Canonical.timeString(Date(timeIntervalSince1970: 1.5)), "1970-01-01T00:00:01.500Z")
    }

    func testEncodeSortedSortsKeysAndKeepsSlashes() throws {
        struct Sample: Encodable {
            let b = 1
            let a = "x/y"
        }
        let json = String(decoding: try Canonical.encodeSorted(Sample()), as: UTF8.self)
        XCTAssertEqual(json, #"{"a":"x/y","b":1}"#)
    }

    func testSHA256Hex() {
        XCTAssertEqual(
            Canonical.sha256Hex(Data("abc".utf8)),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testTraceIDShape() {
        let id = TraceID.make(prefix: "s_")
        XCTAssertTrue(id.hasPrefix("s_"))
        XCTAssertEqual(id.count, 2 + 16)
        XCTAssertNil(id.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")))
    }

    func testStoreRoundTrip() throws {
        let suite = "TraceKitTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = AppGroupStore(defaults: defaults, containerURL: folder)

        XCTAssertNil(store.sessionCurrent)
        let session = SessionInfo(
            sid: "s_AAAAAAAAAAAAAAAA",
            workId: "w_BBBBBBBBBBBBBBBB",
            startToken: "token",
            apiBaseURL: "https://example.com",
            createdAt: Canonical.timeString()
        )
        try store.setSessionCurrent(session)
        XCTAssertEqual(store.sessionCurrent, session)

        let status = BroadcastStatus(sid: session.sid, state: .recording, lastError: "frames=1")
        try store.setBroadcastStatus(status)
        XCTAssertEqual(store.broadcastStatus, status)
        XCTAssertEqual(store.broadcastStatus?.sentSeq, -1)

        try store.prepareSession(session.sid)
        let queue = store.directory(.queue, sid: session.sid)
        try Data("1".utf8).write(to: queue.appendingPathComponent("000002.json"))
        try Data("0".utf8).write(to: queue.appendingPathComponent("000001.json"))
        XCTAssertEqual(store.files(in: .queue, sid: session.sid).map(\.lastPathComponent), ["000001.json", "000002.json"])

        store.removeSession(session.sid)
        XCTAssertTrue(store.files(in: .queue, sid: session.sid).isEmpty)
    }
}
