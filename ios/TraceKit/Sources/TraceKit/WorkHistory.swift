import Foundation

/// 全体画像と、それを撮った記録の sid（画像のファイルは `sessions/{sid}/images/` にある）。
public struct HistorySnapshot: Equatable {
    public let sid: String
    public let item: WholeItem

    public init(sid: String, item: WholeItem) {
        self.sid = sid
        self.item = item
    }
}

/// 【T14】1回の記録（録画の開始から停止まで）のまとめ。作品の画面の「記録」の一覧に出す。
public struct WorkRecordSummary: Identifiable, Equatable {
    public var id: String { sid }
    /// 何回目か（0から）
    public let index: Int
    public let sid: String
    /// 受付API の状態（`recording`・`completed`・`finalizing`・`finalized`）
    public let status: String
    public let chunkCount: Int
    /// 最終チャンクを受信したか（正常に止めた記録）
    public let final: Bool
    public let startedAt: Date?
    public let lastReceivedAt: Date?
    /// この端末に残っている全体画像（撮った順）。ほかの端末で録画した記録では空
    public let snapshots: [WholeItem]
    public var lastSnapshot: WholeItem? { snapshots.last }
    /// 受信区間の長さ（開始から最後の受信まで）。録画が続いた時間で、制作時間ではない
    public var span: TimeInterval? {
        guard let startedAt, let lastReceivedAt else { return nil }
        return max(0, lastReceivedAt.timeIntervalSince(startedAt))
    }

    /// 開始した記録を、作った順に並べる。`records` は sid ごとの `whole.json`。
    public static func make(work: WorkDetail, records: [String: WholeRecord]) -> [WorkRecordSummary] {
        work.startedSessions.enumerated().map { index, session in
            WorkRecordSummary(index: index, sid: session.sid, status: session.status, chunkCount: session.chunkCount,
                              final: session.final, startedAt: session.startedAt.flatMap(Canonical.parseTime),
                              lastReceivedAt: session.lastReceivedAt.flatMap(Canonical.parseTime),
                              snapshots: snapshots(records[session.sid]))
        }
    }

    /// `items` と `latest` を合わせ、撮った順に並べる（時刻が読めないものは外す）。
    static func snapshots(_ record: WholeRecord?) -> [WholeItem] {
        var images = record?.items ?? []
        if let latest = record?.latest, !images.contains(latest) { images.append(latest) }
        return images.filter { Canonical.parseTime($0.frameTime) != nil }.sorted { $0.frameTime < $1.frameTime }
    }
}

/// カレンダーの1日。端末の暦・タイムゾーンで区切る。端末時刻の画像とサーバの受信区間は区別して表示する。
/// 【T14】1日に複数の記録があれば `records` に記録の順で並ぶ。日をまたいだ記録は、両方の日に出る。
public struct WorkHistoryDay: Identifiable, Equatable {
    /// その日に入る、1回の記録の分。
    public struct DayRecord: Identifiable, Equatable {
        public var id: String { sid }
        public let index: Int
        public let sid: String
        public let status: String
        public let final: Bool
        /// この日に撮った全体画像
        public let snapshots: [WholeItem]
        /// この日に入る受信区間（ほかの日にまたがる分は切る）
        public let receivedStart: Date?
        public let receivedEnd: Date?
        public var lastSnapshot: WholeItem? { snapshots.last }
    }

    public var id: Date { date }
    public let date: Date
    public let records: [DayRecord]
    /// この日のすべての全体画像（記録の順・撮った順）
    public var snapshots: [HistorySnapshot] {
        records.flatMap { r in r.snapshots.map { HistorySnapshot(sid: r.sid, item: $0) } }
    }
    public var lastSnapshot: HistorySnapshot? { snapshots.last }

    public static func make(work: WorkDetail, records: [String: WholeRecord], calendar: Calendar = .current) -> [WorkHistoryDay] {
        let summaries = WorkRecordSummary.make(work: work, records: records)
        var byDay: [Date: [DayRecord]] = [:]
        for summary in summaries {
            let grouped = Dictionary(grouping: summary.snapshots) { item in
                calendar.startOfDay(for: Canonical.parseTime(item.frameTime)!)
            }
            var dates = Set(grouped.keys)
            let start = summary.startedAt
            let end = summary.lastReceivedAt
            if let start {
                var day = calendar.startOfDay(for: start)
                let lastDay = calendar.startOfDay(for: max(start, end ?? start))
                // 1回の記録は6時間まで。壊れた応答で際限なく日付を作らない。
                for _ in 0..<3 {
                    guard day <= lastDay else { break }
                    dates.insert(day)
                    guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                    day = next
                }
            }
            for date in dates {
                let next = calendar.date(byAdding: .day, value: 1, to: date) ?? date
                let hasInterval = start != nil && end != nil && start! < next && end! >= date
                byDay[date, default: []].append(DayRecord(
                    index: summary.index, sid: summary.sid, status: summary.status, final: summary.final,
                    snapshots: grouped[date] ?? [],
                    receivedStart: hasInterval ? max(start!, date) : nil,
                    receivedEnd: hasInterval ? min(end!, next) : nil))
            }
        }
        return byDay.keys.sorted(by: >).map { date in
            WorkHistoryDay(date: date, records: byDay[date]!.sorted { $0.index < $1.index })
        }
    }
}

public enum RecordingPolicy {
    public static func matchingStatus(_ status: BroadcastStatus?, sid: String?) -> BroadcastStatus? {
        guard let sid, let status, status.sid == sid else { return nil }
        return status
    }

    public static func isStale(_ status: BroadcastStatus, now: Date = Date()) -> Bool {
        guard let updated = Canonical.parseTime(status.updatedAt) else { return true }
        return now.timeIntervalSince(updated) >= 30
    }

    public static func isActive(_ status: BroadcastStatus?, now: Date = Date()) -> Bool {
        guard let status, !isStale(status, now: now) else { return false }
        return status.state == .starting || status.state == .recording || status.state == .finishing
    }

    public static func didFinish(_ status: BroadcastStatus?) -> Bool {
        status?.state == .finished || status?.state == .error
    }
}
