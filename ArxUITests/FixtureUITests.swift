//
//  FixtureUITests.swift
//  ArxUITests
//
//  Fixture-mode UI tests. The app launches with --bridge-fixtures, so no real
//  Reminders data, account or network permission is ever touched.
//

import XCTest

final class FixtureUITests: XCTestCase {
  private var app: XCUIApplication!

  override func setUpWithError() throws {
    continueAfterFailure = false
    app = XCUIApplication()
    app.launchArguments = ["--bridge-fixtures"]
    app.launch()
  }

  override func tearDownWithError() throws {
    app.terminate()
    app = nil
  }

  @MainActor
  func testSectionsStatusIsReadOnly() throws {
    let status = app.staticTexts["sections-status"]
    XCTAssertTrue(status.waitForExistence(timeout: 10))
    // Fixture mode serves fixture labels, so the read-only wording applies.
    XCTAssertTrue(status.label.contains("read-only"))
    XCTAssertTrue(status.label.contains("Unknown"))
  }

  @MainActor
  func testFixtureBannerAndGrantControls() throws {
    XCTAssertTrue(
      app.staticTexts["Fixture data - no real Reminders access"].waitForExistence(timeout: 10))
    for id in ["inbox", "weekend", "later"] {
      XCTAssertTrue(app.checkBoxes["list-grant-" + id].exists, "Missing grant control for \(id)")
    }
    XCTAssertTrue(app.buttons["Refresh lists"].exists)
  }

  @MainActor
  func testGrantCheckboxToggles() throws {
    let inbox = app.checkBoxes["list-grant-inbox"]
    XCTAssertTrue(inbox.waitForExistence(timeout: 10))
    XCTAssertEqual(inbox.value as? Int, 0)
    inbox.click()
    XCTAssertEqual(inbox.value as? Int, 1)
    inbox.click()
    XCTAssertEqual(inbox.value as? Int, 0)
  }
}
