import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import TraceKit

/// 【11/6】編集画面の判定（上のバーの左側を見本と比べる）の試験。実機の画面と、それを加工した画面を使う。
final class EditorScreenTests: XCTestCase {
    private let detector = EditorScreenDetector()

    private func portrait() throws -> GrayImage {
        try TestImages.loadGray(TestImages.real("dark_blank_ipadportrait.jpg"))
    }

    func testConfigAndTemplateMatchSharedFiles() throws {
        let url = VectorsTests.repoRoot.appendingPathComponent("shared/params/editor_screen.json")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let config = EditorScreenConfig()
        XCTAssertEqual(json["regionPx"] as? [Int], [config.regionX, config.regionY, EditorTemplate.width, EditorTemplate.height])
        XCTAssertEqual(json["brightDelta"] as? Int, config.brightDelta)
        XCTAssertEqual(json["darkBand"] as? Int, config.darkBand)
        XCTAssertEqual(json["brightTol"] as? Int, config.brightTol)
        XCTAssertEqual(json["darkTol"] as? Int, config.darkTol)
        XCTAssertEqual(json["brightMin"] as? Double, config.brightMin)
        XCTAssertEqual(json["darkMin"] as? Double, config.darkMin)

        // 見本（Swift に埋め込んだもの）が、shared/vectors/editor/bar_left.png と同じ（色の変換をかけずに、PNG の画素をそのまま比べる）
        let url2 = VectorsTests.repoRoot.appendingPathComponent("shared/vectors/editor/bar_left.png")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url2 as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, EditorTemplate.width)
        XCTAssertEqual(image.height, EditorTemplate.height)
        XCTAssertEqual(image.bitsPerPixel, 8)
        let bytes = try XCTUnwrap(image.dataProvider?.data as Data?)
        var differences = 0
        for y in 0..<image.height {
            for x in 0..<image.width where bytes[y * image.bytesPerRow + x] != EditorTemplate.pixels[y * image.width + x] {
                differences += 1
            }
        }
        XCTAssertEqual(differences, 0, "make_template.py --swift で作り直す")
        XCTAssertEqual(detector.barColor, 29)
    }

    func testRealScreensAreEditor() throws {
        for name in ["dark_blank_ipadportrait.jpg", "dark_blank_ipadlandscape.jpg"] {
            let match = detector.match(try TestImages.loadGray(TestImages.real(name)))
            XCTAssertTrue(match.isEditor, "\(name) \(match)")
            XCTAssertGreaterThan(match.bright, 0.8, name)
            XCTAssertGreaterThan(match.dark, 0.95, name)
        }
    }

    func testLandscapeFromPortraitBuffer() throws {
        // 実機では、横持ちでも縦長のバッファで届き、時計回りに90度回すと表示の向きになる
        let display = try TestImages.loadGray(TestImages.real("dark_blank_ipadlandscape.jpg"))
        let buffer = TestImages.rotateCounterClockwise(display)
        XCTAssertEqual(buffer.width, display.height)
        let match = buffer.pixels.withUnsafeBufferPointer {
            detector.match(pixels: $0.baseAddress!, width: buffer.width, height: buffer.height, rowBytes: buffer.width, rotation: 90)
        }
        XCTAssertTrue(match.isEditor, "\(match)")
        // 回す向きを間違えると、編集画面にならない
        let wrong = buffer.pixels.withUnsafeBufferPointer {
            detector.match(pixels: $0.baseAddress!, width: buffer.width, height: buffer.height, rowBytes: buffer.width, rotation: 270)
        }
        XCTAssertFalse(wrong.isEditor)
    }

    func testStaysEditorWhileUsingProcreate() throws {
        let screen = try portrait()
        // キャンバスに描いた
        let drawn = TestImages.painting(screen, x0: 200, y0: 300, w: 300, h: 400, value: 0)
        XCTAssertTrue(detector.match(drawn).isEditor)
        // 選択ツールを選んで、S のアイコンが青くなった（明るさ 100 前後）
        var selected = screen
        for y in 0..<33 {
            for x in 165..<205 where selected[x, y] > 90 {
                selected.pixels[y * selected.width + x] = 100
            }
        }
        let match = detector.match(selected)
        XCTAssertTrue(match.isEditor, "\(match)")
        XCTAssertLessThan(match.bright, 1.0)
    }

    func testOtherScreensAreNotEditor() throws {
        let screen = try portrait()
        let width = screen.width
        let height = screen.height
        XCTAssertFalse(detector.match(TestImages.homeLike(width: width, height: height)).isEditor, "ホーム画面")
        XCTAssertFalse(detector.match(GrayImage(pixels: .init(repeating: 30, count: width * height), width: width, height: height)).isEditor, "真っ暗")
        XCTAssertFalse(detector.match(GrayImage(pixels: .init(repeating: 250, count: width * height), width: width, height: height)).isEditor, "真っ白")

        // 上が隠れた（全画面表示や、通知のバナー）
        var hidden = screen
        for y in 0..<50 {
            for x in 0..<width {
                hidden.pixels[y * width + x] = screen[x, y + 500]
            }
        }
        XCTAssertFalse(detector.match(hidden).isEditor, "上が隠れた")

        // アプリの一覧（縮んだ Procreate が、壁紙の上に出ている）
        var switcher = TestImages.homeLike(width: width, height: height)
        let scale = 0.6
        let offsetX = Int(Double(width) * 0.2)
        let offsetY = Int(Double(height) * 0.2)
        for y in 0..<Int(Double(height) * scale) {
            for x in 0..<Int(Double(width) * scale) {
                switcher.pixels[(y + offsetY) * width + (x + offsetX)] = screen[Int(Double(x) / scale), Int(Double(y) / scale)]
            }
        }
        XCTAssertFalse(detector.match(switcher).isEditor, "アプリの一覧")
    }
}
