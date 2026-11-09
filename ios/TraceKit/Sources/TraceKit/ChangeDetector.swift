import Foundation

/// 変化の判定の値（tasks/T05_録画拡張_画面の変化.md の3）。数値は初期値で、実機で調整する。
public struct ChangeDetectorConfig: Equatable {
    /// 画素の輝度の差がこれ以上なら「違う画素」。
    public var pixelDelta: Int
    /// 違う画素がこれ以上あるタイルは「基準と違う」。
    public var minPixels: Int
    /// 基準と違う状態がこの回数続いたら、変化として採用する。
    public var confirmFrames: Int
    /// 1回の処理で採用したタイルがこれ以上なら「全体変化」（768個の30%）。
    public var globalTiles: Int

    public init(pixelDelta: Int = 16, minPixels: Int = 3, confirmFrames: Int = 2, globalTiles: Int = 231) {
        self.pixelDelta = pixelDelta
        self.minPixels = minPixels
        self.confirmFrames = confirmFrames
        self.globalTiles = globalTiles
    }
}

/// 1フレームを処理した結果。
public struct FrameResult: Equatable {
    /// フレームを受け取った時刻（画像の時刻にはすべてこれを使う）。
    public var frameTime: Date
    /// このフレームで変化として採用したタイルの番号（`y*32 + x`）。
    public var adoptedTiles: [Int]
    /// このフレームで基準と違って見えたタイルの数（採用したものと、まだ確かめている途中のものの両方）。
    /// 「画面が止まったか」の判定（`WholeCapture`）に使う。
    public var differingCount: Int
    /// 最初のフレーム（基準を作っただけ）。
    public var isFirst: Bool
    /// 採用したタイルが `globalTiles` 以上（ズーム・回転・移動・バケツ塗りなど）。【11/6】「小さな変化」には数えない。
    public var isGlobalChange: Bool

    public var adoptedCount: Int { adoptedTiles.count }

    public init(frameTime: Date, adoptedTiles: [Int], differingCount: Int, isFirst: Bool, isGlobalChange: Bool) {
        self.frameTime = frameTime
        self.adoptedTiles = adoptedTiles
        self.differingCount = differingCount
        self.isFirst = isFirst
        self.isGlobalChange = isGlobalChange
    }
}

/// 縮小した輝度画像を 32×24 のタイルに分け、タイルごとの変化を判定する（純粋なロジック）。
///
/// - タイルごとに「最後に確定した状態」（基準）を持つ。
/// - 輝度の差が `pixelDelta` 以上の画素が `minPixels` 個以上あれば、そのタイルは基準と違う。
/// - 基準と違う状態が `confirmFrames` 回続いたら変化として採用し、基準を今の画素で上書きする。
/// - 最初のフレームでは基準を作るだけ。幅か高さが変わったら、基準を作り直す。
/// - 【11/6】`ignoredTiles` のタイル（上のバーとサイドバーにかかるもの）は数えない。
///
/// 1つの直列キューから呼ぶこと（スレッドセーフではない）。
public final class ChangeDetector {
    public let config: ChangeDetectorConfig
    public private(set) var width = 0
    public private(set) var height = 0
    private var base: [UInt8] = []
    private var pending = [UInt8](repeating: 0, count: TileBitmap.count)
    /// 数えないタイル（番号 `y*32 + x` ごと）。
    public private(set) var ignoredTiles = [Bool](repeating: false, count: TileBitmap.count)

    public init(config: ChangeDetectorConfig = ChangeDetectorConfig()) {
        self.config = config
    }

    /// 数えないタイルを決める（【11/6】上のバーとサイドバーにかかるタイル。`FrameGeometry.uiTiles` で求める）。
    public func setIgnoredTiles(_ indices: Set<Int>) {
        ignoredTiles = (0..<TileBitmap.count).map { indices.contains($0) }
    }

    /// 基準を捨てる。次のフレームは「最初のフレーム」になる。
    public func reset() {
        width = 0
        height = 0
        base = []
        pending = [UInt8](repeating: 0, count: TileBitmap.count)
    }

