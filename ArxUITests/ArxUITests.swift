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
    // Collect every issue with its full description and element details
    // before failing; the thrown error names only the issue type
    // ("Parent/Child mismatch"), never the element.
    var issues: [String] = []
    // Capture the render the audit measures so contrast findings can be
    // checked against the actual pixels (window key state, dimming).
    // pngData forces the capture now; a screenshot proxy would capture lazily
    // at write time, after the audit has run.
    let auditPNG = app.screenshot().pngData
    try app.performAccessibilityAudit { issue in
      var line = String(describing: issue)
      if let element = issue.element {
        line +=
          " | identifier:\(element.identifier) label:\(element.label) frame:\(element.frame) type:\(element.elementType.rawValue)"
      } else {
        // A nil element gives no location; the tree is the only way to find
        // the mismatch.
        line += " | tree:\n" + app.debugDescription
      }
      issues.append(line)
      return true
    }
    let artifacts = URL(fileURLWithPath: "/tmp/uitest-artifacts")
    try? FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
    try? auditPNG.write(to: artifacts.appendingPathComponent("audit-window.png"))
    XCTAssertTrue(issues.isEmpty, issues.joined(separator: "\n---\n"))
  }
}
