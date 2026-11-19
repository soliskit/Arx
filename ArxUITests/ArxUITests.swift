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
    windowContentObservation(application)
    issues.append(contentsOf: controlInventoryFindings(application))
    // Collect every issue with its full description and element details
    // before failing; the thrown error names only the issue type
    // ("Parent/Child mismatch"), never the element.
    // Capture a render shortly before the audit runs so contrast findings
    // can be compared against those pixels (window key state, dimming).
    // This is pre-audit state; it is not known to be the render the audit
    // engine samples. The pngRepresentation forces the capture now, before
    // the audit runs (XCUIScreenshot's documented PNG data property on
    // macOS).
    let auditPNG = application.screenshot().pngRepresentation
    // Pre-audit observations at the closest test-side point before the
    // audit: a numeric state enum and the window enabled boolean. These
    // sequential queries are not a read of the audit engine's own state.
    // Observations only, never assertions.
    print("pre-audit-app-state: \(application.state.rawValue)")
    print("pre-audit-window-enabled: \(application.windows["main"].isEnabled)")
    contrastProbeObservation(application)
    issues.append(contentsOf: try strictAuditIssueLines(application))
    let artifacts = URL(fileURLWithPath: "/tmp/uitest-artifacts")
    try? FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
    try? auditPNG.write(to: artifacts.appendingPathComponent("audit-window.png"))
    issues.append(contentsOf: grantToggleFindings(application))
    XCTAssertTrue(issues.isEmpty, issues.joined(separator: "\n---\n"))
  }

  /// Minimal-fixture control run: audits a plain NavigationSplitView with a
  /// navigation title and default-styled text, nothing Arx-specific, under
  /// the SAME strict audit handler as the full-app audit. A Parent/Child
  /// structural mismatch that reproduces here cannot come from Arx's own
  /// view structure; one that does not narrows the lead back to it. The
  /// same discrimination applies to contrast findings on default-styled
  /// text. No filtering and no assertions beyond the audit's own issue
  /// list.
  @MainActor
  func testAccessibilityAuditMinimalFixture() throws {
    try runMinimalFixtureAudit(extraArguments: [], artifactName: "minimal-audit-window.png")
  }

  /// Delta 1 of the single-variable ladder: the SAME minimal fixture with
  /// exactly one component from the full app added - its two column
  /// accessibility probes, the only components there that mutate the AX
  /// tree. --arx-minimal-probes selects them in the fixture;
  /// --arx-dump-view-hierarchy activates the probes' DEBUG install path
  /// (its stdout hierarchy dump has no call site in the minimal fixture,
  /// so the only AX-tree change is the probes themselves, including the
  /// detail probe's window-root experiment exactly as in the full app).
  /// If the Parent/Child mismatch appears here but not in the baseline,
  /// the probes are implicated in this environment; if it does not appear,
  /// the probes alone do not reproduce it here and interactions unique to
  /// the full app remain open. Every other condition is identical to the
  /// baseline control above.
  @MainActor
  func testAccessibilityAuditMinimalFixtureProbes() throws {
    try runMinimalFixtureAudit(
      extraArguments: ["--arx-minimal-probes", "--arx-dump-view-hierarchy"],
      artifactName: "minimal-probes-audit-window.png")
  }

  /// Delta 2 of the single-variable ladder: the SAME minimal fixture with
  /// exactly one component from the full app added - its two column
  /// accessibilityElement(children: .contain) + accessibilityLabel
  /// modifier pairs, the only accessibilityElement(children:) calls in
  /// the app source (ContentView:56 and :137) and the only modifiers
  /// there that restructure AX containment rather than set attributes.
  /// Isolated against the baseline: no probes and no dump argument, so
  /// nothing else that touches the AX tree is active. If the Parent/Child
  /// mismatch appears here but not in the baseline, the containment
  /// grouping is implicated in this environment; if it does not appear,
  /// the grouping alone does not reproduce it here and interactions
  /// unique to the full app remain open. Every other condition is
  /// identical to the baseline control.
  @MainActor
  func testAccessibilityAuditMinimalFixtureAXGroup() throws {
    try runMinimalFixtureAudit(
      extraArguments: ["--arx-minimal-axgroup"],
      artifactName: "minimal-axgroup-audit-window.png")
  }

  /// Delta 3 of the ladder: the COMBINATION of deltas 1 and 2 - the
  /// column accessibility probes live AND the column containment-grouping
  /// modifier pair applied - which is the exact AX configuration the full
  /// app runs under the audit. The two single-delta runs did not
  /// reproduce the Parent/Child mismatch; this run tests whether their
  /// combination does. If the mismatch appears here but not in the
  /// baseline or either single-delta run, the probes+grouping combination
  /// is implicated in this environment; if it does not appear, the
  /// combination does not reproduce it here and content, environment, and
  /// other full-app differences remain open. Known and declared: the
  /// fixture sidebar label "Fixture lists" duplicates the Outline's role
  /// description (a fixture fidelity defect classified in the delta-2
  /// review, immaterial to the per-element mismatch discrimination); it
  /// is expected to recur here and is deliberately NOT repaired inside
  /// this combined step - any label repair is its own reviewed change.
  @MainActor
  func testAccessibilityAuditMinimalFixtureProbesAXGroup() throws {
    try runMinimalFixtureAudit(
      extraArguments: [
        "--arx-minimal-probes", "--arx-minimal-axgroup", "--arx-dump-view-hierarchy",
      ],
      artifactName: "minimal-probes-axgroup-audit-window.png")
  }

  /// Shared body of the minimal-fixture control runs: relaunch into the
  /// minimal fixture with the given extra arguments, record the pre-audit
  /// state observations and a window render (evidence for interpreting any
  /// contrast finding against actual pixels, mirroring the full-app
  /// audit's capture), then run the SAME strict audit handler as the
  /// full-app audit and assert on its collected issues. Observations are
  /// never assertions.
  private func runMinimalFixtureAudit(extraArguments: [String], artifactName: String) throws {
    app.terminate()
    app = XCUIApplication()
    app.launchArguments = ["--bridge-fixtures", "--arx-minimal-fixture"] + extraArguments
    app.launch()
    XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
    let application = app!

    print("pre-audit-app-state: \(application.state.rawValue)")
    print("pre-audit-window-enabled: \(application.windows["main"].isEnabled)")
    let auditPNG = application.screenshot().pngRepresentation
    let artifacts = URL(fileURLWithPath: "/tmp/uitest-artifacts")
    try? FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
    try? auditPNG.write(to: artifacts.appendingPathComponent(artifactName))

    let issues = try strictAuditIssueLines(application)
    XCTAssertTrue(issues.isEmpty, issues.joined(separator: "\n---\n"))
  }

  /// Runs the strict accessibility audit (every issue type, no filters) and
  /// returns one self-contained line per finding: the full issue
  /// description plus the audit-fixed installed-identifier match token and
  /// element details, or the whole AX tree when the issue carries no
  /// element. Shared by the full-app audit and the minimal-fixture control
  /// so both apply the identical handler. The handler returns true for
  /// every issue so the audit collects them all instead of throwing on the
  /// first one; the caller asserts on the collected lines.
  private func strictAuditIssueLines(_ application: XCUIApplication) throws -> [String] {
    let installedIdentifiers: Set<String> = ["column-sidebar", "column-detail", "window-content"]
    var lines: [String] = []
    try application.performAccessibilityAudit { issue in
      var line = String(describing: issue)
      // Fixed token only: whether THIS issue's element carries one of the
      // probe-installed identifiers. This is the only sanctioned binding
      // between a finding and an owned view - element identity, never
      // label or frame coincidence.
      let matchesInstalled =
        issue.element.map { installedIdentifiers.contains($0.identifier) } ?? false
      line += " | matches-installed-id:\(matchesInstalled)"

      if let element = issue.element {
        line +=
          " | identifier:\(element.identifier) label:\(element.label) frame:\(element.frame) type:\(element.elementType.rawValue)"
      } else {
        // A nil element gives no location; the tree is the only way to find
        // the mismatch.
        line += " | tree:\n" + application.debugDescription
      }
      lines.append(line)
      return true
    }
    return lines
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
  /// Same-instance passive control inventory. The list covers ONLY these 19
  /// controls - the interactive set observed in the audit instance's own AX
  /// tree in the baseline runs - not every AX control (scroll chrome and any
  /// newly added controls are outside it). Existence, uniqueness and enabled
  /// state are asserted against that measured debug baseline, which is a
  /// fixture regression expectation, not a cross-version contract. This step
  /// proves reachability observations only; operability is proven separately
  /// for the three grant checkboxes after the audit. Output is fixed tokens
  /// and booleans only.
  private func controlInventoryFindings(_ application: XCUIApplication) -> [String] {
    struct Control {
      let token: String
      let query: (XCUIApplication) -> XCUIElementQuery
      let expectedEnabled: Bool
    }
    func byLabel(_ label: String) -> NSPredicate {
      NSPredicate(format: "label == %@", label)
    }
    func byPlaceholder(_ text: String) -> NSPredicate {
      NSPredicate(format: "placeholderValue == %@", text)
    }
    let controls: [Control] = [
      Control(
        token: "grant-inbox",
        query: { $0.checkBoxes.matching(identifier: "list-grant-inbox") },
        expectedEnabled: true),
      Control(
        token: "grant-weekend",
        query: { $0.checkBoxes.matching(identifier: "list-grant-weekend") },
        expectedEnabled: true),
      Control(
        token: "grant-later",
        query: { $0.checkBoxes.matching(identifier: "list-grant-later") },
        expectedEnabled: true),
      Control(
        token: "grant-readonly",
        query: { $0.checkBoxes.matching(identifier: "list-grant-readonly") },
        expectedEnabled: true),
      Control(
        token: "refresh-lists",
        query: { $0.buttons.matching(byLabel("Refresh lists")) },
        expectedEnabled: true),
      Control(
        token: "origin-field",
        query: { $0.textFields.matching(byPlaceholder("Exact remote HTTPS origin")) },
        expectedEnabled: true),
      Control(
        token: "port-field",
        query: { $0.textFields.matching(byPlaceholder("Local port")) },
        expectedEnabled: true),
      Control(
        token: "bridge-start",
        query: { $0.buttons.matching(identifier: "bridge-start") },
        expectedEnabled: true),
      Control(
        token: "bridge-stop",
        query: { $0.buttons.matching(identifier: "bridge-stop") },
        expectedEnabled: false),
      Control(
        token: "client-label-field",
        query: { $0.textFields.matching(byPlaceholder("Client label")) },
        expectedEnabled: true),
      Control(
        token: "rights-read",
        query: { $0.checkBoxes.matching(byLabel("Read selected lists")) },
        expectedEnabled: true),
      Control(
        token: "rights-manage",
        query: { $0.checkBoxes.matching(byLabel("Create, edit, move, complete and reopen")) },
        expectedEnabled: false),
      Control(
        token: "rights-delete",
        query: { $0.checkBoxes.matching(byLabel("Delete reminders with confirmation")) },
        expectedEnabled: false),
      Control(
        token: "pair-create",
        query: { $0.buttons.matching(byLabel("Create single-use pairing secret")) },
        expectedEnabled: false),
      Control(
        token: "refresh-client-status",
        query: { $0.buttons.matching(byLabel("Refresh client status")) },
        expectedEnabled: true),
      Control(
        token: "hide-sidebar",
        query: { $0.buttons.matching(byLabel("Hide Sidebar")) },
        expectedEnabled: true),
      Control(
        token: "window-close",
        query: { $0.buttons.matching(identifier: "_XCUI:CloseWindow") },
        expectedEnabled: true),
      Control(
        token: "window-minimize",
        query: { $0.buttons.matching(identifier: "_XCUI:MinimizeWindow") },
        expectedEnabled: true),
      Control(
        token: "window-fullscreen",
        query: { $0.buttons.matching(identifier: "_XCUI:FullScreenWindow") },
        expectedEnabled: true),
    ]
    var findings: [String] = []
    for control in controls {
      let matches = control.query(application)
      let count = matches.count
      var exists = false
      var enabledMatches = false
      if count == 1 {
        let element = matches.firstMatch
        exists = element.waitForExistence(timeout: 2)
        if exists {
          enabledMatches = element.isEnabled == control.expectedEnabled
        }
      }
      print(
        "control observation: \(control.token) count=\(count) exists=\(exists) enabledMatchesExpected=\(enabledMatches)"
      )
      if count != 1 {
        findings.append("control: \(control.token) expected exactly one match, found \(count)")
      } else if !exists {
        findings.append("control: \(control.token) not reachable")
      } else if !enabledMatches {
        findings.append(
          "control: \(control.token) enabled state changed from the measured baseline")
      }
    }
    return findings
  }

  /// Operability proof for the three togglable grant checkboxes, run AFTER
  /// the audit and after the screenshot is persisted, so it cannot change
  /// the state the audit measures. Each checkbox is exercised only when it
  /// is uniquely matched, existing, enabled, hittable and its current value
  /// is a known 0 or 1; the ACTUAL original value is restored and verified,
  /// never a hardcoded one. Any unsafe condition is reported, not clicked.
  private func grantToggleFindings(_ application: XCUIApplication) -> [String] {
    var findings: [String] = []
    for identifier in ["list-grant-inbox", "list-grant-weekend", "list-grant-later"] {
      let matches = application.checkBoxes.matching(identifier: identifier)
      guard matches.count == 1 else {
        findings.append("toggle: \(identifier) not uniquely matched, skipped")
        continue
      }
      let checkbox = matches.firstMatch
      guard checkbox.exists, checkbox.isEnabled, checkbox.isHittable,
        let original = checkbox.value as? Int, original == 0 || original == 1
      else {
        findings.append("toggle: \(identifier) unsafe to exercise, skipped")
        continue
      }
      checkbox.click()
      let toggled = checkbox.value as? Int
      if toggled != 1 - original {
        findings.append("toggle: \(identifier) value did not change on click")
      }
      if checkbox.value as? Int != original {
        checkbox.click()
      }
      let restored = checkbox.value as? Int == original
      print(
        "control observation: \(identifier) toggled=\(toggled == 1 - original) restored=\(restored)"
      )
      if !restored {
        findings.append("toggle: \(identifier) original state not restored")
      }
    }
    return findings
  }

  /// Window-root binding observation. Report only: prints one fixed-token
  /// line for the probe's "window-content" identifier across ALL element
  /// types and NEVER appends a finding - every outcome (absent, unique,
  /// not-unique) is a legitimate experiment result, and the binding itself is
  /// decided only by the audit issue's own matches-installed-id token.
  /// Output is a bounded count, a closed role token and booleans; no
  /// strings, frames or addresses leave the test.
  private func windowContentObservation(_ application: XCUIApplication) {
    let matches = application.descendants(matching: .any).matching(
      NSPredicate(format: "identifier == %@", "window-content"))
    let count = matches.count
    var labelPresent = false
    var roleToken = count > 1 ? "not-unique" : "absent"
    if count == 1 {
      let element = matches.firstMatch
      labelPresent = !element.label.isEmpty
      switch element.elementType {
      case .group: roleToken = "group"
      case .staticText: roleToken = "staticText"
      default: roleToken = "other"
      }
    }
    print(
      "window content observation: count=\(count) role=\(roleToken) labelPresent=\(labelPresent)")
  }

  /// Element-level pre-audit capture for the two flagged contrast elements
  /// and two unflagged same-container references. Report only: one
  /// fixed-token observation line and one element-scoped attachment per
  /// element, plus one window attachment at the same instant. No assertion
  /// is added and no observation is appended to any failing issue; the
  /// strict audit runs exactly as before. Each line pairs the AX frame with
  /// the attachment's point size and pixel dimensions, which together give
  /// the actual screen scale factor that an AX frame alone cannot provide.
  private func contrastProbeObservation(_ application: XCUIApplication) {
    let probes: [(token: String, element: XCUIElement)] = [
      ("banner", application.staticTexts["Fixture data - no real Reminders access"]),
      ("bridge-status", application.staticTexts["bridge-status"]),
      ("arx-bridge-title", application.staticTexts["Arx bridge"]),
      (
        "keep-running-caption",
        application.staticTexts["Keep the Mac, Arx and your connector running."]
      ),
    ]
    for probe in probes {
      let element = probe.element
      guard element.exists else {
        print("contrast probe observation: token=\(probe.token) exists=false")
        continue
      }
      let screenshot = element.screenshot()
      let image = screenshot.image
      var pixelToken = "pixels=unknown"
      if let representation = image.representations.first {
        pixelToken = "pixels=\(representation.pixelsWide)x\(representation.pixelsHigh)"
      }
      print(
        "contrast probe observation: token=\(probe.token) exists=true frame=\(element.frame) enabled=\(element.isEnabled) selected=\(element.isSelected) type=\(element.elementType.rawValue) points=\(image.size.width)x\(image.size.height) \(pixelToken)"
      )
      let attachment = XCTAttachment(screenshot: screenshot)
      attachment.name = "contrast-probe-\(probe.token)"
      attachment.lifetime = .keepAlways
      add(attachment)
    }
    let windowAttachment = XCTAttachment(screenshot: application.windows["main"].screenshot())
    windowAttachment.name = "contrast-probe-window"
    windowAttachment.lifetime = .keepAlways
    add(windowAttachment)
  }

  private func columnContainerFindings(_ application: XCUIApplication) -> [String] {
    let expected: [(token: String, identifier: String, label: String, child: String)] = [
      ("sidebar", "column-sidebar", "Lists to share", "list-grant-inbox"),
      ("detail", "column-detail", "Sharing", "bridge-start"),
    ]
    var findings: [String] = []
    for entry in expected {
      // Identifier query across ALL element types: the candidate no longer
      // assigns a role, so the observation must not assume one. Only a
      // bounded count, a closed role token and booleans leave the test.
      let matches = application.descendants(matching: .any).matching(
        NSPredicate(format: "identifier == %@", entry.identifier))
      let count = matches.count
      var labelMatchesExpected = false
      var containsExpectedChild = false
      var roleToken = count > 1 ? "not-unique" : "absent"
      if count == 1 {
        let element = matches.firstMatch
        labelMatchesExpected = element.label == entry.label
        containsExpectedChild = element.descendants(matching: .any)[entry.child].exists
        switch element.elementType {
        case .group: roleToken = "group"
        case .staticText: roleToken = "staticText"
        default: roleToken = "other"
        }
      }
      print(
        "column probe observation: \(entry.token) count=\(count) role=\(roleToken) labelMatchesExpected=\(labelMatchesExpected) containsExpectedChild=\(containsExpectedChild)"
      )
      if count != 1 {
        findings.append(
          "column probe: \(entry.token) expected exactly one AX element, found \(count)")
      } else {
        if !labelMatchesExpected {
          findings.append(
            "column probe: \(entry.token) AX element label did not match the expected label")
        }
        if !containsExpectedChild {
          findings.append(
            "column probe: \(entry.token) AX element does not contain the expected child")
        }
      }
    }
    return findings
  }
}
