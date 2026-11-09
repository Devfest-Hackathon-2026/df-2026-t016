import Foundation

/// 全体画像の判定の値（`shared/params/whole_canvas.json` と同じ。変えるときは両方を同じ PR で直す。T13）。
/// 画素で書く値は、表示の向きで長辺1024px の画像のときの値。
public struct WholeCanvasConfig: Equatable {
    /// 【11/6】無視する領域: 上のバー（上から）と左のサイドバー（左から、上から下まで）。
    public var topBarPx = 35
    public var leftBarPx = 42
    public var ringPx = 4
    public var bgTol = 8
    public var ringBgMin = 0.60
    public var lineMin = 0.10
    public var minAreaFrac = 0.15
    public var marginPx = 4
    public var fillMin = 0.85
    public var cornerFrac = 0.02
    public var cornerMin = 0.90
    public var outsideMax = 0.03
    /// 途中の全体画像は、前に残したものからこの秒数以上あける。
    public var minIntervalSec: TimeInterval = 60
    /// 1セッションで残す全体画像の上限。
    public var maxPerSession = 120
    /// 途中の全体画像に対応した受付APIへ送る。
    public var sendWhole = true

    public init() {}
}

/// キャンバスの四角形（画素）。
public struct CanvasRect: Equatable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// 画面に対する割合 `[x, y, 幅, 高さ]`（小数4桁）。`whole.json` の `rect`。
    public func normalized(width screenWidth: Int, height screenHeight: Int) -> [Double] {
        func round4(_ value: Double) -> Double { (value * 10_000).rounded() / 10_000 }
        return [
            round4(Double(x) / Double(screenWidth)),
            round4(Double(y) / Double(screenHeight)),
            round4(Double(width) / Double(screenWidth)),
            round4(Double(height) / Double(screenHeight)),
        ]
    }
}

/// 検出の結果。`reason` は `ok` か、外れた理由（`tools/prototypes/whole_canvas/proto.py` と同じ言葉）。
public struct WholeCanvasResult: Equatable {
    public var rect: CanvasRect?
    public var reason: String
    public var background: Int?
}

/// キャンバス全体が画面に収まっているかを、決まったルールで調べる（T13 の「A. キャンバスの検出」。AI は使わない）。
/// 入力は表示の向きのグレースケール画像（長辺1024px）。
public final class WholeCanvasDetector {
    public let config: WholeCanvasConfig

    public init(config: WholeCanvasConfig = WholeCanvasConfig()) {
        self.config = config
    }

