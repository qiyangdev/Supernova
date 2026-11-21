//
//  SupernovaUITests.swift
//  SupernovaUITests
//
//  Created by qiyang on 2026/11/20.
//

import XCTest

final class SupernovaUITests: XCTestCase {

    private let storeID = UUID().uuidString

    @MainActor
    private func testApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["SUPERNOVA_UI_TEST_STORE"] = storeID
        return app
    }

    @MainActor
    private func launchWithThread(_ app: XCUIApplication) {
        app.launch()
        let sidebar = app.buttons["newThread"]
        let showSidebar = app.buttons["Show Sidebar"]
        if !sidebar.isHittable, showSidebar.isHittable {
            showSidebar.tap()
        }
        let create = sidebar.isHittable ? sidebar : app.buttons["newThreadFromEmptyState"]
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        create.tap()
        XCTAssertTrue(app.textViews["conversationEditor"].waitForExistence(timeout: 5))
    }

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
    func testMessageEditorAcceptsTypingWithoutATapAfterCreatingAThread() {
        let app = testApp()
        launchWithThread(app)
        let editor = app.textViews["conversationEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        let message = "Hello Supernova"
        editor.typeText(message)
        XCTAssertEqual(editor.value as? String, message)
    }

    @MainActor
    func testSendingWithoutAnAPIKeyKeepsDraftAndOffersConfig() {
        let app = testApp()
        app.launchEnvironment["SUPERNOVA_UI_TEST_KEYCHAIN_NAMESPACE"] =
            UUID().uuidString
        launchWithThread(app)

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
    func testThreadsKeepSeparateDraftsAcrossRelaunchAndCanBeDeleted() {
        let app = testApp()
        launchWithThread(app)
        let editor = app.textViews["conversationEditor"]
        let actions = app.buttons["threadActions"]

        func renameThread(adding suffix: String) -> String {
            XCTAssertTrue(actions.waitForExistence(timeout: 5))
            actions.tap()
            app.buttons["Rename"].tap()
            let alert = app.alerts["Rename Thread"]
            let field = alert.textFields.firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            let originalTitle = field.value as? String ?? ""
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
            field.typeText(suffix)
            let title = originalTitle + suffix
            XCTAssertEqual(field.value as? String, title)
            alert.buttons["Save"].tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
            return title
        }

        func showSidebar() {
            if !app.buttons["newThread"].isHittable {
                actions.tap()
                app.buttons["Show Threads"].tap()
            }
            XCTAssertTrue(app.buttons["newThread"].waitForExistence(timeout: 5))
        }

        func selectThread(_ title: String) {
            showSidebar()
            let link = app.buttons.matching(identifier: title).firstMatch
            if link.isHittable {
                link.tap()
            } else {
                app.staticTexts.matching(identifier: title).firstMatch.tap()
            }
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5))
        }

        let firstThread = renameThread(adding: " A")
        editor.typeText("First draft")
        showSidebar()
        app.buttons["newThread"].tap()
        let secondThread = renameThread(adding: " B")
        editor.typeText("Second draft")

        selectThread(firstThread)
        XCTAssertEqual(editor.value as? String, "First draft")
        app.terminate()
        app.launch()
        selectThread(secondThread)
        XCTAssertEqual(editor.value as? String, "Second draft")

        actions.tap()
        app.buttons["Delete"].tap()
        let confirm = app.alerts["Delete Thread?"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.buttons["Delete"].tap()
        XCTAssertTrue(app.navigationBars[firstThread].waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, "First draft")
    }

    @MainActor
    func testConfigSavesAPIKeyWhenTappingOutsideAndPersistsClear() {
        let app = testApp()
        app.launchEnvironment["SUPERNOVA_UI_TEST_KEYCHAIN_NAMESPACE"] =
            UUID().uuidString
        launchWithThread(app)
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
        let app = testApp()
        launchWithThread(app)

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
        let app = testApp()
        launchWithThread(app)

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
        let app = testApp()
        launchWithThread(app)

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
            testApp().launch()
        }
    }
}
