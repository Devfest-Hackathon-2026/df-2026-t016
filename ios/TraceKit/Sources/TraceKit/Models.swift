import Foundation

// App Group で受け渡す値（tasks/00_共通仕様.md の8章）と、チャンクの形式（4章）。

/// `session.current`: 本体アプリが書き、録画拡張が録画の開始時に読む。
public struct SessionInfo: Codable, Equatable {
    public var sid: String
    public var workId: String
    public var startToken: String
    public var apiBaseURL: String
    public var createdAt: String

    public init(sid: String, workId: String, startToken: String, apiBaseURL: String, createdAt: String) {
        self.sid = sid
        self.workId = workId
        self.startToken = startToken
        self.apiBaseURL = apiBaseURL
        self.createdAt = createdAt
    }
}

public enum BroadcastState: String, Codable {
    case starting, recording, finishing, finished, error
}

/// `broadcast.status`: 録画拡張が書き、本体アプリが読む。
public struct BroadcastStatus: Codable, Equatable {
    /// 録画中のセッション。`session.current` が読めなかったときは `nil`。
    public var sid: String?
    public var state: BroadcastState
    /// 送り終えたチャンクの最後の `seq`。まだ1つも送っていなければ -1（T07 で使う）。
    public var sentSeq: Int
    /// 送信待ちのチャンクの数（T07 で使う）。
    public var queuedCount: Int
    /// 撮った全体画像の枚数（T13 で使う）。
    public var wholeCount: Int
    /// 最後のエラーだけ。フレームの統計は別キー `broadcast.debug` に置く。
    public var lastError: String?
    public var updatedAt: String

    public init(
        sid: String?,
        state: BroadcastState,
        sentSeq: Int = -1,
        queuedCount: Int = 0,
        wholeCount: Int = 0,
        lastError: String? = nil,
        updatedAt: String = Canonical.timeString()
    ) {
        self.sid = sid
        self.state = state
        self.sentSeq = sentSeq
        self.queuedCount = queuedCount
        self.wholeCount = wholeCount
        self.lastError = lastError
        self.updatedAt = updatedAt
    }
}

/// `broadcast.debug`: 確認用の診断情報（【T15d】画面には出さない。録画拡張は同じ1行をログにも出す）。
public struct BroadcastDebug: Codable, Equatable {
    public var sid: String?
    public var summary: String
    public var updatedAt: String

    public init(sid: String?, summary: String, updatedAt: String = Canonical.timeString()) {
        self.sid = sid
        self.summary = summary
        self.updatedAt = updatedAt
    }
}

/// `w_`・`s_` で始まる ID（12バイトの乱数を base64url にしたもの）。
public enum TraceID {
    public static func make(prefix: String) -> String {
        var bytes = [UInt8](repeating: 0, count: 12)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: 0...255)
        }
        return prefix + Canonical.base64url(Data(bytes))
    }
}

// MARK: - チャンク（tasks/00_共通仕様.md の4章）

/// チャンクのヘッダの `stats`。
public struct ChunkStats: Codable, Equatable {
    public var fps: Int
    public var changedTiles: Int
    public var resend: Bool
    public var memMB: Int
    /// メモリ不足で fps を落としたら true。
    public var degraded: Bool
    /// 【11/6】そのチャンクの間に Procreate の編集画面だった時間（ミリ秒）。無ければ出力しない。
    public var editorMs: Int?
    /// 【11/6】そのうち、キャンバスに小さな変化があった時間（ミリ秒）。無ければ出力しない。
    public var activeMs: Int?

    public init(
        fps: Int, changedTiles: Int, resend: Bool, memMB: Int, degraded: Bool,
        editorMs: Int? = nil, activeMs: Int? = nil
    ) {
        self.fps = fps
        self.changedTiles = changedTiles
        self.resend = resend
        self.memMB = memMB
        self.degraded = degraded
        self.editorMs = editorMs
        self.activeMs = activeMs
    }
}

/// チャンクのヘッダの `images`。無いものは出力しない。
public struct ChunkImages: Codable, Equatable {
    public var start: String?
    public var end: String?
    /// 全体画像。1チャンクに1枚、撮影順に載せる。
    public var whole: String?

    public init(start: String? = nil, end: String? = nil, whole: String? = nil) {
        self.start = start
        self.end = end
        self.whole = whole
    }

    public var isEmpty: Bool { start == nil && end == nil && whole == nil }
}

/// チャンクのヘッダ。署名する対象は `Canonical.encodeSorted(header)` のバイト列。
public struct ChunkHeader: Codable, Equatable {
    public var v: Int
    public var sid: String
    public var seq: Int
    /// 前のチャンクのヘッダのハッシュ（seq=0 なら開始証のハッシュ）。
    public var prev: String
    public var tStart: String
    public var tEnd: String
    /// 本文のハッシュ。
    public var body: String
    public var bodyLen: Int
    public var images: ChunkImages?
    public var stats: ChunkStats
    public var `final`: Bool

    public init(
        sid: String, seq: Int, prev: String, tStart: String, tEnd: String,
        body: String, bodyLen: Int, images: ChunkImages? = nil, stats: ChunkStats, `final`: Bool
    ) {
        self.v = 1
        self.sid = sid
        self.seq = seq
        self.prev = prev
        self.tStart = tStart
        self.tEnd = tEnd
        self.body = body
        self.bodyLen = bodyLen
        self.images = (images?.isEmpty ?? true) ? nil : images
        self.stats = stats
        self.final = `final`
    }
}

/// チャンクの本文。
public struct ChunkBody: Codable, Equatable {
    public var v: Int
    /// 処理したフレームごとの、採用したタイルの数（0〜768、最大600個）。
    public var frames: [Int]
    /// チャンク内で一度でも採用されたタイルのビットマップ（96バイト）の base64。
    public var tiles: String

    public init(frames: [Int], tiles: Data) {
        self.v = 1
        self.frames = frames
        self.tiles = Canonical.base64(tiles)
    }
}

/// App Group の `sessions/{sid}/queue/{seq:06d}.json`（署名済みで送信待ちのチャンク。値はすべて base64）。
public struct QueueItem: Codable, Equatable {
    public var seq: Int
    public var header: String
    public var sig: String
    public var body: String

    public init(seq: Int, header: Data, sig: Data, body: Data) {
        self.seq = seq
        self.header = Canonical.base64(header)
        self.sig = Canonical.base64(sig)
        self.body = Canonical.base64(body)
    }
}

/// タイル（32×24）のビットマップ。タイル番号 `i = y*32 + x` は `byte[i/8]` の第 `(7 - i%8)` ビット。
public enum TileBitmap {
    public static let columns = 32
    public static let rows = 24
    public static let count = columns * rows
    public static let byteCount = count / 8

    public static func make<S: Sequence>(_ indices: S) -> Data where S.Element == Int {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        for index in indices where (0..<count).contains(index) {
            bytes[index / 8] |= UInt8(1) << UInt8(7 - index % 8)
        }
        return Data(bytes)
    }

    public static func indices(_ bitmap: Data) -> [Int] {
        let bytes = [UInt8](bitmap)
        return (0..<min(count, bytes.count * 8)).filter { index in
            bytes[index / 8] & (UInt8(1) << UInt8(7 - index % 8)) != 0
        }
    }
}
