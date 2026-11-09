import Foundation
import XCTest
@testable import TraceKit

/// 【11/6】全体画像の検出（T13 の A）と、撮った全体画像の残し方（T05 の6・7）の試験。
final class WholeCanvasTests: XCTestCase {
    // MARK: - 値が共通のファイルと同じか

    func testConfigMatchesSharedParams() throws {
        let url = VectorsTests.repoRoot.appendingPathComponent("shared/params/whole_canvas.json")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let config = WholeCanvasConfig()
        XCTAssertEqual(json["topBarPx"] as? Int, config.topBarPx)
        XCTAssertEqual(json["leftBarPx"] as? Int, config.leftBarPx)
        XCTAssertEqual(json["ringPx"] as? Int, config.ringPx)
        XCTAssertEqual(json["bgTol"] as? Int, config.bgTol)
        XCTAssertEqual(json["ringBgMin"] as? Double, config.ringBgMin)
        XCTAssertEqual(json["lineMin"] as? Double, config.lineMin)
        XCTAssertEqual(json["minAreaFrac"] as? Double, config.minAreaFrac)
        XCTAssertEqual(json["marginPx"] as? Int, config.marginPx)
        XCTAssertEqual(json["fillMin"] as? Double, config.fillMin)
        XCTAssertEqual(json["cornerFrac"] as? Double, config.cornerFrac)
        XCTAssertEqual(json["cornerMin"] as? Double, config.cornerMin)
        XCTAssertEqual(json["outsideMax"] as? Double, config.outsideMax)
        XCTAssertEqual(json["minIntervalSec"] as? Double, config.minIntervalSec)
        XCTAssertEqual(json["maxPerSession"] as? Int, config.maxPerSession)
        XCTAssertNil(json["uiMask"], "【11/6】uiMask は topBarPx・leftBarPx に替えた")
    }

    // MARK: - 実機の画面

    func testRealScreensAreDetectedLikePython() throws {
        let detector = WholeCanvasDetector()
        // Python（tools/prototypes/whole_canvas/check_real.py）の結果。縮小の仕方が違うので ±2px まで同じとみなす
        let expected: [(String, CanvasRect)] = [
            ("dark_blank_ipadportrait.jpg", CanvasRect(x: 104, y: 186, width: 503, height: 710)),
            ("dark_blank_ipadlandscape.jpg", CanvasRect(x: 186, y: 105, width: 710, height: 503)),
        ]
        for (name, rect) in expected {
            let gray = try TestImages.loadGray(TestImages.real(name))
            let result = detector.detect(gray)
            XCTAssertEqual(result.reason, "ok", name)
            let found = try XCTUnwrap(result.rect, name)
            XCTAssertLessThanOrEqual(abs(found.x - rect.x), 2, "\(name) \(found)")
            XCTAssertLessThanOrEqual(abs(found.y - rect.y), 2, "\(name) \(found)")
            XCTAssertLessThanOrEqual(abs(found.width - rect.width), 2, "\(name) \(found)")
            XCTAssertLessThanOrEqual(abs(found.height - rect.height), 2, "\(name) \(found)")
        }
    }

    // MARK: - 合成の画面（tools/prototypes/whole_canvas と同じ作り方。Python で同じ結果になることを確かめてある）

    /// 1024×768 の暗い画面に、上のバー（33px）・サイドバー（幅38px）と、白いキャンバスを置く。
    private func screen(
        canvas: (x: Double, y: Double, width: Double, height: Double)?,
        tilt degrees: Double = 0,
        reference: Bool = false
    ) -> GrayImage {
        let width = 1024
        let height = 768
        var pixels = [UInt8](repeating: 40, count: width * height)
        if let canvas {
            let cx = canvas.x + canvas.width / 2
            let cy = canvas.y + canvas.height / 2
            let angle = degrees * Double.pi / 180
            let lines = (0..<6).map { Int(canvas.y + canvas.height * Double($0 + 1) / 8) }
            for y in 0..<height {
                for x in 0..<width {
                    let dx = Double(x) - cx
                    let dy = Double(y) - cy
                    let u = dx * cos(angle) + dy * sin(angle)
                    let v = -dx * sin(angle) + dy * cos(angle)
                    guard abs(u) <= canvas.width / 2, abs(v) <= canvas.height / 2 else { continue }
                    let onLine = lines.contains { abs(y - $0) <= 1 }
                        && Double(x) > canvas.x + canvas.width * 0.1 && Double(x) < canvas.x + canvas.width * 0.8
                    pixels[y * width + x] = onLine ? 30 : 255
                }
            }
        }
        if reference {
            for y in 560..<700 {
                for x in 820..<990 {
                    pixels[y * width + x] = 120
                }
            }
        }
        for y in 0..<33 {
            for x in 0..<width {
                pixels[y * width + x] = 28
            }
        }
        for i in 0..<8 {
            for y in 8..<26 {
                for x in (20 + i * 40)..<(40 + i * 40) {
                    pixels[y * width + x] = 200
                }
            }
        }
        let middle = Int(0.54 * Double(height))
        for y in max(33, middle - 192)..<min(height, middle + 193) {
            for x in 0..<38 {
                pixels[y * width + x] = 70
            }
        }
        return GrayImage(pixels: pixels, width: width, height: height)
    }

