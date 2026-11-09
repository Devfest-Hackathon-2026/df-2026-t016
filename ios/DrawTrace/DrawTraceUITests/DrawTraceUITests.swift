import XCTest

final class DrawTraceUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor private func launch(arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"] + arguments
        app.launch()
        return app
    }

    @MainActor private func capture(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor func testGalleryOpensCalendarAndDayDetail() {
        let app = launch()
        let work = app.buttons["work.w_preview0"]
        XCTAssertTrue(work.waitForExistence(timeout: 10))
        capture("01-gallery", app: app)
        work.tap()
        XCTAssertTrue(app.staticTexts["制作の記録"].waitForExistence(timeout: 5))
        capture("02-calendar", app: app)
        let day = app.buttons.matching(identifier: "history.day").firstMatch
        for _ in 0..<3 where !day.isHittable { app.swipeUp() }
        XCTAssertTrue(day.exists)
        day.tap()
        XCTAssertTrue(app.staticTexts["history.lastSnapshot"].waitForExistence(timeout: 5))
        capture("03-day-detail", app: app)
        app.buttons["閉じる"].tap()
    }

    @MainActor func testFinalizeNeedsDeclarationAndExplicitEndImageChoice() {
        let app = launch()
        XCTAssertTrue(app.buttons["work.w_preview0"].waitForExistence(timeout: 10))
        app.buttons["work.w_preview0"].tap()
        app.buttons["work.tab.0"].tap()
        // 【T14】記録の一覧（2回）から「提出へ」で提出の画面に移る
        XCTAssertTrue(app.descendants(matching: .any)["work.record.1"].waitForExistence(timeout: 5))
        capture("04a-records", app: app)
        let submit = app.buttons["work.submit"]
        for _ in 0..<5 where !submit.isHittable { app.swipeUp() }
        XCTAssertTrue(submit.waitForExistence(timeout: 5))
        submit.tap()
        let finalize = app.buttons["work.finalize"]
        for _ in 0..<5 where !finalize.isHittable { app.swipeUp() }
        XCTAssertTrue(finalize.waitForExistence(timeout: 5))
        XCTAssertFalse(finalize.isEnabled)
        // 【11/8】作者の申告は AI の使い方を3つから選ぶ
        let declaration = app.buttons["work.declaration.none"]
        XCTAssertTrue(declaration.exists)
        declaration.tap()
        XCTAssertTrue(app.staticTexts["work.declaration.text"].exists)
        XCTAssertFalse(finalize.isEnabled)
        let publishWhole = app.switches["work.showWhole"]
        XCTAssertTrue(publishWhole.exists)
        publishWhole.tap()
        XCTAssertEqual(publishWhole.value as? String, "0")
        let endChoice = app.buttons["work.endImage.use"]
        for _ in 0..<3 where !endChoice.isHittable { app.swipeDown() }
        endChoice.tap()
        for _ in 0..<3 where !finalize.isHittable { app.swipeUp() }
        XCTAssertTrue(finalize.isEnabled)
        capture("04-declaration", app: app)
        finalize.tap()
        XCTAssertTrue(app.buttons["リンクを共有"].waitForExistence(timeout: 5))
        capture("05-share", app: app)
    }

    @MainActor func testCalendarSelectionOpensSelectedDay() {
        let app = launch()
        XCTAssertTrue(app.buttons["work.w_preview0"].waitForExistence(timeout: 10))
        app.buttons["work.w_preview0"].tap()
        let yesterday = Calendar.current.component(.day, from: Date().addingTimeInterval(-86_400))
        let date = app.buttons["calendar.day.\(yesterday)"]
        XCTAssertTrue(date.waitForExistence(timeout: 5))
        date.tap()
        capture("06-calendar-selection", app: app)
        app.buttons["history.selection"].tap()
        XCTAssertTrue(app.staticTexts["history.lastSnapshot"].waitForExistence(timeout: 5))
    }

    @MainActor func testLocalFiltersAndOrderedGallery() {
        let app = launch()
        XCTAssertTrue(app.buttons["work.w_preview0"].waitForExistence(timeout: 10))
        app.buttons["提出済み"].tap()
        XCTAssertTrue(app.staticTexts["作品が見つかりません"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["work.w_preview0"].exists)
        app.buttons["全て"].tap()
        XCTAssertTrue(app.buttons["work.w_preview0"].exists)
        app.buttons["ギャラリーのメニュー"].tap()
        let order = app.buttons["整列して表示"]
        XCTAssertTrue(order.waitForExistence(timeout: 5))
        order.tap()
        XCTAssertTrue(app.buttons["work.w_preview0"].exists)
        XCTAssertTrue(app.buttons["work.w_preview1"].exists)
        capture("07-ordered-gallery", app: app)
        app.buttons["ギャラリーのメニュー"].tap()
        app.buttons["表示名を変更"].tap()
        XCTAssertTrue(app.textFields["表示名"].waitForExistence(timeout: 5))
        capture("09-profile", app: app)
        app.buttons["閉じる"].tap()
    }

    @MainActor func testPreparationEnablesBroadcastControl() {
        let app = launch(arguments: ["--prepare-preview"])
        XCTAssertTrue(app.buttons["work.w_preview0"].waitForExistence(timeout: 10))
        app.buttons["work.w_preview0"].tap()
        let prepare = app.buttons["work.prepare"]
        XCTAssertTrue(prepare.waitForExistence(timeout: 5))
        XCTAssertTrue(prepare.isEnabled)
        XCTAssertFalse(app.buttons["録画状態を更新"].exists)
        prepare.tap()
        XCTAssertTrue(app.buttons["録画状態を更新"].waitForExistence(timeout: 5))
        let finished = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: prepare)
        XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 5), .completed)
        XCTAssertTrue(app.staticTexts["準備完了"].exists)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "notice.error").firstMatch.exists)
        capture("08-preparation", app: app)
    }
}
