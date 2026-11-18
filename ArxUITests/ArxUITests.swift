//
//  ArxUITests.swift
//  ArxUITests
//
//  Fixture-mode UI tests. The app launches with --bridge-fixtures, so no real
//  Reminders data, account or network permission is ever touched.
//

import XCTest

final class ArxUITests: XCTestCase {
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
  func testFixtureBannerAndGrantControls() throws {
    // The fixture banner must be visible so a fixture run can never look like
    // real Reminders access.
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

  @MainActor
  func testAccessibilityAudit() throws {
    XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
    // Collect every issue with its full description before failing; the
    // thrown error names only the issue type ("Parent/Child mismatch"),
    // never the element.
    var issues: [String] = []
    try app.performAccessibilityAudit { issue in
      issues.append(String(describing: issue))
      return true
    }
    XCTAssertTrue(issues.isEmpty, issues.joined(separator: "\n---\n"))
  }
}