    public func detect(_ image: GrayImage) -> WholeCanvasResult {
        let width = image.width
        let height = image.height
        let top = min(max(config.topBarPx, 0), height)
        let left = min(max(config.leftBarPx, 0), width)
        let tolerance = config.bgTol
        func fail(_ reason: String, _ background: Int? = nil) -> WholeCanvasResult {
            WholeCanvasResult(rect: nil, reason: reason, background: background)
        }

        return image.pixels.withUnsafeBufferPointer { buffer -> WholeCanvasResult in
            let p = buffer.baseAddress!

            // 1〜2. 画面の縁（無視する領域を除く）の明るさの最頻値を、背景の色とする
            var histogram = [Int](repeating: 0, count: 256)
            var ringCount = 0
            let ring = config.ringPx
            for y in top..<height {
                let row = p + y * width
                if y < ring || y >= height - ring {
                    for x in left..<width {
                        histogram[Int(row[x])] += 1
                    }
                    ringCount += width - left
                } else {
                    // 左の縁は、サイドバー（無視する領域）より右にあるときだけ数える
                    if left < min(ring, width) {
                        for x in left..<min(ring, width) {
                            histogram[Int(row[x])] += 1
                            ringCount += 1
                        }
                    }
                    for x in max(left, width - ring)..<width {
                        histogram[Int(row[x])] += 1
                        ringCount += 1
                    }
                }
            }
            guard ringCount > 0 else { return fail("ring") }
            var background = 0
            for value in 1..<256 where histogram[value] > histogram[background] {
                background = value
            }
            var nearBackground = 0
            for value in max(0, background - tolerance)...min(255, background + tolerance) {
                nearBackground += histogram[value]
            }
            if Double(nearBackground) / Double(ringCount) < config.ringBgMin {
                return fail("ring-not-bg", background)
            }

            // 3〜4. 背景でない画素を、行・列ごとに数える
            func isForeground(_ value: UInt8) -> Bool {
                let difference = Int(value) - background
                return difference > tolerance || -difference > tolerance
            }
            var rowCounts = [Int](repeating: 0, count: height)
            var columnCounts = [Int](repeating: 0, count: width)
            var foregroundTotal = 0
            for y in top..<height {
                let row = p + y * width
                var count = 0
                for x in left..<width where isForeground(row[x]) {
                    count += 1
                    columnCounts[x] += 1
                }
                rowCounts[y] = count
                foregroundTotal += count
            }
            let rowNeed = config.lineMin * Double(width)
            let columnNeed = config.lineMin * Double(height)
            guard
                let y0 = rowCounts.firstIndex(where: { Double($0) >= rowNeed }),
                let y1 = rowCounts.lastIndex(where: { Double($0) >= rowNeed }),
                let x0 = columnCounts.firstIndex(where: { Double($0) >= columnNeed }),
                let x1 = columnCounts.lastIndex(where: { Double($0) >= columnNeed })
            else { return fail("no-rect", background) }
            let rectWidth = x1 - x0 + 1
            let rectHeight = y1 - y0 + 1

            // 5. 大きさ
            if Double(rectWidth * rectHeight) < config.minAreaFrac * Double(width * height) {
                return fail("small", background)
            }
            // 6. 上下左右の余白と、UI に隠れていないこと
            let margin = config.marginPx
            if x0 < margin || y0 < margin || width - 1 - x1 < margin || height - 1 - y1 < margin {
                return fail("margin", background)
            }
            if (top > 0 && max(0, y0 - margin) < top) || (left > 0 && max(0, x0 - margin) < left) {
                return fail("ui-overlap", background)
            }

            // 7. 四角形の中が埋まっていること
            func foregroundCount(x: Int, y: Int, width w: Int, height h: Int) -> Int {
                var count = 0
                for yy in y..<(y + h) {
                    let row = p + yy * width
                    for xx in x..<(x + w) where isForeground(row[xx]) {
                        count += 1
                    }
                }
                return count
            }
            let inside = foregroundCount(x: x0, y: y0, width: rectWidth, height: rectHeight)
            if Double(inside) / Double(rectWidth * rectHeight) < config.fillMin {
                return fail("fill", background)
            }

            // 8. 四隅が埋まっていること（傾いていない）
            let cornerWidth = max(2, Int((Double(rectWidth) * config.cornerFrac).rounded()))
            let cornerHeight = max(2, Int((Double(rectHeight) * config.cornerFrac).rounded()))
            let corners = [
                (x0, y0), (x1 - cornerWidth + 1, y0),
                (x0, y1 - cornerHeight + 1), (x1 - cornerWidth + 1, y1 - cornerHeight + 1),
            ]
            for (cx, cy) in corners {
                let filled = foregroundCount(x: cx, y: cy, width: cornerWidth, height: cornerHeight)
                if Double(filled) / Double(cornerWidth * cornerHeight) < config.cornerMin {
                    return fail("tilted", background)
                }
            }

            // 9. 四角形の外に、背景でないものがほとんどないこと
            let free = (width - left) * (height - top) - rectWidth * rectHeight
            if Double(foregroundTotal - inside) / Double(max(free, 1)) > config.outsideMax {
                return fail("outside", background)
            }

            return WholeCanvasResult(
                rect: CanvasRect(x: x0, y: y0, width: rectWidth, height: rectHeight),
                reason: "ok",
                background: background
            )
        }
    }
}

/// `whole.json` の1件。
public struct WholeItem: Codable, Equatable {
    public var sha: String
    public var frameTime: String
    /// キャンバスの四角形 `[x, y, 幅, 高さ]`（表示の向きの画面に対する割合）。
    public var rect: [Double]

    public init(sha: String, frameTime: String, rect: [Double]) {
        self.sha = sha
        self.frameTime = frameTime
        self.rect = rect
    }
}

/// 【T15b】全体画像を表示するときだけ、キャンバスの部分を切り抜く範囲。保存した画像（署名した画像）は変えない。
public enum CanvasCrop {
    /// 割合の四角形 `[x, y, 幅, 高さ]` を、`width`×`height` の画像の画素の範囲にする。
    /// 内側に `inset` 画素ずつ寄せる（四角形の端に背景が1画素残るのを防ぐ）。
    /// 四角形が無い・形が違う・範囲の外・小さすぎる・ほぼ画面全体なら `nil`（元の画像をそのまま出す）。
    public static func pixelRect(_ rect: [Double]?, width: Int, height: Int, inset: Int = 2) -> CanvasRect? {
        guard let rect, rect.count == 4, width > 0, height > 0, rect.allSatisfy(\.isFinite) else { return nil }
        let (x, y, w, h) = (rect[0], rect[1], rect[2], rect[3])
        let tolerance = 0.01
        guard x >= -tolerance, y >= -tolerance, w > 0, h > 0,
              x + w <= 1 + tolerance, y + h <= 1 + tolerance else { return nil }
        // 検出の下限（画面の15%）より小さいものは使わない。ほぼ全体なら切り抜く意味がない
        guard w * h >= 0.1, !(w >= 0.98 && h >= 0.98) else { return nil }
        var x0 = min(max(Int((x * Double(width)).rounded()), 0), width)
        var y0 = min(max(Int((y * Double(height)).rounded()), 0), height)
        var x1 = min(max(Int(((x + w) * Double(width)).rounded()), 0), width)
        var y1 = min(max(Int(((y + h) * Double(height)).rounded()), 0), height)
        if x1 - x0 > inset * 2 + 16 { x0 += inset; x1 -= inset }
        if y1 - y0 > inset * 2 + 16 { y0 += inset; y1 -= inset }
        guard x1 > x0, y1 > y0 else { return nil }
        return CanvasRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}

extension WholeRecord {
    /// 【T15b】その画像のキャンバスの四角形（`items` か `latest` に同じ sha があれば）。
    public func rect(for sha: String) -> [Double]? {
        if let latest, latest.sha == sha { return latest.rect }
        return items.last { $0.sha == sha }?.rect
    }
}

/// `sessions/{sid}/whole.json`（共通仕様8章）。
public struct WholeRecord: Codable, Equatable {
    /// 残した全体画像（最初の1枚と、そこから60秒以上あけたもの。終了時に最後の1枚を足す）。
    public var items: [WholeItem] = []
    /// いちばん新しく撮った全体画像（`items` に入っていないこともある）。
    public var latest: WholeItem?
    public var start: String?
    public var end: String?