    func testSyntheticScreensMatchPrototype() {
        let detector = WholeCanvasDetector()
        let whole = detector.detect(screen(canvas: (212, 159, 600, 450)))
        XCTAssertEqual(whole.reason, "ok")
        XCTAssertEqual(whole.rect, CanvasRect(x: 212, y: 159, width: 601, height: 451))
        XCTAssertEqual(whole.background, 40)

        XCTAssertEqual(detector.detect(screen(canvas: (0, 33, 1024, 735))).reason, "no-rect", "画面いっぱい")
        XCTAssertEqual(detector.detect(screen(canvas: (-200, -100, 1400, 1000))).reason, "no-rect", "拡大中")
        XCTAssertEqual(detector.detect(screen(canvas: (212, 20, 600, 450))).reason, "ui-overlap", "上のバーに重なる")
        XCTAssertEqual(detector.detect(screen(canvas: (212, 159, 600, 450), tilt: 1)).reason, "tilted", "傾き1°")
        XCTAssertEqual(detector.detect(screen(canvas: (150, 120, 600, 450), reference: true)).reason, "fill", "参照ウィンドウ")
        XCTAssertNil(detector.detect(screen(canvas: nil)).rect, "キャンバスなし")
    }

    func testNormalizedRect() {
        let rect = CanvasRect(x: 104, y: 186, width: 503, height: 710)
        XCTAssertEqual(rect.normalized(width: 712, height: 1024), [0.1461, 0.1816, 0.7065, 0.6934])
    }

    // MARK: - 【T15b】表示のときの切り抜き

    func testCropPixelRect() {
        // 割合 → 画素。内側に2画素ずつ寄せる
        XCTAssertEqual(CanvasCrop.pixelRect([0.1, 0.1, 0.8, 0.8], width: 1000, height: 750),
                       CanvasRect(x: 102, y: 77, width: 796, height: 596))
        XCTAssertEqual(CanvasCrop.pixelRect([0.1461, 0.1816, 0.7065, 0.6934], width: 712, height: 1024, inset: 0),
                       CanvasRect(x: 104, y: 186, width: 503, height: 710))
        // 誤差で少しはみ出すのは、画像の端で止める
        XCTAssertEqual(CanvasCrop.pixelRect([-0.002, 0.2, 0.5, 0.805], width: 1000, height: 1000, inset: 0),
                       CanvasRect(x: 0, y: 200, width: 498, height: 800))
    }

    func testCropFallsBackToWholeImage() {
        XCTAssertNil(CanvasCrop.pixelRect(nil, width: 1024, height: 768), "四角形なし")
        XCTAssertNil(CanvasCrop.pixelRect([], width: 1024, height: 768), "空")
        XCTAssertNil(CanvasCrop.pixelRect([0.1, 0.1, 0.8], width: 1024, height: 768), "形が違う")
        XCTAssertNil(CanvasCrop.pixelRect([0.5, 0.5, 0.8, 0.8], width: 1024, height: 768), "範囲の外")
        XCTAssertNil(CanvasCrop.pixelRect([0.1, 0.1, 0, 0.5], width: 1024, height: 768), "幅0")
        XCTAssertNil(CanvasCrop.pixelRect([0.1, 0.1, .nan, 0.5], width: 1024, height: 768), "数でない")
        XCTAssertNil(CanvasCrop.pixelRect([0.4, 0.4, 0.2, 0.2], width: 1024, height: 768), "小さすぎる")
        XCTAssertNil(CanvasCrop.pixelRect([0, 0, 1, 1], width: 1024, height: 768), "ほぼ画面全体")
        XCTAssertNil(CanvasCrop.pixelRect([0.1, 0.1, 0.8, 0.8], width: 0, height: 768), "画像の大きさ0")
    }

    func testRectForSha() {
        var record = WholeRecord()
        record.items = [WholeItem(sha: "a", frameTime: "t1", rect: [0.1, 0.1, 0.8, 0.8])]
        record.latest = WholeItem(sha: "b", frameTime: "t2", rect: [0.2, 0.2, 0.6, 0.6])
        record.end = "b"
        XCTAssertEqual(record.rect(for: "a"), [0.1, 0.1, 0.8, 0.8])
        XCTAssertEqual(record.rect(for: "b"), [0.2, 0.2, 0.6, 0.6])
        XCTAssertNil(record.rect(for: "c"))
    }

