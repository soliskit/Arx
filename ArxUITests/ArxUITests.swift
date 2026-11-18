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
    // Only the audit test requests the diagnostic dump: relaunch the fixture
    // app with the dump argument. The DEBUG app prints its bounded view
    // hierarchy to stdout, which xcodebuild captures into this run's
    // .xcresult bundle (uploaded with the existing artifacts); extraction
    // happens during analysis, not in the test.
    app.terminate()
    app = XCUIApplication()
    app.launchArguments = ["--bridge-fixtures", "--arx-dump-view-hierarchy"]
    app.launch()
    defer { corroborateColumnContainers() }
    XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
    let application = app!
    // Collect every issue with its full description and element details
    // before failing; the thrown error names only the issue type
    // ("Parent/Child mismatch"), never the element.
    var issues: [String] = []
    // Capture the render the audit measures so contrast findings can be
    // checked against the actual pixels (window key state, dimming). The
    // pngRepresentation forces the capture now, before the audit runs
    // (XCUIScreenshot's documented PNG data property on macOS).
    let auditPNG = application.screenshot().pngRepresentation
    try application.performAccessibilityAudit { issue in
      var line = String(describing: issue)
      if let element = issue.element {
        line +=
          " | identifier:\(element.identifier) label:\(element.label) frame:\(element.frame) type:\(element.elementType.rawValue)"
      } else {
        // A nil element gives no location; the tree is the only way to find
        // the mismatch.
        line += " | tree:\n" + application.debugDescription
      }
      issues.append(line)
      return true
    }
    let artifacts = URL(fileURLWithPath: "/tmp/uitest-artifacts")
    try? FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
    try? auditPNG.write(to: artifacts.appendingPathComponent("audit-window.png"))
    XCTAssertTrue(issues.isEmpty, issues.joined(separator: "\n---\n"))
  }

  /// AX role and containment corroboration for the column container repair.
  /// Runs from a defer so a throwing audit or a failing assertion cannot
  /// skip it (a process abort still could). The column identifiers are fixed
  /// values only the container probe installs (SwiftUI content never carries
  /// them), so identifier matching cannot confuse the containers with
  /// pre-existing SwiftUI-labeled content. Each match must be UNIQUE and
  /// carry the exact label below - the literal English strings are valid
  /// only because this fixture run is known to execute in English - and the
  /// known content must sit somewhere INSIDE the group: containment, not a
  /// direct-parent claim.
  private func corroborateColumnContainers() {
    let expected: [(identifier: String, label: String, child: String)] = [
      ("column-sidebar", "Lists to share", "list-grant-inbox"),
      ("column-detail", "Sharing", "bridge-start"),
    ]
    for entry in expected {
      let matches = app.groups.matching(
        NSPredicate(format: "identifier == %@", entry.identifier))
      XCTAssertEqual(
        matches.count, 1, "Expected exactly one AX group \"\(entry.identifier)\"")
      guard matches.count == 1 else { continue }
      let group = matches.firstMatch
      XCTAssertEqual(
        group.label, entry.label, "AX group \"\(entry.identifier)\" carries the wrong label")
      XCTAssertTrue(
        group.descendants(matching: .any)[entry.child].exists,
        "AX group \"\(entry.identifier)\" does not contain \"\(entry.child)\"")
    }
  }
}