    public init() {}

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(items, forKey: .items)
        // 決まっていないものも、キーを残して null にする
        try container.encode(latest, forKey: .latest)
        try container.encode(start, forKey: .start)
        try container.encode(end, forKey: .end)
    }
}

/// 【11/6】いつキャンバスの検出をかけ、撮った全体画像をどう残すか（純粋なロジック。T05 の6・7）。
///
/// - 検出をかけるのは、画面が `stableAfter` 秒以上止まり、最後に処理したフレームが編集画面で、
///   前に検出をかけてから基準と違うタイルが見えたことがあるときだけ。
/// - 1枚目は開始画面。2枚目からは、前に残したものから `minIntervalSec` 以上あけて残す（`maxPerSession` まで）。
///   残さなかったものも `latest` に置き、録画を終えるときに終了画面にする。
///
/// 1つの直列キューから呼ぶこと（スレッドセーフではない）。
public final class WholeCapture {
    public struct Decision: Equatable {
        /// 開始画面になった（1枚目）。
        public var isStart: Bool
        /// `items` に残した。
        public var kept: Bool
        /// 前の `latest` で、もう使わないので消してよい画像。
        public var discard: String?
    }

    public let config: WholeCanvasConfig
    public let stableAfter: TimeInterval
    public private(set) var record = WholeRecord()
    /// 最後に処理したフレームが編集画面だったか。
    public private(set) var editor = false
    private var lastChangeAt: Date?
    private var changedSinceCheck = false
    private var lastKeptAt: Date?

    public init(config: WholeCanvasConfig = WholeCanvasConfig(), stableAfter: TimeInterval = 1.0) {
        self.config = config
        self.stableAfter = stableAfter
    }

    /// 残した全体画像の数（`broadcast.status.wholeCount`）。
    public var count: Int { record.items.count }

    /// フレームを処理するたびに呼ぶ。`changed` は、基準と違うタイルが見えたか（最初のフレームも true）。
    public func frameProcessed(changed: Bool, editor: Bool, at time: Date) {
        if changed {
            lastChangeAt = time
            changedSinceCheck = true
        }
        self.editor = editor
    }

    /// タイマーごとに呼ぶ。true なら、今の写しにキャンバスの検出をかける。
    public func shouldCheck(now: Date) -> Bool {
        guard editor, changedSinceCheck, let lastChangeAt else { return false }
        return now.timeIntervalSince(lastChangeAt) >= stableAfter
    }

    /// 検出をかけたら（結果にかかわらず）呼ぶ。次に画面が変わるまで、もう検出をかけない。
    public func markChecked() {
        changedSinceCheck = false
    }

    /// キャンバス全体が映っていたので撮った。
    public func add(sha: String, frameTime: Date, rect: [Double]) -> Decision {
        let item = WholeItem(sha: sha, frameTime: Canonical.timeString(frameTime), rect: rect)
        var discard: String?
        if let previous = record.latest, previous.sha != sha, !record.items.contains(where: { $0.sha == previous.sha }) {
            discard = previous.sha
        }
        record.latest = item

        guard let lastKeptAt else {
            record.items.append(item)
            record.start = sha
            self.lastKeptAt = frameTime
            return Decision(isStart: true, kept: true, discard: discard)
        }
        if record.items.count < config.maxPerSession,
           frameTime.timeIntervalSince(lastKeptAt) >= config.minIntervalSec,
           record.items.last?.sha != sha {
            record.items.append(item)
            self.lastKeptAt = frameTime
            return Decision(isStart: false, kept: true, discard: discard)
        }
        return Decision(isStart: false, kept: false, discard: discard)
    }

    /// 録画を終えるときに呼ぶ。`latest` を終了画面にして、その sha を返す（全体画像がなければ `nil`）。
    @discardableResult
    public func finish() -> String? {
        if let latest = record.latest, record.items.last?.sha != latest.sha {
            record.items.append(latest)
        }
        record.end = record.items.last?.sha
        return record.end
    }
}
