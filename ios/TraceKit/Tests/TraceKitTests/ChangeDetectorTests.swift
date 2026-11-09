import Foundation
import XCTest
@testable import TraceKit

/// T05 の「変化の判定」の試験（tasks/T05_録画拡張_画面の変化.md の単体テスト）。
/// 128×96 の合成画像を使う（タイルは 4×4 画素）。
final class ChangeDetectorTests: XCTestCase {
    private let width = 128
    private let height = 96

    private func time(_ index: Int) -> Date {
        Date(timeIntervalSinceReferenceDate: Double(index) / 10)
    }

    private func blank() -> [UInt8] {
        [UInt8](repeating: 255, count: width * height)
    }

    /// (x0, y0) から w×h の黒い四角を描く。
    private func drawing(_ image: [UInt8], x0: Int, y0: Int, w: Int = 4, h: Int = 4) -> [UInt8] {
        var result = image
        for y in y0..<(y0 + h) {
            for x in x0..<(x0 + w) {
                result[y * width + x] = 0
            }
        }
        return result
    }

    private func run(_ images: [[UInt8]], detector: ChangeDetector = ChangeDetector()) -> [FrameResult] {
        images.enumerated().map { index, image in
            detector.process(luma: image, width: width, height: height, frameTime: time(index))
        }
    }

    func testDotIsAdoptedOnSecondFrameOnly() {
        let dot = drawing(blank(), x0: 40, y0: 40)
        let results = run([blank(), dot, dot, dot, dot])
        XCTAssertTrue(results[0].isFirst)
        XCTAssertEqual(results.map(\.adoptedCount), [0, 0, 1, 0, 0])
        // (40, 40) はタイル (10, 10) → 番号 330
        XCTAssertEqual(results[2].adoptedTiles, [330])
        // 1回目に見えたときは「違って見えた」が、まだ採用しない
        XCTAssertEqual(results[1].differingCount, 1)
    }

    func testSingleFrameGlitchIsNotAdopted() {
        let glitch = drawing(blank(), x0: 40, y0: 40)
        let results = run([blank(), glitch, blank(), blank()])
        XCTAssertEqual(results.map(\.adoptedCount), [0, 0, 0, 0])
    }

    func testShortLineDrawnInOneFrameIsAdopted() {
        // 1フレームで描き終わり、以後は変わらない短い線（横20画素・縦1画素）
        let line = drawing(blank(), x0: 30, y0: 50, w: 20, h: 1)
        let results = run([blank(), line, line, line])
        XCTAssertEqual(results[1].adoptedCount, 0)
        // x=30〜49 はタイル7〜12にかかるが、3画素以上かかるのは8〜11の4つ（y=50 はタイルの行12）
        XCTAssertEqual(results[2].adoptedTiles, [12 * 32 + 8, 12 * 32 + 9, 12 * 32 + 10, 12 * 32 + 11])
        XCTAssertEqual(results[3].adoptedCount, 0)
    }

    func testBucketFillOverSixtyPercentIsGlobalChange() {
        var filled = blank()
        for y in 0..<height {
            for x in 0..<Int(Double(width) * 0.6) {
                filled[y * width + x] = 60
            }
        }
        let results = run([blank(), filled, filled, filled])
        XCTAssertGreaterThanOrEqual(results[2].adoptedCount, 231)
        XCTAssertTrue(results[2].isGlobalChange)
        XCTAssertFalse(results[1].isGlobalChange)
        XCTAssertFalse(results[3].isGlobalChange)
    }

    func testRemainderPixelsBelongToLastColumnAndRow() {
        // 130×98: タイルは 4×4。余りの画素（x=128〜129、y=96〜97）は最後の列・行のタイルに入る
        let w = 130
        let h = 98
        let base = [UInt8](repeating: 255, count: w * h)
        var corner = base
        for y in 96..<98 {
            for x in 126..<130 {
                corner[y * w + x] = 0
            }
        }
        let detector = ChangeDetector()
        _ = detector.process(luma: base, width: w, height: h, frameTime: time(0))
        _ = detector.process(luma: corner, width: w, height: h, frameTime: time(1))
        let result = detector.process(luma: corner, width: w, height: h, frameTime: time(2))
        XCTAssertEqual(result.adoptedTiles, [767])
    }

    func testRowPaddingIsIgnored() {
        // 1行に8バイトの詰め物がある画像でも、同じ結果になる
        let stride = width + 8
        func padded(_ image: [UInt8]) -> [UInt8] {
            var result = [UInt8](repeating: 7, count: stride * height)
            for y in 0..<height {
                for x in 0..<width {
                    result[y * stride + x] = image[y * width + x]
                }
            }
            return result
        }
        let dot = drawing(blank(), x0: 40, y0: 40)
        let detector = ChangeDetector()
        let counts = [blank(), dot, dot].enumerated().map { index, image -> Int in
            let bytes = padded(image)
            return bytes.withUnsafeBufferPointer { buffer in
                detector.process(
                    width: width, height: height, bytesPerRow: stride,
                    pixels: buffer.baseAddress!, frameTime: time(index)
                ).adoptedCount
            }
        }
        XCTAssertEqual(counts, [0, 0, 1])
    }

    func testSizeChangeResetsBase() {
        let detector = ChangeDetector()
        _ = detector.process(luma: blank(), width: width, height: height, frameTime: time(0))
        let other = [UInt8](repeating: 0, count: 96 * 128)
        let result = detector.process(luma: other, width: 96, height: 128, frameTime: time(1))
        XCTAssertTrue(result.isFirst)
        XCTAssertEqual(result.adoptedCount, 0)
    }