    // MARK: - WholeCapture（いつ検出をかけ、どれを残すか）

    private func date(_ seconds: Double) -> Date {
        Date(timeIntervalSinceReferenceDate: 1_000 + seconds)
    }

    func testCheckOnlyWhenStillEditorAndChanged() {
        let capture = WholeCapture()
        XCTAssertFalse(capture.shouldCheck(now: date(5)), "フレームがまだない")
        capture.frameProcessed(changed: true, editor: true, at: date(0))
        XCTAssertFalse(capture.shouldCheck(now: date(0.5)), "止まってから1秒たっていない")
        XCTAssertTrue(capture.shouldCheck(now: date(1.0)))
        capture.markChecked()
        XCTAssertFalse(capture.shouldCheck(now: date(3)), "前に検出をかけてから変化がない")

        capture.frameProcessed(changed: true, editor: false, at: date(4))
        XCTAssertFalse(capture.shouldCheck(now: date(6)), "編集画面ではない")
        capture.frameProcessed(changed: false, editor: true, at: date(6.5))
        XCTAssertTrue(capture.shouldCheck(now: date(7)), "編集画面に戻った（変化は 4秒のときに見えている）")
    }

    func testFirstIsStartAndIntervalKeepsTheRest() {
        let capture = WholeCapture()
        let first = capture.add(sha: "a", frameTime: date(1), rect: [0.1, 0.1, 0.8, 0.8])
        XCTAssertEqual(first, WholeCapture.Decision(isStart: true, kept: true, discard: nil))
        XCTAssertEqual(capture.record.start, "a")

        // 60秒以内: 残さず、いちばん新しいものとしてだけ持つ
        XCTAssertEqual(capture.add(sha: "b", frameTime: date(30), rect: []), WholeCapture.Decision(isStart: false, kept: false, discard: nil))
        // その次が来たら、残さなかった b は消してよい
        XCTAssertEqual(capture.add(sha: "c", frameTime: date(50), rect: []), WholeCapture.Decision(isStart: false, kept: false, discard: "b"))
        // 前に残した a から60秒以上: 残す（c は消してよい）
        XCTAssertEqual(capture.add(sha: "d", frameTime: date(61), rect: []), WholeCapture.Decision(isStart: false, kept: true, discard: "c"))
        XCTAssertEqual(capture.record.items.map(\.sha), ["a", "d"])
        XCTAssertEqual(capture.record.latest?.sha, "d")

        // 終えると、いちばん新しいものが終了画面になる
        _ = capture.add(sha: "e", frameTime: date(80), rect: [])
        XCTAssertEqual(capture.finish(), "e")
        XCTAssertEqual(capture.record.items.map(\.sha), ["a", "d", "e"])
        XCTAssertEqual(capture.record.end, "e")
        XCTAssertEqual(capture.count, 3)
    }

    func testFinishWithoutNewerImageKeepsLastAsEnd() {
        let capture = WholeCapture()
        _ = capture.add(sha: "a", frameTime: date(1), rect: [])
        XCTAssertEqual(capture.finish(), "a")
        XCTAssertEqual(capture.record.items.map(\.sha), ["a"])
        XCTAssertEqual(capture.record.start, "a")
        XCTAssertEqual(capture.record.end, "a")

        let empty = WholeCapture()
        XCTAssertNil(empty.finish(), "全体を一度も表示しなければ、終了画面はない")
    }

    func testMaxPerSession() {
        var config = WholeCanvasConfig()
        config.maxPerSession = 3
        let capture = WholeCapture(config: config)
        for i in 0..<5 {
            _ = capture.add(sha: "s\(i)", frameTime: date(Double(i) * 61), rect: [])
        }
        XCTAssertEqual(capture.record.items.map(\.sha), ["s0", "s1", "s2"])
        XCTAssertEqual(capture.record.latest?.sha, "s4")
    }

    func testWholeRecordJSONShape() throws {
        let capture = WholeCapture()
        _ = capture.add(sha: "a", frameTime: Date(timeIntervalSinceReferenceDate: 1), rect: [0.1, 0.2, 0.5, 0.6])
        let json = String(decoding: try Canonical.encodeSorted(capture.record), as: UTF8.self)
        XCTAssertEqual(
            json,
            #"{"end":null,"items":[{"frameTime":"2001-01-01T00:00:01.000Z","rect":[0.1,0.2,0.5,0.6],"sha":"a"}],"latest":{"frameTime":"2001-01-01T00:00:01.000Z","rect":[0.1,0.2,0.5,0.6],"sha":"a"},"start":"a"}"#
        )
        XCTAssertEqual(try JSONDecoder().decode(WholeRecord.self, from: Data(json.utf8)), capture.record)
    }
}
