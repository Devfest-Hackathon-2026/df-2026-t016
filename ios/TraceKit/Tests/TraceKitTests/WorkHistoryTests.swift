import Foundation
import XCTest
@testable import TraceKit

final class WorkHistoryTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar
    }

    private func session(_ sid: String, _ start: String?, _ end: String?, status: String = "recording", final: Bool = false) -> [String: Any] {
        ["sid": sid, "status": status, "chunkCount": 3, "startedAt": start as Any? ?? NSNull(),
         "lastReceivedAt": end as Any? ?? NSNull(), "final": final]
    }

    /// T14 より前の応答（`sessions` なし、`session` だけ）。
    private func work(start: String? = nil, end: String? = nil) throws -> WorkDetail {
        let json: [String: Any] = [
            "workId": "w_A", "title": "絵", "displayName": "作者", "status": start == nil ? "draft" : "recording",
            "createdAt": "2026-11-01T00:00:00.000Z",
            "session": start.map { session("s_A", $0, end) } as Any? ?? NSNull()
        ]
        return try JSONDecoder().decode(WorkDetail.self, from: JSONSerialization.data(withJSONObject: json))
    }

    /// 【T14】記録が複数の応答。
    private func work(sessions: [[String: Any]]) throws -> WorkDetail {
        let json: [String: Any] = [
            "workId": "w_A", "title": "絵", "displayName": "作者", "status": "recorded",
            "createdAt": "2026-11-01T00:00:00.000Z", "session": sessions.last as Any? ?? NSNull(), "sessions": sessions
        ]
        return try JSONDecoder().decode(WorkDetail.self, from: JSONSerialization.data(withJSONObject: json))
    }

    func testDraftHasNoInventedRecordingDay() throws {
        XCTAssertTrue(WorkHistoryDay.make(work: try work(), records: [:], calendar: calendar).isEmpty)
    }

    func testGroupsLatestSnapshotByLocalDayAndSortsByFrameTime() throws {
        var record = WholeRecord()
        let beforeMidnight = WholeItem(sha: "a", frameTime: "2026-11-06T14:59:00.000Z", rect: [0, 0, 1, 1])
        let afterMidnight = WholeItem(sha: "b", frameTime: "2026-11-06T15:01:00.000Z", rect: [0, 0, 1, 1])
        let latest = WholeItem(sha: "c", frameTime: "2026-11-06T15:03:00.000Z", rect: [0, 0, 1, 1])
        record.items = [afterMidnight, beforeMidnight]
        record.latest = latest
        let days = WorkHistoryDay.make(work: try work(start: "2026-11-06T14:58:00.000Z", end: "2026-11-06T15:04:00.000Z"),
                                       records: ["s_A": record], calendar: calendar)
        XCTAssertEqual(days.count, 2)
        XCTAssertEqual(calendar.component(.day, from: days[0].date), 7)
        XCTAssertEqual(days[0].snapshots.map(\.item), [afterMidnight, latest])
        XCTAssertEqual(days[0].lastSnapshot, HistorySnapshot(sid: "s_A", item: latest))
        XCTAssertEqual(days[1].lastSnapshot?.item, beforeMidnight)
        XCTAssertEqual(days[0].records.first?.receivedStart, Canonical.parseTime("2026-11-06T15:00:00.000Z"))
        XCTAssertEqual(days[1].records.first?.receivedEnd, Canonical.parseTime("2026-11-06T15:00:00.000Z"))
    }

    func testLatestAlreadyInItemsIsNotRepeated() throws {
        var record = WholeRecord()
        let item = WholeItem(sha: "a", frameTime: "2026-11-06T06:00:00.000Z", rect: [0, 0, 1, 1])
        record.items = [item]
        record.latest = item
        let days = WorkHistoryDay.make(work: try work(start: "2026-11-06T05:58:00.000Z", end: "2026-11-06T06:01:00.000Z"),
                                       records: ["s_A": record], calendar: calendar)
        XCTAssertEqual(days.first?.snapshots.map(\.item), [item])
    }

    func testAnotherDeviceHasRecordingDaysButNoFabricatedSnapshots() throws {
        let days = WorkHistoryDay.make(work: try work(start: "2026-11-06T14:00:00.000Z", end: "2026-11-06T16:00:00.000Z"),
                                       records: [:], calendar: calendar)
        XCTAssertEqual(days.count, 2)
        XCTAssertTrue(days.allSatisfy { $0.lastSnapshot == nil })
    }

    func testUnparseableSnapshotTimeIsIgnored() throws {
        var record = WholeRecord()
        record.items = [WholeItem(sha: "a", frameTime: "bad", rect: [])]
        let days = WorkHistoryDay.make(work: try work(start: "2026-11-06T05:00:00.000Z", end: "2026-11-06T05:10:00.000Z"),
                                       records: ["s_A": record], calendar: calendar)
        XCTAssertEqual(days.count, 1)
        XCTAssertTrue(days[0].snapshots.isEmpty)
    }

    // MARK: - T14 記録が複数

    func testRecordsAreGroupedPerDayAndKeepTheirOwnImages() throws {
        // 1回目: 11/6 午前（JST）。2回目と3回目: 11/7 の昼と夜（JST）。4つ目は未開始（数えない）
        let w = try work(sessions: [
            session("s_1", "2026-11-06T01:00:00.000Z", "2026-11-06T02:30:00.000Z", status: "completed", final: true),
            session("s_2", "2026-11-07T03:00:00.000Z", "2026-11-07T04:00:00.000Z", status: "completed", final: true),
            session("s_3", "2026-11-07T11:00:00.000Z", "2026-11-07T11:40:00.000Z", status: "recording"),
            ["sid": "s_4", "status": "created", "chunkCount": 0, "final": false]
        ])
        func record(_ sha: String, _ time: String) -> WholeRecord {
            var r = WholeRecord()
            r.items = [WholeItem(sha: sha, frameTime: time, rect: [0, 0, 1, 1])]
            return r
        }
        let records = ["s_1": record("a", "2026-11-06T02:00:00.000Z"), "s_3": record("c", "2026-11-07T11:30:00.000Z")]
        let summaries = WorkRecordSummary.make(work: w, records: records)
        XCTAssertEqual(summaries.map(\.sid), ["s_1", "s_2", "s_3"])
        XCTAssertEqual(summaries.map(\.index), [0, 1, 2])
        XCTAssertEqual(summaries[0].span, 5400)
        XCTAssertEqual(summaries[1].lastSnapshot, nil)
        XCTAssertEqual(summaries[2].final, false)

        let days = WorkHistoryDay.make(work: w, records: records, calendar: calendar)
        XCTAssertEqual(days.map { calendar.component(.day, from: $0.date) }, [7, 6])
        XCTAssertEqual(days[0].records.map(\.sid), ["s_2", "s_3"])
        XCTAssertEqual(days[0].lastSnapshot, HistorySnapshot(sid: "s_3", item: records["s_3"]!.items[0]))
        XCTAssertEqual(days[0].records[0].snapshots, [])
        XCTAssertEqual(days[1].records.map(\.sid), ["s_1"])
        XCTAssertEqual(days[1].snapshots.map(\.sid), ["s_1"])
    }

    func testOlderResponseWithoutSessionsStillListsTheOnlyRecord() throws {
        let w = try work(start: "2026-11-06T01:00:00.000Z", end: "2026-11-06T01:30:00.000Z")
        XCTAssertNil(w.sessions)
        XCTAssertEqual(w.allSessions.map(\.sid), ["s_A"])
        XCTAssertEqual(WorkRecordSummary.make(work: w, records: [:]).map(\.sid), ["s_A"])
    }

    func testUnrelatedStatusDoesNotChangeWorkState() {
        let status = BroadcastStatus(sid: "s_B", state: .finished)
        XCTAssertNil(RecordingPolicy.matchingStatus(status, sid: "s_A"))
        XCTAssertFalse(RecordingPolicy.didFinish(RecordingPolicy.matchingStatus(status, sid: "s_A")))
    }

    func testThirtySecondsIsOnlyAnEstimateAndFinishingStillOwnsSending() {
        let now = Date(timeIntervalSince1970: 1_793_000_000)
        let recent = BroadcastStatus(sid: "s_A", state: .finishing, updatedAt: Canonical.timeString(now.addingTimeInterval(-29)))
        let stale = BroadcastStatus(sid: "s_A", state: .recording, updatedAt: Canonical.timeString(now.addingTimeInterval(-30)))
        XCTAssertTrue(RecordingPolicy.isActive(recent, now: now))
        XCTAssertFalse(ChunkSender.shouldAppSend(status: recent, sid: "s_A", now: now))
        XCTAssertTrue(RecordingPolicy.isStale(stale, now: now))
        XCTAssertFalse(RecordingPolicy.didFinish(stale))
        XCTAssertTrue(ChunkSender.shouldAppSend(status: stale, sid: "s_A", now: now))
    }

    func testDebugInformationCannotBecomeLastError() throws {
        let suite = "t10-debug-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppGroupStore(defaults: defaults, containerURL: FileManager.default.temporaryDirectory)
        try store.setBroadcastStatus(BroadcastStatus(sid: "s_A", state: .recording))
        try store.setBroadcastDebug(BroadcastDebug(sid: "s_A", summary: "frames=50 fps=2"))
        XCTAssertNil(store.broadcastStatus?.lastError)
        XCTAssertEqual(store.broadcastDebug?.summary, "frames=50 fps=2")
    }
}
