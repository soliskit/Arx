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
    XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
    let application = app!
    // Container observations come first and are recorded as data with no
    // assertions, so the observation step itself adds no abort before the
    // audit. The full strict audit then runs regardless of what the
    // observation found, and one combined assertion reports everything at
    // the end. No defer: XCTest failure unwinding can skip deferred work.
    var issues = columnContainerFindings(application)
    // Collect every issue with its full description and element details
    // before failing; the thrown error names only the issue type
    // ("Parent/Child mismatch"), never the element.
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

  /// AX role and containment observation for the column container probe.
  /// Asserts nothing: it records one fixed-token observation line per column
  /// and returns failure strings, so it cannot abort the audit that runs
  /// after it. Output is limited to the fixed sidebar/detail token, the
  /// match count, and booleans; the actual AX label is compared internally
  /// and never printed or embedded in a failure. The column identifiers are
  /// fixed values only the container probe installs (SwiftUI content never
  /// carries them), so identifier matching cannot confuse the containers
  /// with pre-existing SwiftUI-labeled content. Each match must be UNIQUE
  /// and carry the exact label below - the literal English strings are valid
  /// only because this fixture run is known to execute in English - and the
  /// known content must sit somewhere INSIDE the group: containment, not a
  /// direct-parent claim.
  private func columnContainerFindings(_ application: XCUIApplication) -> [String] {
    let expected: [(token: String, identifier: String, label: String, child: String)] = [
      ("sidebar", "column-sidebar", "Lists to share", "list-grant-inbox"),
      ("detail", "column-detail", "Sharing", "bridge-start"),
    ]
    var findings: [String] = []
    for entry in expected {
      let matches = application.groups.matching(
        NSPredicate(format: "identifier == %@", entry.identifier))
      let count = matches.count
      var labelMatchesExpected = false
      var containsExpectedChild = false
      if count == 1 {
        let group = matches.firstMatch
        labelMatchesExpected = group.label == entry.label
        containsExpectedChild = group.descendants(matching: .any)[entry.child].exists
      }
      print(
        "column probe observation: \(entry.token) count=\(count) labelMatchesExpected=\(labelMatchesExpected) containsExpectedChild=\(containsExpectedChild)"
      )
      if count != 1 {
        findings.append(
          "column probe: \(entry.token) expected exactly one AX group, found \(count)")
      } else {
        if !labelMatchesExpected {
          findings.append(
            "column probe: \(entry.token) AX group label did not match the expected label")
        }
        if !containsExpectedChild {
          findings.append(
            "column probe: \(entry.token) AX group does not contain the expected child")
        }
      }
    }
    return findings
  }
}