    /// 1フレームを処理する。`pixels` は `height` 行、1行 `bytesPerRow` バイトの輝度（1画素1バイト）。
    public func process(
        width: Int, height: Int, bytesPerRow: Int, pixels: UnsafePointer<UInt8>, frameTime: Date
    ) -> FrameResult {
        precondition(width >= TileBitmap.columns && height >= TileBitmap.rows, "画像が小さすぎます")
        precondition(bytesPerRow >= width, "bytesPerRow が幅より小さい")

        if base.isEmpty || width != self.width || height != self.height {
            self.width = width
            self.height = height
            var fresh = [UInt8](repeating: 0, count: width * height)
            fresh.withUnsafeMutableBufferPointer { buffer in
                let destination = buffer.baseAddress!
                for y in 0..<height {
                    (destination + y * width).update(from: pixels + y * bytesPerRow, count: width)
                }
            }
            base = fresh
            pending = [UInt8](repeating: 0, count: TileBitmap.count)
            return FrameResult(
                frameTime: frameTime, adoptedTiles: [], differingCount: 0, isFirst: true, isGlobalChange: false
            )
        }

        let columns = TileBitmap.columns
        let rows = TileBitmap.rows
        let tileWidth = width / columns
        let tileHeight = height / rows
        let delta = config.pixelDelta
        let need = config.minPixels
        let confirm = config.confirmFrames

        var adopted: [Int] = []
        var differing = 0
        var pendingCounts = pending
        let ignored = ignoredTiles

        base.withUnsafeMutableBufferPointer { buffer in
            let reference = buffer.baseAddress!
            for tileY in 0..<rows {
                let y0 = tileY * tileHeight
                // 余りの画素は、最後の行のタイルに入れる
                let y1 = tileY == rows - 1 ? height : y0 + tileHeight
                for tileX in 0..<columns {
                    let x0 = tileX * tileWidth
                    // 余りの画素は、最後の列のタイルに入れる
                    let x1 = tileX == columns - 1 ? width : x0 + tileWidth
                    let index = tileY * columns + tileX
                    if ignored[index] {
                        pendingCounts[index] = 0
                        continue
                    }

                    var count = 0
                    rowLoop: for y in y0..<y1 {
                        let current = pixels + y * bytesPerRow
                        let previous = reference + y * width
                        for x in x0..<x1 {
                            let difference = Int(current[x]) - Int(previous[x])
                            if difference >= delta || -difference >= delta {
                                count += 1
                                if count >= need { break rowLoop }
                            }
                        }
                    }

                    if count >= need {
                        differing += 1
                        let seen = Int(pendingCounts[index]) + 1
                        if seen >= confirm {
                            adopted.append(index)
                            pendingCounts[index] = 0
                            for y in y0..<y1 {
                                (reference + y * width + x0).update(from: pixels + y * bytesPerRow + x0, count: x1 - x0)
                            }
                        } else {
                            pendingCounts[index] = UInt8(min(seen, 255))
                        }
                    } else {
                        pendingCounts[index] = 0
                    }
                }
            }
        }

        pending = pendingCounts
        return FrameResult(
            frameTime: frameTime,
            adoptedTiles: adopted,
            differingCount: differing,
            isFirst: false,
            isGlobalChange: adopted.count >= config.globalTiles
        )
    }

    /// 試験などで使う。`luma` は `width * height` バイト（行の詰め物なし）。
    public func process(luma: [UInt8], width: Int, height: Int, frameTime: Date) -> FrameResult {
        precondition(luma.count >= width * height, "luma が足りません")
        return luma.withUnsafeBufferPointer { buffer in
            process(width: width, height: height, bytesPerRow: width, pixels: buffer.baseAddress!, frameTime: frameTime)
        }
    }
}

/// 変化の結果を、チャンク1つ分（5秒）貯める（tasks/T05_録画拡張_画面の変化.md の4）。
/// 録画拡張の処理のキューで `add` し、T07 のタイマーで `drain` するので、ロックで守る。
public final class ActivityAccumulator {
    public struct Drained: Equatable {
        /// 処理したフレームごとの、採用したタイルの数（チャンクの本文の `frames`）。
        public var frames: [Int]
        /// チャンク内で一度でも採用されたタイルのビットマップ（96バイト。共通仕様4章の並び）。
        public var tiles: Data
        /// `tiles` で立っているビットの数（ヘッダの `stats.changedTiles`）。
        public var changedTiles: Int
        /// 全体変化の回数。
        public var globalChanges: Int
        /// 【11/6】Procreate の編集画面だった時間（ミリ秒。ヘッダの `stats.editorMs`）。
        public var editorMs: Int
        /// 【11/6】そのうち、キャンバスに小さな変化があった時間（ミリ秒。`stats.activeMs`。`editorMs` を超えない）。
        public var activeMs: Int
    }

    /// チャンクの本文の `frames` は最大600個（共通仕様4章）。超えた分は数を残さない（タイルのビットには入れる）。
    public static let maxFrames = 600

    private let lock = NSLock()
    private var frames: [Int] = []
    private var bits = [UInt8](repeating: 0, count: TileBitmap.byteCount)
    private var globalChanges = 0
    private var editorMs = 0
    private var activeMs = 0

    public init() {}

    /// 【11/6】編集画面だった時間を足す（タイマーごと）。
    public func addEditorTime(milliseconds: Int) {
        lock.lock()
        defer { lock.unlock() }
        editorMs += max(0, milliseconds)
    }

    /// 【11/6】小さな変化があった時間を足す（処理したフレームごと）。
    public func addActiveTime(milliseconds: Int) {
        lock.lock()
        defer { lock.unlock() }
        activeMs += max(0, milliseconds)
    }

    public func add(_ result: FrameResult) {
        lock.lock()
        defer { lock.unlock() }
        if frames.count < Self.maxFrames {
            frames.append(result.adoptedCount)
        }
        for index in result.adoptedTiles where (0..<TileBitmap.count).contains(index) {
            bits[index / 8] |= UInt8(1) << UInt8(7 - index % 8)
        }
        if result.isGlobalChange {
            globalChanges += 1
        }
    }

    /// 貯めた分を取り出して空にする。
    public func drain() -> Drained {
        lock.lock()
        defer { lock.unlock() }
        let drained = Drained(
            frames: frames,
            tiles: Data(bits),
            changedTiles: bits.reduce(0) { $0 + $1.nonzeroBitCount },
            globalChanges: globalChanges,
            editorMs: editorMs,
            activeMs: min(activeMs, editorMs)
        )
        frames = []
        bits = [UInt8](repeating: 0, count: TileBitmap.byteCount)
        globalChanges = 0
        editorMs = 0
        activeMs = 0
        return drained
    }
}
