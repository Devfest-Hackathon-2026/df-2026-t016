import Foundation

/// チャンクのヘッダに署名するもの。録画拡張では、開始の登録に使った `DeviceKey`。
public protocol ChunkSigning {
    func signRS(_ data: Data) throws -> Data
}

extension DeviceKey: ChunkSigning {}

/// 5秒ごとのチャンクを作り、署名して App Group のキューに書く（tasks/T07_録画拡張_送信.md の2）。
///
/// - 録画拡張の直列キューの上で使う（スレッドセーフではない）。
/// - `seq` は 0 から1ずつ増やし、キューに書けてから進める（抜けを作らない）。
/// - ヘッダの `prev` は、前に作ったヘッダのバイト列のハッシュ（seq=0 は開始証のバイト列のハッシュ）。送れたかどうかには関係しない。
public final class ChunkBuilder {
    public enum BuildError: Error, Equatable, CustomStringConvertible {
        /// キューが上限（5000件）に達した。録画を終える。
        case queueFull(Int)
        /// 最終チャンクの後に作ろうとした。
        case finalAlreadyBuilt

        public var description: String {
            switch self {
            case .queueFull(let limit): return "チャンクが上限（\(limit)件）に達しました"
            case .finalAlreadyBuilt: return "最終チャンクの後には作れません"
            }
        }
    }

    /// 1セッションのチャンクの上限（共通仕様5章。ヘッダの `seq` は 0〜4999）。
    public static let maxChunks = 5000

    public let sid: String
    public let store: AppGroupStore
    /// 次に作るチャンクの `seq`。
    public private(set) var seq = 0
    /// 次のチャンクの `prev`。
    public private(set) var prevHash: String
    public private(set) var finalBuilt = false

    private let signer: ChunkSigning
    private let limit: Int
    private var lastEnd: Date
    private var startImage: String?
    private var startImageSent = false
    private var wholeImages: [String] = []
    private var lastWholeImage: String?

    /// - Parameters:
    ///   - startCert: 開始証のバイト列（`POST /start` の `startCert` を base64 から戻したもの）
    ///   - recordingStartedAt: 録画を始めた時刻（最初のチャンクの `tStart`）
    public init(
        sid: String,
        store: AppGroupStore,
        signer: ChunkSigning,
        startCert: Data,
        recordingStartedAt: Date,
        maxChunks: Int = ChunkBuilder.maxChunks
    ) throws {
        self.sid = sid
        self.store = store
        self.signer = signer
        limit = maxChunks
        prevHash = Canonical.sha256Hex(startCert)
        lastEnd = recordingStartedAt
        try store.prepareSession(sid)
    }

    /// 開始画面（最初の全体画像）が決まった。次に作るチャンクの `images.start` に1回だけ入れる。
    public func noteStartImage(_ sha: String) {
        guard startImage == nil else { return }
        startImage = sha
    }

    /// 残すことが決まった全体画像を、撮影順に1チャンク1枚で送る。
    public func noteWholeImage(_ sha: String) {
        guard (wholeImages.last ?? lastWholeImage) != sha else { return }
        wholeImages.append(sha)
    }

    /// 未記載の全体画像を先に書き、最後の画像を含む最終チャンクを作る。
    public func finish(
        _ drained: ActivityAccumulator.Drained, now: Date, fps: Int, memMB: Int,
        degraded: Bool, end: String?, sendWhole: Bool = true
    ) throws {
        var activity = drained
        while !wholeImages.isEmpty && (wholeImages.count > 1 || wholeImages.first != end) {
            try append(activity, now: now, fps: fps, memMB: memMB, degraded: degraded)
            activity = ActivityAccumulator().drain()
        }
        if sendWhole, let end { noteWholeImage(end) }
        try append(activity, now: now, fps: fps, memMB: memMB, degraded: degraded, end: end, final: true)
    }

    public func queueURL(_ seq: Int) -> URL {
        store.directory(.queue, sid: sid).appendingPathComponent(String(format: "%06d.json", seq))
    }

    /// チャンクを1つ作ってキューに書く。画面に変化がなくても呼ぶ（心拍）。
    /// - Parameters:
    ///   - drained: `ActivityAccumulator.drain()` の結果
    ///   - now: このチャンクの終わりの時刻（`tEnd`）
    ///   - fps: 処理した枚数（通常 2、メモリ不足のときは 1）
    ///   - end: 終了画面（最後の全体画像）。最終チャンクのときだけ入れる
    @discardableResult
    public func append(
        _ drained: ActivityAccumulator.Drained,
        now: Date,
        fps: Int,
        memMB: Int,
        degraded: Bool,
        end: String? = nil,
        final isFinal: Bool = false
    ) throws -> QueueItem {
        guard !finalBuilt else { throw BuildError.finalAlreadyBuilt }
        guard seq < limit else { throw BuildError.queueFull(limit) }

        let bodyBytes = try Canonical.encodeSorted(ChunkBody(frames: drained.frames, tiles: drained.tiles))
        var images = ChunkImages()
        if let startImage, !startImageSent {
            images.start = startImage
        }
        if isFinal, let end {
            images.end = end
        }
        images.whole = wholeImages.first
        let tEnd = max(now, lastEnd)
        let header = ChunkHeader(
            sid: sid,
            seq: seq,
            prev: prevHash,
            tStart: Canonical.timeString(lastEnd),
            tEnd: Canonical.timeString(tEnd),
            body: Canonical.sha256Hex(bodyBytes),
            bodyLen: bodyBytes.count,
            images: images,
            stats: ChunkStats(
                fps: max(0, fps),
                changedTiles: drained.changedTiles,
                resend: false,
                memMB: max(0, memMB),
                degraded: degraded,
                editorMs: drained.editorMs,
                activeMs: drained.activeMs
            ),
            final: isFinal
        )
        let headerBytes = try Canonical.encodeSorted(header)
        let signature = try signer.signRS(headerBytes)
        let item = QueueItem(seq: seq, header: headerBytes, sig: signature, body: bodyBytes)
        try Canonical.encodeSorted(item).write(to: queueURL(seq), options: .atomic)

        // キューに書けてから進める
        prevHash = Canonical.sha256Hex(headerBytes)
        seq += 1
        lastEnd = tEnd
        if images.start != nil { startImageSent = true }
        if let whole = images.whole {
            lastWholeImage = whole
            wholeImages.removeFirst()
        }
        if isFinal { finalBuilt = true }
        return item
    }
}
