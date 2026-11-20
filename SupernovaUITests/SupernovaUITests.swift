//
//  SupernovaUITests.swift
//  SupernovaUITests
//
//  Created by qiyang on 2026/11/20.
//

import XCTest

final class SupernovaUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testMessageEditorAcceptsTypingWithoutATapOnLaunch() {
        let app = XCUIApplication()
        app.launch()

        let editor = app.textViews["conversationEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        let message = "Hello Supernova"
        editor.typeText(message)
        XCTAssertEqual(editor.value as? String, message)
    }

    @MainActor
    func testSendingWithoutAnAPIKeyKeepsDraftAndOffersConfig() {
        let app = XCUIApplication()
        app.launchEnvironment["SUPERNOVA_UI_TEST_KEYCHAIN_NAMESPACE"] =
            UUID().uuidString
        app.launch()

        let editor = app.textViews["conversationEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        let draft = "Keep my message"
        editor.typeText(draft)

        let send = app.buttons["sendConversationMessage"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        send.tap()

        let openConfig = app.alerts.buttons["Open Config"]
        XCTAssertTrue(openConfig.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, draft)
        openConfig.tap()
        XCTAssertTrue(
            app.secureTextFields["openAIAPIKey"].waitForExistence(timeout: 5)
        )
    }

    @MainActor
    func testSelectingSidebarConversationShowsItsDetail() {
        let app = XCUIApplication()
        app.launch()

        let title = "Introduction to Epsilon"
        let row = app.descendants(matching: .any)["introductionToEpsilon"]
            .firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()

        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textViews.firstMatch.isHittable)
    }

    @MainActor
    func testConfigSavesAPIKeyWhenTappingOutsideAndPersistsClear() {
        let app = XCUIApplication()
        app.launchEnvironment["SUPERNOVA_UI_TEST_KEYCHAIN_NAMESPACE"] =
            UUID().uuidString
        app.launch()
        let cancel = app.buttons["cancelSettings"]

        func openSettings() -> XCUIElement {
            let config = app.buttons["configButton"]
            XCTAssertTrue(config.waitForExistence(timeout: 5))
            config.tap()

            let settingsBar = app.navigationBars["Settings"]
            XCTAssertTrue(settingsBar.waitForExistence(timeout: 5))
            XCTAssertTrue(cancel.exists)
            XCTAssertFalse(settingsBar.buttons["Confirm"].exists)

            let apiKey = app.secureTextFields["openAIAPIKey"]
            XCTAssertTrue(apiKey.waitForExistence(timeout: 5))
            XCTAssertTrue(apiKey.isEnabled)
            return apiKey
        }

        func tapOutside(_ apiKey: XCUIElement) {
            apiKey.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1))
                .withOffset(CGVector(dx: 0, dy: 30))
                .tap()
        }

        let discardAlert = app.alerts["Discard changes?"]
        let clear = app.buttons["Clear text"]
        let unchangedAPIKey = openSettings()
        cancel.tap()
        XCTAssertTrue(unchangedAPIKey.waitForNonExistence(timeout: 5))
        XCTAssertFalse(discardAlert.exists)

        let cancelledAPIKey = openSettings()
        cancelledAPIKey.tap()
        cancelledAPIKey.typeText("cancel-draft-test")
        cancel.tap()
        XCTAssertTrue(discardAlert.waitForExistence(timeout: 5))
        discardAlert.buttons["Keep Editing"].tap()
        XCTAssertTrue(discardAlert.waitForNonExistence(timeout: 5))
        XCTAssertTrue(clear.waitForExistence(timeout: 5))

        cancel.tap()
        XCTAssertTrue(discardAlert.waitForExistence(timeout: 5))
        discardAlert.buttons["Discard"].tap()
        XCTAssertTrue(cancelledAPIKey.waitForNonExistence(timeout: 5))

        let apiKey = openSettings()
        XCTAssertEqual(apiKey.value as? String, apiKey.placeholderValue)
        apiKey.tap()
        apiKey.typeText("clear-button-test")

        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        let keyboard = app.keyboards.firstMatch
        let keyboardWasVisible = keyboard.exists
        tapOutside(apiKey)
        if keyboardWasVisible {
            XCTAssertTrue(keyboard.waitForNonExistence(timeout: 5))
        }

        app.terminate()
        app.launch()
        let savedAPIKey = openSettings()
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        clear.tap()

        XCTAssertTrue(clear.waitForNonExistence(timeout: 5))
        XCTAssertEqual(
            savedAPIKey.value as? String,
            savedAPIKey.placeholderValue
        )
        tapOutside(savedAPIKey)

        app.terminate()
        app.launch()
        let emptyAPIKey = openSettings()
        XCTAssertEqual(
            emptyAPIKey.value as? String,
            emptyAPIKey.placeholderValue
        )
        XCTAssertFalse(clear.exists)
    }

    @MainActor
    func testContextWindowUsageAppearsBeforeFastMode() {
        let app = XCUIApplication()
        app.launch()

        let usage = app.descendants(matching: .any)["contextWindowUsage"]
        let fastMode = app.descendants(matching: .any)["fastMode"]
        XCTAssertTrue(usage.waitForExistence(timeout: 5))
        XCTAssertEqual(usage.value as? String, "20%")
        XCTAssertTrue(fastMode.isHittable)
        let horizontalDistance = fastMode.frame.midX - usage.frame.midX
        let verticalDistance = fastMode.frame.midY - usage.frame.midY
        if abs(horizontalDistance) > abs(verticalDistance) {
            XCTAssertGreaterThan(horizontalDistance, 0)
        } else {
            XCTAssertGreaterThan(verticalDistance, 0)
        }
    }

    @MainActor
    func testModelPickerShowsAndChangesSelection() {
        let app = XCUIApplication()
        app.launch()

        let picker = app.buttons["modelPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertTrue(picker.isHittable)

        picker.tap()
        let defaultModel = app.buttons["gpt-6-sol"]
        XCTAssertTrue(defaultModel.waitForExistence(timeout: 5))
        let model = app.buttons["gpt-6-luna"]
        XCTAssertTrue(model.waitForExistence(timeout: 5))
        XCTAssertTrue(defaultModel.isSelected)
        XCTAssertFalse(model.isSelected)
        model.tap()

        picker.tap()
        XCTAssertTrue(model.waitForExistence(timeout: 5))
        XCTAssertTrue(model.isSelected)
        XCTAssertFalse(defaultModel.isSelected)
    }

    @MainActor
    func testThinkingEffortCanSwitchBetweenNoneAndLow() {
        let app = XCUIApplication()
        app.launch()

        let menu = app.descendants(matching: .any)["thinkingEffortMenu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        let otherOption = app.buttons["high"]

        for effort in ["none", "low"] {
            menu.tap()
            let option = app.buttons[effort]
            XCTAssertTrue(option.waitForExistence(timeout: 5))
            option.tap()
            XCTAssertTrue(otherOption.waitForNonExistence(timeout: 5))
        }
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            XCUIApplication().launch()
        }
    }
}