    func testAccumulatorBitmapMatchesSharedSpec() {
        let dot = drawing(blank(), x0: 40, y0: 40)
        let accumulator = ActivityAccumulator()
        for result in run([blank(), dot, dot]) {
            accumulator.add(result)
        }
        let drained = accumulator.drain()
        XCTAssertEqual(drained.frames, [0, 0, 1])
        XCTAssertEqual(drained.changedTiles, 1)
        XCTAssertEqual(drained.globalChanges, 0)
        XCTAssertEqual(drained.tiles.count, 96)
        // 番号 330 は byte[41] の第 (7 - 330 % 8) = 5 ビット（共通仕様4章）
        XCTAssertEqual(drained.tiles[41], 0b0010_0000)
        XCTAssertEqual(drained.tiles, TileBitmap.make([330]))
        XCTAssertEqual(TileBitmap.indices(drained.tiles), [330])

        // 取り出した後は空になる
        let empty = accumulator.drain()
        XCTAssertEqual(empty.frames, [])
        XCTAssertEqual(empty.changedTiles, 0)
        XCTAssertEqual(empty.tiles, Data(count: 96))
    }

    func testAccumulatorCountsGlobalChangesAndCapsFrames() {
        let accumulator = ActivityAccumulator()
        let global = FrameResult(
            frameTime: time(0), adoptedTiles: Array(0..<300), differingCount: 300, isFirst: false, isGlobalChange: true
        )
        for _ in 0..<(ActivityAccumulator.maxFrames + 5) {
            accumulator.add(global)
        }
        let drained = accumulator.drain()
        XCTAssertEqual(drained.frames.count, ActivityAccumulator.maxFrames)
        XCTAssertEqual(drained.globalChanges, ActivityAccumulator.maxFrames + 5)
        XCTAssertEqual(drained.changedTiles, 300)
    }

    // MARK: - 【11/6】無視するタイルと、時間の集計

    func testIgnoredTilesAreNotCounted() {
        let detector = ChangeDetector()
        // (40, 40) のタイルは 330。これを数えないようにする
        detector.setIgnoredTiles([330])
        let dot = drawing(blank(), x0: 40, y0: 40)
        let other = drawing(dot, x0: 80, y0: 60)
        let results = run([blank(), dot, dot, other, other], detector: detector)
        XCTAssertEqual(results.map(\.adoptedCount), [0, 0, 0, 0, 1])
        XCTAssertEqual(results[1].differingCount, 0)
        XCTAssertEqual(results[4].adoptedTiles, [15 * 32 + 20])
    }

    func testUITilesFollowDisplayOrientation() {
        // 475×683 の縦長のバッファ。長辺1024px のとき上 35px・左 42px → このバッファでは上 23px・左 28px
        let portrait = FrameGeometry.uiTiles(bufferWidth: 475, bufferHeight: 683, rotation: 0, topBarPx: 35, leftBarPx: 42)
        // 縦持ち: 上の1行（タイルの高さ 28px）と、左の3列（タイルの幅 14px。左 28.01px にかかる3列目まで）
        XCTAssertTrue(portrait.contains(0 * 32 + 10))
        XCTAssertTrue(portrait.contains(10 * 32 + 0))
        XCTAssertTrue(portrait.contains(10 * 32 + 2))
        XCTAssertFalse(portrait.contains(10 * 32 + 3))
        XCTAssertFalse(portrait.contains(1 * 32 + 10))
        XCTAssertEqual(portrait.count, 32 + 23 * 3)

        // 横持ち（時計回りに90度回して表示）: 表示の上はバッファの左の列、表示の左はバッファの下の行
        let landscape = FrameGeometry.uiTiles(bufferWidth: 475, bufferHeight: 683, rotation: 90, topBarPx: 35, leftBarPx: 42)
        XCTAssertTrue(landscape.contains(10 * 32 + 0))
        XCTAssertTrue(landscape.contains(10 * 32 + 1))
        XCTAssertFalse(landscape.contains(10 * 32 + 2))
        XCTAssertTrue(landscape.contains(23 * 32 + 10))
        XCTAssertFalse(landscape.contains(0 * 32 + 10))
    }

    func testDisplayAndBufferPointsAreInverse() {
        for rotation in [0, 90, 180, 270] {
            for (x, y) in [(0, 0), (10, 3), (474, 682), (100, 600)] {
                let display = FrameGeometry.displayPoint(x: x, y: y, bufferWidth: 475, bufferHeight: 683, rotation: rotation)
                let size = FrameGeometry.displaySize(bufferWidth: 475, bufferHeight: 683, rotation: rotation)
                XCTAssertTrue((0..<size.width).contains(display.x) && (0..<size.height).contains(display.y))
                let back = FrameGeometry.bufferPoint(
                    x: display.x, y: display.y, bufferWidth: 475, bufferHeight: 683, rotation: rotation
                )
                XCTAssertTrue(back == (x, y), "rotation=\(rotation) (\(x),\(y)) → \(display) → \(back)")
            }
        }
        // 時計回りに90度: バッファの左上は、表示の右上
        XCTAssertTrue(FrameGeometry.displayPoint(x: 0, y: 0, bufferWidth: 475, bufferHeight: 683, rotation: 90) == (682, 0))
    }

    func testAccumulatorKeepsEditorAndActiveTime() {
        let accumulator = ActivityAccumulator()
        accumulator.addEditorTime(milliseconds: 4_000)
        accumulator.addActiveTime(milliseconds: 1_500)
        accumulator.addActiveTime(milliseconds: 5_000)
        let drained = accumulator.drain()
        XCTAssertEqual(drained.editorMs, 4_000)
        // 小さな変化の時間は、編集画面の時間を超えない
        XCTAssertEqual(drained.activeMs, 4_000)
        let empty = accumulator.drain()
        XCTAssertEqual(empty.editorMs, 0)
        XCTAssertEqual(empty.activeMs, 0)
    }
}
