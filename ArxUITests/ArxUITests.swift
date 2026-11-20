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

  /// Delta 4 of the ladder: the combo configuration (probes + column
  /// grouping) PLUS the full app's fixture-mode content shape, replicated
  /// faithfully from ContentView.swift into the minimal fixture behind
  /// --arx-minimal-content (banner capsule, grant-list rows with their
  /// real labels and list-grant-* identifiers, Refresh button, bridge
  /// status text, and the Connection/New client/Clients group boxes).
  /// The combo run did not reproduce the Parent/Child mismatch; this run
  /// tests whether the content shape does. If the mismatch appears here
  /// but not in the combo run, this content shape is implicated in this
  /// environment; if it does not appear, content does not reproduce it
  /// here and the remaining differences (inert onChange presence,
  /// environment variance) stay open, with the reverse ladder as the
  /// following step. Multi-element attribution is acknowledged: this is
  /// ONE coherent content delta, not a claim about any single element;
  /// if it reproduces the mismatch, bisecting within the content set is
  /// its own reviewed step. Label fidelity declared, not hidden: content
  /// mode uses the full app's real column titles and accessibility labels
  /// ("Lists to share", "Sharing"), so the delta-2 "Fixture lists"
  /// duplicate-role fixture infidelity is not expected in this run; that
  /// fidelity repair rides inside this delta explicitly.
  @MainActor
  func testAccessibilityAuditMinimalFixtureContent() throws {
    try runMinimalFixtureAudit(
      extraArguments: [
        "--arx-minimal-content", "--arx-minimal-probes", "--arx-minimal-axgroup",
        "--arx-dump-view-hierarchy",
      ],
      artifactName: "minimal-content-audit-window.png")
  }

  /// Delta 5a of the ladder: the content+fixture-labels cell of the
  /// content x labels grid. Identical to the delta-4 content run except
  /// that --arx-minimal-fixture-labels forces the fixture label tokens
  /// ("Fixture lists", "Fixture Sharing") on the column accessibility
  /// groups, isolating the label variable from the content variable.
  /// Existing cells: plain+fixture-labels (combo run: no mismatch) and
  /// content+real-labels (delta-4: mismatch reproduced). Bounded
  /// readings of this cell, hypotheses only: if the mismatch appears
  /// here, the real labels are not necessary for reproduction in this
  /// configuration (content alone suffices here); that says nothing
  /// about labels generally. If it does not appear, content with fixture
  /// labels does not reproduce it here; a single negative is not a
  /// causal exclusion. Known and declared: the fixture labels reinstate
  /// the delta-2 duplicate-role label infidelity in this cell, so the
  /// duplicate-role finding is expected here as in the axgroup/combo
  /// runs; it remains immaterial to the per-element mismatch
  /// discrimination. A single run does not establish recurrence.
  @MainActor
  func testAccessibilityAuditMinimalFixtureContentFixtureLabels() throws {
    try runMinimalFixtureAudit(
      extraArguments: [
        "--arx-minimal-content", "--arx-minimal-fixture-labels", "--arx-minimal-probes",
        "--arx-minimal-axgroup", "--arx-dump-view-hierarchy",
      ],
      artifactName: "minimal-content-fixture-labels-audit-window.png")
  }

  /// Delta 5b of the ladder: the plain-content+real-labels cell of the
  /// content x labels grid. Identical to the combo run except that
  /// --arx-minimal-real-labels forces the full app's real column labels
  /// ("Lists to share", "Sharing") on the plain placeholder content,
  /// isolating the label variable from the content variable. Bounded
  /// readings of this cell, hypotheses only: if the mismatch appears
  /// here, real labels alone reproduce it in this configuration; if it
  /// does not appear, real labels on plain content do not reproduce it
  /// here and a single negative is not a causal exclusion. If neither
  /// new cell reproduces while the content+real-labels cell did, the
  /// joint combination is what reproduced in this environment - an
  /// interaction observation about these runs, not proof of mechanism.
  /// Known and declared: whether the real label "Lists to share"
  /// duplicates the plain List Outline's role description is unknown
  /// (the full app shows no duplicate-role finding); if one appears
  /// here it is a label-coincidence observation about this cell,
  /// immaterial to the per-element mismatch discrimination. A single
  /// run does not establish recurrence.
  @MainActor
  func testAccessibilityAuditMinimalFixtureRealLabels() throws {
    try runMinimalFixtureAudit(
      extraArguments: [
        "--arx-minimal-real-labels", "--arx-minimal-probes", "--arx-minimal-axgroup",
        "--arx-dump-view-hierarchy",
      ],
      artifactName: "minimal-real-labels-audit-window.png")
  }

  /// Delta 6a of the ladder: the sidebar half of the content variable.
  /// Identical to the delta-4 content run except that only the sidebar
  /// column renders the full content shape (banner capsule, grant-list
  /// rows, Refresh button); the detail column stays plain. Real labels
  /// on both columns, on the combo (probes+axgroup) base, matching the
  /// delta-4 base so this cell differs from the reproducing content
  /// cell by exactly the detail content. Bounded readings, hypotheses
  /// only: if the mismatch appears here, the detail content is not
  /// necessary for reproduction in this configuration; if it does not
  /// appear, sidebar-only content does not reproduce it here and a
  /// single negative is not a causal exclusion. If neither half
  /// reproduces while the union did, that is an interaction observation
  /// about these runs, not proof of mechanism. A single run does not
  /// establish recurrence. Known and declared: the plain detail column
  /// under a real label may show the plain-content duplicate-role
  /// coincidence observed in the delta-5 cells; immaterial to the
  /// per-element mismatch discrimination.
  @MainActor
  func testAccessibilityAuditMinimalFixtureSidebarContent() throws {
    try runMinimalFixtureAudit(
      extraArguments: [
        "--arx-minimal-sidebar-content", "--arx-minimal-real-labels", "--arx-minimal-probes",
        "--arx-minimal-axgroup", "--arx-dump-view-hierarchy",
      ],
      artifactName: "minimal-sidebar-content-audit-window.png")
  }

  /// Delta 6b of the ladder: the detail half of the content variable.
  /// Identical to the delta-4 content run except that only the detail
  /// column renders the full content shape (bridge status, the three
  /// group boxes); the sidebar column stays plain. Real labels on both
  /// columns, on the combo (probes+axgroup) base. Bounded readings,
  /// hypotheses only: if the mismatch appears here, the sidebar content
  /// is not necessary for reproduction in this configuration; if it
  /// does not appear, detail-only content does not reproduce it here
  /// and a single negative is not a causal exclusion. A single run does
  /// not establish recurrence. Known and declared: the plain sidebar
  /// column under the real label "Lists to share" is the delta-5b cell
  /// shape and may show its duplicate-role coincidence; immaterial to
  /// the per-element mismatch discrimination.
  @MainActor
  func testAccessibilityAuditMinimalFixtureDetailContent() throws {
    try runMinimalFixtureAudit(
      extraArguments: [
        "--arx-minimal-detail-content", "--arx-minimal-real-labels", "--arx-minimal-probes",
        "--arx-minimal-axgroup", "--arx-dump-view-hierarchy",
      ],
      artifactName: "minimal-detail-content-audit-window.png")
  }

  /// Delta 7a of the ladder: the detail CONTAINER structure with simple
  /// text only. The sidebar stays plain; the detail column renders the
  /// ScrollView holding just the "Arx bridge" title and the bridge
  /// status text, no group boxes - isolating the container structure
  /// from the box content. Real labels, combo (probes+axgroup) base, so
  /// this cell differs from the reproducing detail-content cell by
  /// exactly the box content. Bounded readings, hypotheses only: if the
  /// mismatch appears here, the group boxes are not necessary for
  /// reproduction in this configuration and the ScrollView-plus-text
  /// shape suffices here; if it does not appear, the container alone
  /// does not reproduce it here and a single negative is not a causal
  /// exclusion. A single run does not establish recurrence. Known and
  /// declared: the plain sidebar under the real label "Lists to share"
  /// is the delta-5b cell shape and may show its duplicate-role
  /// coincidence; immaterial to the per-element mismatch discrimination.
  @MainActor
  func testAccessibilityAuditMinimalFixtureDetailContainer() throws {
    try runMinimalFixtureAudit(
      extraArguments: [
        "--arx-minimal-detail-container", "--arx-minimal-real-labels", "--arx-minimal-probes",
        "--arx-minimal-axgroup", "--arx-dump-view-hierarchy",
      ],
      artifactName: "minimal-detail-container-audit-window.png")
  }

  /// Delta 7b of the ladder: the detail BOX CONTENT without the
  /// container. The sidebar stays plain; the detail column renders the
  /// full detail content (title, status, all three group boxes, revoke
  /// caption) in a plain VStack WITHOUT the ScrollView wrapper -
  /// isolating the box content from the container structure. Real
  /// labels, combo (probes+axgroup) base, so this cell differs from the
  /// reproducing detail-content cell by exactly the ScrollView.
  /// Bounded readings, hypotheses only: if the mismatch appears here,
  /// the ScrollView container is not necessary for reproduction in this
  /// configuration; if it does not appear, the box content without the
  /// ScrollView does not reproduce it here and a single negative is not
  /// a causal exclusion. A single run does not establish recurrence.
  /// Declared caveat: without the ScrollView the long content may clip
  /// or overflow the window; that geometry difference is part of this
  /// cell, and no claim is made that the accessibility tree is
  /// unaffected by it. Known and declared: the plain sidebar under the
  /// real label may show the delta-5b duplicate-role coincidence;
  /// immaterial to the per-element mismatch discrimination.
  @MainActor
  func testAccessibilityAuditMinimalFixtureDetailNoScroll() throws {
    try runMinimalFixtureAudit(
      extraArguments: [
        "--arx-minimal-detail-noscroll", "--arx-minimal-real-labels", "--arx-minimal-probes",
        "--arx-minimal-axgroup", "--arx-dump-view-hierarchy",
      ],
      artifactName: "minimal-detail-noscroll-audit-window.png")
  }

  /// Delta 8a of the ladder: the three group boxes alone in the
  /// no-scroll VStack family (no title, status or revoke caption).
  /// Plain sidebar, real labels, combo (probes+axgroup) base, so this
  /// cell differs from the reproducing no-scroll cell by exactly the
  /// texts. Bounded readings, hypotheses only: if the mismatch appears
  /// here, the texts are not necessary for reproduction in this
  /// configuration; if it does not appear, the boxes alone do not
  /// reproduce it here and a single negative is not a causal exclusion.
  /// Geometry is NOT held identical between cells (the no-scroll family
  /// already grew the window); the actual window frame is recorded per
  /// run and reported with the result, not assumed. A single run does
  /// not establish recurrence. Known and declared: the plain sidebar
  /// under the real label may show the delta-5b duplicate-role
  /// coincidence; immaterial to the per-element mismatch discrimination.
  @MainActor
  func testAccessibilityAuditMinimalFixtureDetailBoxes() throws {
    try runMinimalFixtureAudit(
      extraArguments: [
        "--arx-minimal-detail-boxes", "--arx-minimal-real-labels", "--arx-minimal-probes",
        "--arx-minimal-axgroup", "--arx-dump-view-hierarchy",
      ],
      artifactName: "minimal-detail-boxes-audit-window.png")
  }

  /// Delta 8b of the ladder: the texts alone in the no-scroll VStack
  /// family (title, status, revoke caption; no group boxes). Plain
  /// sidebar, real labels, combo (probes+axgroup) base, so this cell
  /// differs from the reproducing no-scroll cell by exactly the boxes.
  /// Bounded readings, hypotheses only: if the mismatch appears here,
  /// the boxes are not necessary for reproduction in this
  /// configuration; if it does not appear, the texts alone do not
  /// reproduce it here and a single negative is not a causal exclusion.
  /// Geometry is NOT held identical between cells; the actual window
  /// frame is recorded per run and reported with the result, not
  /// assumed. A single run does not establish recurrence. Known and
  /// declared: the plain sidebar under the real label may show the
  /// delta-5b duplicate-role coincidence; immaterial to the per-element
  /// mismatch discrimination.
  @MainActor
  func testAccessibilityAuditMinimalFixtureDetailTexts() throws {
    try runMinimalFixtureAudit(
      extraArguments: [
        "--arx-minimal-detail-texts", "--arx-minimal-real-labels", "--arx-minimal-probes",
        "--arx-minimal-axgroup", "--arx-dump-view-hierarchy",
      ],
      artifactName: "minimal-detail-texts-audit-window.png")
  }

  /// Delta 9a of the ladder: the connection group box alone in the
  /// no-scroll VStack family, a one-box source/config reduction of the
  /// reproducing delta-8a boxes cell. Plain sidebar, real labels, combo
  /// (probes+axgroup) base, unchanged strict audit. Bounded readings,
  /// hypotheses only: if the mismatch appears here, this one box alone
  /// is sufficient for reproduction in this configuration (and the
  /// other two boxes are not necessary here); if it does not appear,
  /// this box alone does not reproduce it here and a single negative
  /// is not a causal exclusion. Geometry is NOT held identical between
  /// cells; the actual window frame is recorded per run and reported
  /// with the result, not assumed. A single run does not establish
  /// recurrence. Known and declared: the plain sidebar under the real
  /// label may show the delta-5b duplicate-role coincidence;
  /// immaterial to the per-element mismatch discrimination.
  @MainActor
  func testAccessibilityAuditMinimalFixtureDetailBoxConnection() throws {
    try runMinimalFixtureAudit(
      extraArguments: [
        "--arx-minimal-detail-box-connection", "--arx-minimal-real-labels", "--arx-minimal-probes",
        "--arx-minimal-axgroup", "--arx-dump-view-hierarchy",
      ],
      artifactName: "minimal-detail-box-connection-audit-window.png")
  }

  /// Delta 9b of the ladder: the new-client group box alone in the
  /// no-scroll VStack family, same reduction as 9a. Bounded readings,
  /// hypotheses only: if the mismatch appears here, this one box alone
  /// is sufficient for reproduction in this configuration (and the
  /// other two boxes are not necessary here); if it does not appear,
  /// this box alone does not reproduce it here and a single negative
  /// is not a causal exclusion. Geometry is NOT held identical between
  /// cells; the actual window frame is recorded per run and reported
  /// with the result, not assumed. A single run does not establish
  /// recurrence. Known and declared: the plain sidebar under the real
  /// label may show the delta-5b duplicate-role coincidence;
  /// immaterial to the per-element mismatch discrimination.
  @MainActor
  func testAccessibilityAuditMinimalFixtureDetailBoxNewClient() throws {
    try runMinimalFixtureAudit(
      extraArguments: [
        "--arx-minimal-detail-box-new-client", "--arx-minimal-real-labels", "--arx-minimal-probes",
        "--arx-minimal-axgroup", "--arx-dump-view-hierarchy",
      ],
      artifactName: "minimal-detail-box-new-client-audit-window.png")
  }

  /// Delta 9c of the ladder: the clients group box alone in the
  /// no-scroll VStack family, same reduction as 9a. Bounded readings,
  /// hypotheses only: if the mismatch appears here, this one box alone
  /// is sufficient for reproduction in this configuration (and the
  /// other two boxes are not necessary here); if it does not appear,
  /// this box alone does not reproduce it here and a single negative
  /// is not a causal exclusion. Geometry is NOT held identical between
  /// cells; the actual window frame is recorded per run and reported
  /// with the result, not assumed. A single run does not establish
  /// recurrence. Known and declared: the plain sidebar under the real
  /// label may show the delta-5b duplicate-role coincidence;
  /// immaterial to the per-element mismatch discrimination.
  @MainActor
  func testAccessibilityAuditMinimalFixtureDetailBoxClients() throws {
    try runMinimalFixtureAudit(
      extraArguments: [
        "--arx-minimal-detail-box-clients", "--arx-minimal-real-labels", "--arx-minimal-probes",
        "--arx-minimal-axgroup", "--arx-dump-view-hierarchy",
      ],
      artifactName: "minimal-detail-box-clients-audit-window.png")
  }

  /// Delta 10a of the ladder: the GroupBox chrome with inert content -
  /// GroupBox("Connection") wrapping one default-styled placeholder
  /// text, in the same no-scroll VStack family. This is a NEW
  /// COMPOSITION (no prior cell gave the chrome inert content), not a
  /// reduction. Plain sidebar, real labels, combo (probes+axgroup)
  /// base, unchanged strict audit. Bounded readings, hypotheses only:
  /// if the mismatch appears here, the chrome with inert content
  /// suffices for reproduction in this configuration; if it does not
  /// appear, this composition does not reproduce it here and a single
  /// negative is not a causal exclusion. Geometry is NOT held identical
  /// between cells; the actual window frame is recorded per run and
  /// reported with the result, not assumed. A single run does not
  /// establish recurrence. Known and declared: the plain sidebar under
  /// the real label may show the delta-5b duplicate-role coincidence;
  /// immaterial to the per-element mismatch discrimination.
  @MainActor
  func testAccessibilityAuditMinimalFixtureConnectionChrome() throws {
    try runMinimalFixtureAudit(
      extraArguments: [
        "--arx-minimal-connection-chrome", "--arx-minimal-real-labels", "--arx-minimal-probes",
        "--arx-minimal-axgroup", "--arx-dump-view-hierarchy",
      ],
      artifactName: "minimal-connection-chrome-audit-window.png")
  }

  /// Delta 10b of the ladder: the connection box's exact contents
  /// without the GroupBox chrome - a REDUCTION of the reproducing
  /// delta-9a cell, rendering the verbatim-shared connectionBoxContent
  /// builder in the same no-scroll VStack family. Plain sidebar, real
  /// labels, combo (probes+axgroup) base, unchanged strict audit.
  /// Bounded readings, hypotheses only: if the mismatch appears here,
  /// the contents alone suffice for reproduction in this configuration
  /// (and the chrome is not necessary here); if it does not appear,
  /// the contents alone do not reproduce it here and a single negative
  /// is not a causal exclusion. Geometry is NOT held identical between
  /// cells; the actual window frame is recorded per run and reported
  /// with the result, not assumed. A single run does not establish
  /// recurrence. Known and declared: the plain sidebar under the real
  /// label may show the delta-5b duplicate-role coincidence;
  /// immaterial to the per-element mismatch discrimination.
  @MainActor
  func testAccessibilityAuditMinimalFixtureConnectionContents() throws {
    try runMinimalFixtureAudit(
      extraArguments: [
        "--arx-minimal-connection-contents", "--arx-minimal-real-labels", "--arx-minimal-probes",
        "--arx-minimal-axgroup", "--arx-dump-view-hierarchy",
      ],
      artifactName: "minimal-connection-contents-audit-window.png")
  }

  /// Delta 11a of the ladder: the two connection text fields alone, a
  /// REDUCTION of the reproducing delta-10b contents cell (same inner
  /// VStack(alignment: .leading, spacing: 10).padding(6) shape, same
  /// no-scroll family wrapper, verbatim connectionFields pieces).
  /// Plain sidebar, real labels, combo (probes+axgroup) base, unchanged
  /// strict audit. Bounded readings, hypotheses only: if the mismatch
  /// appears here, the two text fields alone suffice for reproduction
  /// in this configuration (and the caption and buttons are not
  /// necessary here); if it does not appear, the fields alone do not
  /// reproduce it here and a single negative is not a causal
  /// exclusion. Geometry is NOT held identical between cells; the
  /// actual window frame is recorded per run and reported with the
  /// result, not assumed. A single run does not establish recurrence.
  /// Known and declared: the plain sidebar under the real label may
  /// show the delta-5b duplicate-role coincidence; immaterial to the
  /// per-element mismatch discrimination.
  @MainActor
  func testAccessibilityAuditMinimalFixtureConnectionFields() throws {
    try runMinimalFixtureAudit(
      extraArguments: [
        "--arx-minimal-connection-fields", "--arx-minimal-real-labels", "--arx-minimal-probes",
        "--arx-minimal-axgroup", "--arx-dump-view-hierarchy",
      ],
      artifactName: "minimal-connection-fields-audit-window.png")
  }

  /// Delta 11b of the ladder: the connection caption and button row
  /// alone, a REDUCTION of the reproducing delta-10b contents cell
  /// (same inner shape, same no-scroll family wrapper, verbatim
  /// connectionCaptionAndButtons pieces). Plain sidebar, real labels,
  /// combo (probes+axgroup) base, unchanged strict audit. Bounded
  /// readings, hypotheses only: if the mismatch appears here, the
  /// caption and buttons alone suffice for reproduction in this
  /// configuration (and the text fields are not necessary here); if it
  /// does not appear, the caption and buttons alone do not reproduce
  /// it here and a single negative is not a causal exclusion. Geometry
  /// is NOT held identical between cells; the actual window frame is
  /// recorded per run and reported with the result, not assumed. A
  /// single run does not establish recurrence. Known and declared: the
  /// plain sidebar under the real label may show the delta-5b
  /// duplicate-role coincidence; immaterial to the per-element
  /// mismatch discrimination.
  @MainActor
  func testAccessibilityAuditMinimalFixtureConnectionCaptionButtons() throws {
    try runMinimalFixtureAudit(
      extraArguments: [
        "--arx-minimal-connection-caption-buttons", "--arx-minimal-real-labels",
        "--arx-minimal-probes", "--arx-minimal-axgroup", "--arx-dump-view-hierarchy",
      ],
      artifactName: "minimal-connection-caption-buttons-audit-window.png")
  }

  /// Delta 12a of the ladder: the connection origin text field alone,
  /// a REDUCTION of the reproducing delta-11a fields cell (same inner
  /// VStack(alignment: .leading, spacing: 10).padding(6) shape, same
  /// no-scroll family wrapper, verbatim connectionOriginField piece).
  /// Plain sidebar, real labels, combo (probes+axgroup) base, unchanged
  /// strict audit. Bounded readings, hypotheses only: if the mismatch
  /// appears here, this single tested field (the origin field) alone
  /// suffices for reproduction in this configuration; that says
  /// nothing about any other text field generally. If it does not
  /// appear, the origin field alone does not reproduce it here and a
  /// single negative is not a causal exclusion. Geometry is NOT held
  /// identical between cells; the actual window frame is recorded per
  /// run and reported with the result, not assumed. A single run does
  /// not establish recurrence. Known and declared: the plain sidebar
  /// under the real label may show the delta-5b duplicate-role
  /// coincidence; immaterial to the per-element mismatch
  /// discrimination.
  @MainActor
  func testAccessibilityAuditMinimalFixtureConnectionOriginField() throws {
    try runMinimalFixtureAudit(
      extraArguments: [
        "--arx-minimal-connection-origin-field", "--arx-minimal-real-labels",
        "--arx-minimal-probes", "--arx-minimal-axgroup", "--arx-dump-view-hierarchy",
      ],
      artifactName: "minimal-connection-origin-field-audit-window.png")
  }

  /// Delta 12b of the ladder: the connection port text field alone, a
  /// REDUCTION of the reproducing delta-11a fields cell (same inner
  /// VStack(alignment: .leading, spacing: 10).padding(6) shape, same
  /// no-scroll family wrapper, verbatim connectionPortField piece).
  /// Plain sidebar, real labels, combo (probes+axgroup) base, unchanged
  /// strict audit. Bounded readings, hypotheses only: if the mismatch
  /// appears here, this single tested field (the port field) alone
  /// suffices for reproduction in this configuration; that says
  /// nothing about any other text field generally. If it does not
  /// appear, the port field alone does not reproduce it here and a
  /// single negative is not a causal exclusion. Geometry is NOT held
  /// identical between cells; the actual window frame is recorded per
  /// run and reported with the result, not assumed. A single run does
  /// not establish recurrence. Known and declared: the plain sidebar
  /// under the real label may show the delta-5b duplicate-role
  /// coincidence; immaterial to the per-element mismatch
  /// discrimination.
  @MainActor
  func testAccessibilityAuditMinimalFixtureConnectionPortField() throws {
    try runMinimalFixtureAudit(
      extraArguments: [
        "--arx-minimal-connection-port-field", "--arx-minimal-real-labels",
        "--arx-minimal-probes", "--arx-minimal-axgroup", "--arx-dump-view-hierarchy",
      ],
      artifactName: "minimal-connection-port-field-audit-window.png")
  }

  /// Delta 13a of the ladder: the connection origin text field
  /// identical except for the removed .textContentType(.URL) modifier,
  /// contrasted same-run with the reproducing delta-12a origin-field
  /// cell (same label, same empty binding, same inner shape, same
  /// no-scroll family wrapper). Plain sidebar, real labels, combo
  /// (probes+axgroup) base, unchanged strict audit. Bounded readings,
  /// hypotheses only: if the mismatch appears here, the origin field
  /// without the modifier also suffices in this configuration and the
  /// modifier is not necessary here; if it does not appear, that is a
  /// single negative - the modifier is implicated in this
  /// configuration only, not excluded generally. Geometry is NOT held
  /// identical between cells; the actual window frame is recorded per
  /// run and reported with the result, not assumed. A single run does
  /// not establish recurrence. Known and declared: the plain sidebar
  /// under the real label may show the delta-5b duplicate-role
  /// coincidence; immaterial to the per-element mismatch
  /// discrimination.
  @MainActor
  func testAccessibilityAuditMinimalFixtureConnectionOriginNoContentType() throws {
    try runMinimalFixtureAudit(
      extraArguments: [
        "--arx-minimal-connection-origin-no-content-type", "--arx-minimal-real-labels",
        "--arx-minimal-probes", "--arx-minimal-axgroup", "--arx-dump-view-hierarchy",
      ],
      artifactName: "minimal-connection-origin-no-content-type-audit-window.png")
  }

  /// Delta 13b of the ladder: the new-client box's client-label text
  /// field alone, a REDUCTION of the reproducing delta-9b new-client
  /// box cell using that box's own inner VStack(alignment: .leading,
  /// spacing: 10).padding(6) shape and the same no-scroll family
  /// wrapper. A third tested field with a distinct label, a filled
  /// value and no contentType modifier. Plain sidebar, real labels,
  /// combo (probes+axgroup) base, unchanged strict audit. Bounded
  /// readings, hypotheses only: if the mismatch appears here, this
  /// third tested field also suffices in this configuration; that
  /// says nothing about text fields generally. If it does not appear,
  /// that is a single negative, not a causal exclusion. Geometry is
  /// NOT held identical between cells; the actual window frame is
  /// recorded per run and reported with the result, not assumed. A
  /// single run does not establish recurrence. Known and declared: the
  /// plain sidebar under the real label may show the delta-5b
  /// duplicate-role coincidence; immaterial to the per-element
  /// mismatch discrimination.
  @MainActor
  func testAccessibilityAuditMinimalFixtureNewClientLabelField() throws {
    try runMinimalFixtureAudit(
      extraArguments: [
        "--arx-minimal-new-client-label-field", "--arx-minimal-real-labels",
        "--arx-minimal-probes", "--arx-minimal-axgroup", "--arx-dump-view-hierarchy",
      ],
      artifactName: "minimal-new-client-label-field-audit-window.png")
  }

  /// Delta 13c of the ladder: the new-client box's Read selected
  /// lists Toggle alone, a second REDUCTION of the reproducing
  /// delta-9b new-client box cell in that box's own inner shape and
  /// the same no-scroll family wrapper, contrasting control type
  /// against the single-field cells. Plain sidebar, real labels,
  /// combo (probes+axgroup) base, unchanged strict audit. Bounded
  /// readings, hypotheses only: if the mismatch appears here, THIS
  /// tested Toggle cell suffices in this configuration - it says
  /// nothing about interactive controls generally; if it does not
  /// appear, that is a single negative, not a causal exclusion of
  /// non-field controls. Geometry is NOT held identical between
  /// cells; the actual window frame is recorded per run and reported
  /// with the result, not assumed. A single run does not establish
  /// recurrence. Known and declared: the plain sidebar under the real
  /// label may show the delta-5b duplicate-role coincidence;
  /// immaterial to the per-element mismatch discrimination.
  @MainActor
  func testAccessibilityAuditMinimalFixtureNewClientReadToggle() throws {
    try runMinimalFixtureAudit(
      extraArguments: [
        "--arx-minimal-new-client-read-toggle", "--arx-minimal-real-labels",
        "--arx-minimal-probes", "--arx-minimal-axgroup", "--arx-dump-view-hierarchy",
      ],
      artifactName: "minimal-new-client-read-toggle-audit-window.png")
  }

  /// Delta 14a of the ladder: the verbatim delta-12a origin-field cell
  /// with keyboard focus displaced off the field (DEBUG-only
  /// first-responder displacement to nil; onAppear adds no element).
  /// Same content, shape, wrapper, base and unchanged strict audit as
  /// the origin-field cell, same run. Validity gate: the additive
  /// focus print, the window render and the tree comparison must show
  /// the field NOT Keyboard Focused at audit time, with every other
  /// tree difference versus the origin-field cell itemized as a
  /// residual; without that evidence this cell is INVALID and takes
  /// no reading. Bounded readings, hypotheses only: if the mismatch
  /// appears in a valid unfocused cell, the origin field without
  /// keyboard focus also suffices in this configuration and focus is
  /// not necessary here; if it does not appear in a valid unfocused
  /// cell, focus on the field is implicated in this configuration
  /// only - a single controlled pair, not a mechanism and not an
  /// exclusion. Geometry is NOT held identical between cells; the
  /// actual window frame is recorded per run and reported, not
  /// assumed. A single run does not establish recurrence. Known and
  /// declared: the plain sidebar under the real label may show the
  /// delta-5b duplicate-role coincidence; immaterial to the
  /// per-element mismatch discrimination.
  @MainActor
  func testAccessibilityAuditMinimalFixtureConnectionOriginFieldUnfocused() throws {
    try runMinimalFixtureAudit(
      extraArguments: [
        "--arx-minimal-connection-origin-field-unfocused", "--arx-minimal-real-labels",
        "--arx-minimal-probes", "--arx-minimal-axgroup", "--arx-dump-view-hierarchy",
      ],
      artifactName: "minimal-connection-origin-field-unfocused-audit-window.png")
  }

  /// Delta 15: the verbatim delta-12a origin-field cell with keyboard
  /// focus displaced at 1.25/1.75/2.25s - after the shared descriptor
  /// phases - while the extended schedule observes the responder
  /// 0.25s after each fire (1.5/2.0/2.5s). This test POLLS for the
  /// complete six-line capture with a bounded deadline BEFORE running
  /// the audit, so the audit is sequenced behind validated evidence
  /// of a successful persistent displacement: phases 0-2 are expected
  /// to read _SystemTextFieldFieldEditor (matching the focused cell)
  /// and phases 3-5 window, and the capture gate enforces that exact
  /// pattern. An incomplete or malformed capture by the deadline is
  /// INVALID, and a complete capture whose tokens miss that pattern
  /// is INVALID too (invalid-pattern, printed with the raw observed
  /// tokens); either way the audit still runs, but no
  /// displacement-sequenced claim attaches to it. Declared gap: focus
  /// changes between the last observation (2.5s) and the audit's own
  /// start are unobserved; no responder-at-audit-time claim is made.
  /// Bounded readings, hypotheses only: if the Parent/Child mismatch
  /// appears in a valid late-unfocused cell, first-second focus
  /// history still co-occurs with the mismatch when the audit ran
  /// after validated displacement, weakening audit-time focus as the
  /// discriminating variable in this configuration; if it does not
  /// appear, both displacement timings share the absence, consistent
  /// with (not proving) audit-time focus being the associate. One
  /// cell, one run: no mechanism, no exclusion, no recurrence claim.
  @MainActor
  func testAccessibilityAuditMinimalFixtureConnectionOriginFieldLateUnfocused() throws {
    try runMinimalFixtureAudit(
      extraArguments: [
        "--arx-minimal-connection-origin-field-late-unfocused", "--arx-minimal-real-labels",
        "--arx-minimal-probes", "--arx-minimal-axgroup", "--arx-dump-view-hierarchy",
      ],
      artifactName: "minimal-connection-origin-field-late-unfocused-audit-window.png",
      expectedPhaseLines: 6,
      awaitCompletePhases: true)
  }

  /// Delta 16a of the ladder: the plain half of the matched
  /// caption-context pair for the Contrast class. The SAME caption
  /// text (string, font, default foreground) as the failing
  /// plainDetail caption, mounted alone at fixed coordinates, in a
  /// plain VStack - no GroupBox. The strict audit is unchanged.
  /// Bounded readings, hypotheses only: this cell is one half of ONE
  /// discriminating comparison, read only together with its GroupBox
  /// sibling and the recorded frames. If the frames differ, the
  /// comparison is inconclusive by design, never negative. If this
  /// cell fails and the sibling passes, the verdict is sensitive to
  /// THIS container-context bundle in this configuration - not to a
  /// named mechanism, and not an automatic app fix. If both fail,
  /// THIS GroupBox variant did not change the verdict; that does not
  /// establish a text-intrinsic cause and does not rule out other
  /// container interactions. If this cell passes while the unchanged
  /// plainDetail cells still fail in the same run, the pair premise
  /// itself needs reassessment. A single run does not establish
  /// recurrence.
  @MainActor
  func testAccessibilityAuditMinimalFixtureCaptionContextPlain() throws {
    try runMinimalFixtureAudit(
      extraArguments: ["--arx-minimal-caption-context-plain"],
      artifactName: "minimal-caption-context-plain-audit-window.png",
      observedTargetIdentifier: "caption-context-target")
  }

  /// Delta 16b of the ladder: the GroupBox half of the matched
  /// caption-context pair. The SAME text element inside
  /// GroupBox("Connection") containment, the context carrying the
  /// passing caption neighbor, at the same fixed coordinates as the
  /// plain half. The strict audit is unchanged; the baseline
  /// plainDetail cells in the same run re-establish the existing
  /// failure. Read only together with its plain sibling and the
  /// recorded frames; every outcome branch is bounded as declared on
  /// delta 16a, and neither half alone carries a conclusion.
  @MainActor
  func testAccessibilityAuditMinimalFixtureCaptionContextGroupBox() throws {
    try runMinimalFixtureAudit(
      extraArguments: ["--arx-minimal-caption-context-groupbox"],
      artifactName: "minimal-caption-context-groupbox-audit-window.png",
      observedTargetIdentifier: "caption-context-target")
  }

  /// Delta 17a of the ladder: the plain half of the FOREGROUND-
  /// SECONDARY caption-context pair. Identical to delta 16a except
  /// the caption text carries an explicit
  /// .foregroundStyle(.secondary); the default-foreground pair (16a/
  /// 16b) is retained unchanged as the same-run control. Observed
  /// outcomes are bounded by the recorded-frame gate (a mismatch is
  /// inconclusive, never negative) and the anomaly downgrade (if the
  /// default pair does not reproduce its c11 verdicts in the same
  /// run, cross-pair reads downgrade to raw verdicts). Bounded
  /// readings, hypotheses only, pre-registered:
  /// - If BOTH secondary halves fail, no containment split is
  ///   observed for THIS caption/style/pair/run. That does not
  ///   eliminate containment as a factor for other styles or
  ///   configurations. If the unchanged default pair reproduces its
  ///   c11 split in the same run, the foreground style is ASSOCIATED
  ///   with the split within this run only - association, not
  ///   mechanism.
  /// - If plain-secondary fails and groupbox-secondary passes, the
  ///   split persists under .secondary for THIS pair/run; every other
  ///   difference from any other context (window, position, siblings,
  ///   titles, surrounding content) remains uncontrolled.
  /// - If plain-secondary PASSES, the style change altered this
  ///   plain half's outcome for this fixture; report raw verdicts
  ///   only, no mechanism claim.
  /// - A missing target or a frame mismatch makes the read
  ///   inconclusive by design, never negative. If the unchanged
  ///   default pair does NOT reproduce its c11 verdicts in the same
  ///   run, the run is anomalous: cross-pair reads downgrade to raw
  ///   verdicts and no recurrence is claimed.
  @MainActor
  func testAccessibilityAuditMinimalFixtureCaptionContextPlainSecondary() throws {
    try runMinimalFixtureAudit(
      extraArguments: ["--arx-minimal-caption-context-plain-secondary"],
      artifactName: "minimal-caption-context-plain-secondary-audit-window.png",
      observedTargetIdentifier: "caption-context-secondary-target")
  }

  /// Delta 17b of the ladder: the GroupBox half of the FOREGROUND-
  /// SECONDARY caption-context pair. The SAME .secondary caption text
  /// inside the SAME GroupBox("Connection") containment at the same
  /// fixed coordinates as its plain sibling. Read only together with
  /// delta 17a and the recorded frames; every outcome branch is
  /// bounded as declared on delta 17a, and neither half alone carries
  /// a conclusion.
  @MainActor
  func testAccessibilityAuditMinimalFixtureCaptionContextGroupBoxSecondary() throws {
    try runMinimalFixtureAudit(
      extraArguments: ["--arx-minimal-caption-context-groupbox-secondary"],
      artifactName: "minimal-caption-context-groupbox-secondary-audit-window.png",
      observedTargetIdentifier: "caption-context-secondary-target")
  }

  /// Delta 18a of the ladder: the plain half of the matched
  /// bridge-status pair. The exact bridge-status string with its
  /// real .primary foreground and default font, mounted alone - the
  /// string whose full-app cell currently fails Contrast (one of
  /// three current full-app audit findings; this pair probes only
  /// that one and leaves the fixture-data Contrast and the unnamed
  /// Parent/Child mismatch untouched). A hypothesis, not a fix.
  /// Bounded readings, hypotheses only, pre-registered:
  /// - If this half fails and the GroupBox sibling passes, the
  ///   containment association observed for the default-foreground
  ///   caption extends to THIS text/style/pair/run - association,
  ///   not mechanism, and not by itself approval for any app change.
  /// - If BOTH halves fail, no containment split is observed for
  ///   THIS cell/run; that does not eliminate containment for other
  ///   cells or configurations.
  /// - If this half PASSES, the outcome contradicts the pair's
  ///   premise; report raw verdicts only, no mechanism claim.
  /// - A missing target or a frame mismatch makes the read
  ///   inconclusive by design, never negative; a spacer correction
  ///   would then be a separately proposed step. If the caption
  ///   pairs in the same run do not reproduce their c14 verdicts,
  ///   the run is anomalous: cross-pair reads downgrade to raw
  ///   verdicts and no recurrence is claimed.
  @MainActor
  func testAccessibilityAuditMinimalFixtureBridgeStatusPlain() throws {
    try runMinimalFixtureAudit(
      extraArguments: ["--arx-minimal-bridge-status-plain"],
      artifactName: "minimal-bridge-status-plain-audit-window.png",
      observedTargetIdentifier: "bridge-status-pair-target")
  }

  /// Delta 18b of the ladder: the GroupBox half of the matched
  /// bridge-status pair. The SAME text element inside the same
  /// GroupBox("Connection") containment at the same fixed
  /// coordinates as its plain sibling. Read only together with
  /// delta 18a and the recorded frames; every outcome branch is
  /// bounded as declared on delta 18a, and neither half alone
  /// carries a conclusion.
  @MainActor
  func testAccessibilityAuditMinimalFixtureBridgeStatusGroupBox() throws {
    try runMinimalFixtureAudit(
      extraArguments: ["--arx-minimal-bridge-status-groupbox"],
      artifactName: "minimal-bridge-status-groupbox-audit-window.png",
      observedTargetIdentifier: "bridge-status-pair-target")
  }

  /// Delta 19 of the reduction ladder: the height discriminator. The
  /// cell content is the delta-8b texts cell verbatim plus a trailing
  /// 1600-point clear filler, so total content height exceeds any
  /// window the screen can hold and the only intended difference from
  /// the passing delta-8b cell in this run is content height. The
  /// window may auto-grow to fit content (contentMinSize), so the
  /// overflow condition is evidenced by the recorded pre-audit window
  /// frame, never assumed: a window frame that fits this content makes
  /// the run invalid, not negative. Pre-registered readings,
  /// hypotheses only: if the identical bridge status text is flagged
  /// here while passing in delta 8b, content height is implicated for
  /// these cells; if it passes here, content height alone does not
  /// reproduce the flag in this run and a single negative is not a
  /// causal exclusion. A single run does not establish recurrence.
  @MainActor
  func testAccessibilityAuditMinimalFixtureHeightOverflow() throws {
    try runMinimalFixtureAudit(
      extraArguments: [
        "--arx-minimal-height-overflow",
        "--arx-minimal-real-labels",
        "--arx-minimal-probes",
        "--arx-minimal-axgroup",
        "--arx-dump-view-hierarchy",
      ],
      artifactName: "minimal-height-overflow-audit-window.png",
      observedTargetIdentifier: "bridge-status")
  }

  /// Delta 20 of the reduction ladder: the banner capsule variant. The
  /// full content sidebar from delta 6a with only the banner's capsule
  /// background removed; every other modifier is identical. The banner
  /// line has been flagged in every fixture replica that renders it
  /// and in the full app, at the same small frame. Pre-registered
  /// readings, hypotheses only: if the capsule-free banner passes here
  /// while the delta-6a control fails in the same run, the capsule
  /// background is implicated; if it is still flagged, the capsule is
  /// not the cause in this run and a single negative is not a causal
  /// exclusion. A single run does not establish recurrence.
  @MainActor
  func testAccessibilityAuditMinimalFixtureSidebarBannerNoCapsule() throws {
    try runMinimalFixtureAudit(
      extraArguments: [
        "--arx-minimal-sidebar-banner-no-capsule",
        "--arx-minimal-real-labels",
        "--arx-minimal-probes",
        "--arx-minimal-axgroup",
        "--arx-dump-view-hierarchy",
      ],
      artifactName: "minimal-sidebar-banner-no-capsule-audit-window.png")
  }

  /// Delta 21a of the reduction ladder: the scroll pair's fit half.
  /// The texts cell content inside a ScrollView pinned to a fixed
  /// 300-point viewport, with content that fits. Matched control for
  /// the overflow half; the only intended difference between the
  /// halves is scroll-content height. Registered evidence gates: the
  /// two halves must record EQUAL pre-audit window frames (a
  /// difference is INVALID, never negative); the bridge-status target
  /// frame is recorded in both; both view-hierarchy dumps are
  /// captured (c18: delivered complete through the nonce-named file
  /// channel - the app's stdout does not reach the retained job log);
  /// and the geometry receipt must be delivered with both values
  /// measured at runtime (a GeometryReader behind the framed
  /// ScrollView measures the viewport, a second inside the content
  /// measures the content) and the inequality enforced numerically on
  /// the pre-registered primary, the preference-key stackFrame - this
  /// half must measure content at most the measured viewport. c18
  /// adds comparative observations (the @State-delivered contentSize,
  /// a 1600-point filler calibration, a write sequence number) that
  /// are printed, never enforced. A fixed frame alone is not runtime
  /// proof after c16's lesson: a missing, malformed, pending or
  /// inequality-violating receipt FAILS the test, never a fits
  /// finding.
  @MainActor
  func testAccessibilityAuditMinimalFixtureScrollFit() throws {
    try runMinimalFixtureAudit(
      extraArguments: [
        "--arx-minimal-scroll-fit",
        "--arx-minimal-real-labels",
        "--arx-minimal-probes",
        "--arx-minimal-axgroup",
        "--arx-dump-view-hierarchy",
      ],
      artifactName: "minimal-scroll-fit-audit-window.png",
      observedTargetIdentifier: "bridge-status",
      geometryReceiptCell: "fit")
  }

  /// Delta 21b of the reduction ladder: the scroll pair's overflow
  /// half. Identical to the fit half plus a trailing 1600-point clear
  /// filler inside the scroll content, so the content overflows the
  /// pinned 300-point viewport - the configuration the failing app
  /// cells actually render (status at scroll-rest top, content
  /// overflowing below), which the c16 window-growth cell could not
  /// construct. Same registered gates as the fit half; this half's
  /// receipt must measure content at least twice the measured
  /// viewport on the pre-registered primary (the preference-key
  /// stackFrame); this half also carries the 1600-point filler
  /// calibration measurement. Bounded
  /// readings, hypotheses only: bridge-status flagged here but not in
  /// the fit half implicates scroll-overflow for these cells
  /// (association, one run); unflagged here does not bear the
  /// hypothesis out in this run, and a single negative is not a
  /// causal exclusion. A single run does not establish recurrence.
  @MainActor
  func testAccessibilityAuditMinimalFixtureScrollOverflow() throws {
    try runMinimalFixtureAudit(
      extraArguments: [
        "--arx-minimal-scroll-overflow",
        "--arx-minimal-real-labels",
        "--arx-minimal-probes",
        "--arx-minimal-axgroup",
        "--arx-dump-view-hierarchy",
      ],
      artifactName: "minimal-scroll-overflow-audit-window.png",
      observedTargetIdentifier: "bridge-status",
      geometryReceiptCell: "overflow")
  }

  /// Delta 22 of the reduction ladder: the banner alone. The fixture
  /// banner line, standard capsule form verbatim, without the sidebar,
  /// List or any sibling. The whole context bundle varies at once, so
  /// the registered readings stay bundle-bounded: flagged alone
  /// implicates the text/style family in this configuration
  /// (association, one run) - it cannot isolate font, color or padding
  /// as the cause; unflagged alone implicates the context bundle, not
  /// any single variable. The delta-20 capsule negative was bounded to
  /// its own configuration and does not transfer here. Census reading
  /// only: the banner carries no accessibility identifier. A single
  /// run does not establish recurrence.
  @MainActor
  func testAccessibilityAuditMinimalFixtureBannerAlone() throws {
    try runMinimalFixtureAudit(
      extraArguments: [
        "--arx-minimal-banner-alone",
        "--arx-minimal-real-labels",
        "--arx-minimal-probes",
        "--arx-minimal-axgroup",
        "--arx-dump-view-hierarchy",
      ],
      artifactName: "minimal-banner-alone-audit-window.png")
  }

  /// Shared body of the minimal-fixture control runs: relaunch into the
  /// minimal fixture with the given extra arguments, record the pre-audit
  /// state observations and a window render (evidence for interpreting any
  /// contrast finding against actual pixels, mirroring the full-app
  /// audit's capture), then run the SAME strict audit handler as the
  /// full-app audit and assert on its collected issues. Observations are
  /// never assertions.
  private func runMinimalFixtureAudit(
    extraArguments: [String], artifactName: String,
    expectedPhaseLines: Int = 3, awaitCompletePhases: Bool = false,
    observedTargetIdentifier: String? = nil,
    geometryReceiptCell: String? = nil
  ) throws {
    app.terminate()
    app = XCUIApplication()
    app.launchArguments = ["--bridge-fixtures", "--arx-minimal-fixture"] + extraArguments
    // Observability repair (c3/c4): the app's stdout never reaches the
    // job log, so the DEBUG responder descriptors travel through a file
    // instead. A fresh per-launch nonce names it; a missing or stale
    // file (no nonce match) is INVALID evidence, never a negative
    // finding.
    //
    // Candidate locations, both fail-closed (absence reads INVALID):
    // 1. NSTemporaryDirectory(), documented by Apple as "the temporary
    //    directory for the current user". The CI workflow builds with
    //    CODE_SIGNING_ALLOWED=NO, so the app likely runs unsigned and
    //    unsandboxed; app and runner sharing one TMPDIR is then the
    //    expected case, but that equality remains a hypothesis until a
    //    launch actually delivers descriptors - a shared UID alone
    //    does not prove an identical process environment.
    // 2. ~/Library/Containers/com.soliskit.Arx/Data/tmp. Apple's sandbox
    //    documentation places a sandboxed app's container under
    //    ~/Library/Containers and, on macOS 14+, associates it via the
    //    app's code signature; the bundle identifier is pinned in
    //    project.pbxproj. An unsigned build makes this the less likely
    //    case, and macOS can additionally require user consent before
    //    one process enters another app's container, which a headless
    //    runner cannot grant: if the path is unreachable the read
    //    fails and the outcome is INVALID, never negative. No runtime
    //    validity is claimed before actual descriptor delivery.
    let nonce = UUID().uuidString
    var launchEnvironment = ["ARX_RESPONDER_PHASES_NONCE": nonce]
    // Geometry receipt channel (delta 21): same nonce-per-launch
    // fail-closed pattern as the responder phases, written by the
    // scroll pair cells only.
    let geometryNonce = UUID().uuidString
    let dumpNonce = UUID().uuidString
    if geometryReceiptCell != nil {
      launchEnvironment["ARX_GEOMETRY_NONCE"] = geometryNonce
      // c18: the registered hierarchy gate travels the same nonce-file
      // family (see printViewHierarchyDump); only the scroll pair cells
      // carry the gate, so only they get a dump nonce.
      launchEnvironment["ARX_DUMP_NONCE"] = dumpNonce
    }
    app.launchEnvironment = launchEnvironment
    let phasesFileName = "arx-responder-phases-\(nonce).txt"
    let phasesFileCandidates = [
      URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(phasesFileName),
      URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Containers/com.soliskit.Arx/Data/tmp")
        .appendingPathComponent(phasesFileName),
    ]
    app.launch()
    // Cleanup is registered up front so it runs even when the audit
    // throws. Removal is best-effort: a leftover file carries a stale
    // nonce that no future launch can match, so residue is never
    // consumed.
    let geometryFileName = "arx-geometry-\(geometryNonce).txt"
    let geometryFileCandidates = [
      URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(geometryFileName),
      URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Containers/com.soliskit.Arx/Data/tmp")
        .appendingPathComponent(geometryFileName),
    ]
    let dumpFileName = "arx-dump-\(dumpNonce).txt"
    let dumpFileCandidates = [
      URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(dumpFileName),
      URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Containers/com.soliskit.Arx/Data/tmp")
        .appendingPathComponent(dumpFileName),
    ]
    defer {
      for file in phasesFileCandidates { try? FileManager.default.removeItem(at: file) }
      for file in geometryFileCandidates { try? FileManager.default.removeItem(at: file) }
      for file in dumpFileCandidates { try? FileManager.default.removeItem(at: file) }
    }
    XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
    let application = app!

    print("pre-audit-app-state: \(application.state.rawValue)")
    print("pre-audit-window-enabled: \(application.windows["main"].isEnabled)")
    // Additive observation (delta 8): record the actual window frame per
    // cell, because the no-scroll family demonstrated that geometry
    // varies with content. Observation only, never an assertion.
    print("pre-audit-window-frame: \(application.windows["main"].frame)")
    // Matched-pair observation (delta 16): when a cell names a target
    // element, record its existence and actual AX frame so the pair
    // comparison's same-coordinates premise is verified evidence.
    // Observation only, never an assertion; a missing target or a
    // frame mismatch makes the comparison inconclusive by design.
    if let observedTargetIdentifier {
      let target = application.staticTexts[observedTargetIdentifier]
      print("pre-audit-target-exists: \(target.exists)")
      print("pre-audit-target-frame: \(target.frame)")
    }
    let auditPNG = application.screenshot().pngRepresentation
    let artifacts = URL(fileURLWithPath: "/tmp/uitest-artifacts")
    try? FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
    try? auditPNG.write(to: artifacts.appendingPathComponent(artifactName))

    let issues: [String]
    if awaitCompletePhases {
      // Sequenced capture (delta 15): poll for the complete validated
      // capture with a bounded deadline BEFORE the audit runs, so the
      // audit is gated on observed displacement, not on a schedule
      // assumption. A deadline miss is INVALID, never negative.
      printResponderPhasesAwaited(from: phasesFileCandidates, expectedLines: expectedPhaseLines)
      issues = try strictAuditIssueLines(application)
    } else {
      issues = try strictAuditIssueLines(application)
      // Bounded handoff read (c4). Placed after the audit, whose
      // wall-clock duration exceeds the 1.0s final phase delay in
      // practice; a file still short at read time yields INVALID-partial,
      // never partial evidence. The read is bounded at the byte level:
      // at most limit+1 bytes are read, and anything longer, malformed
      // or mis-encoded is INVALID. The audit above is unchanged; these
      // lines are observation, never assertions.
      printResponderPhases(from: phasesFileCandidates)
    }
    // Geometry receipt (delta 21): fail-closed. The registered
    // reading of the scroll pair requires this receipt; a missing,
    // malformed or inequality-violating one fails the test below, so
    // the cell is INVALID, never a fits/overflow finding.
    if let geometryReceiptCell {
      // Fail-closed: an invalid receipt fails the test, so an invalid
      // run can never read as a clean audit negative.
      if !printGeometryReceipt(from: geometryFileCandidates, expectedCell: geometryReceiptCell) {
        XCTFail("scroll-geometry: INVALID")
      }
      // c18: the registered reading of the scroll pair also requires
      // the COMPLETE view-hierarchy dump, delivered through the
      // nonce-named file (the app's stdout does not reach the retained
      // job log). Missing, over-cap, mis-encoded or partial is INVALID,
      // never an absent-hierarchy finding.
      if !printViewHierarchyDump(from: dumpFileCandidates) {
        XCTFail("arx-view-dump: INVALID")
      }
    }
    XCTAssertTrue(issues.isEmpty, issues.joined(separator: "\n---\n"))
  }

  /// Reads the handoff file once, enforcing the byte-level bound and
  /// the exact line grammar. Returns the validated lines, or nil with
  /// the INVALID marker printed. Shared by the post-audit read and
  /// the pre-audit awaited capture.
  private func readResponderPhases(from candidates: [URL], expectedLines: Int) -> [String]? {
    guard let file = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
      let handle = try? FileHandle(forReadingFrom: file)
    else {
      print("pre-audit-first-responder: invalid-missing")
      return nil
    }
    defer { try? handle.close() }
    let data = handle.readData(ofLength: Self.phasesReadLimit + 1)
    guard data.count <= Self.phasesReadLimit else {
      print("pre-audit-first-responder: invalid-oversized")
      return nil
    }
    guard let text = String(data: data, encoding: .utf8) else {
      print("pre-audit-first-responder: invalid-encoding")
      return nil
    }
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).dropLast()
    let valid =
      lines.count == expectedLines
      && lines.enumerated().allSatisfy { index, line in
        line.hasPrefix("pre-audit-first-responder-\(index): ")
          && !line.dropFirst("pre-audit-first-responder-\(index): ".count).isEmpty
      }
    guard valid else {
      print("pre-audit-first-responder: invalid-partial")
      return nil
    }
    return lines.map(String.init)
  }

  /// Prints the three DEBUG responder-phase descriptors the app handed
  /// over for this launch, or a single INVALID marker. The first
  /// candidate file that exists is the handoff; a line is well-formed
  /// only as `pre-audit-first-responder-<phase>: <token>` with a known
  /// phase index. The read is bounded at the byte level: at most
  /// `phasesReadLimit + 1` bytes are read, so an oversized file is
  /// rejected without being consumed. Anything else - missing file,
  /// short, oversized, mis-encoded, malformed - prints INVALID for
  /// that launch. Observation only; no assertions here.
  private static let phasesReadLimit = 1024

  private func printResponderPhases(from candidates: [URL]) {
    guard let lines = readResponderPhases(from: candidates, expectedLines: 3) else { return }
    for line in lines { print(line) }
  }

  /// Delta 21 geometry receipt read, fail-closed (c18 grammar): exactly
  /// one line of the shape
  /// "scroll-geometry: cell=<expected> seq=<n> viewport=<v|pending>
  /// contentSize=<s|pending> stackFrame=<f|pending>
  /// filler=<h|absent|pending>"
  /// with the registered inequality enforced numerically on the
  /// PRE-REGISTERED PRIMARY, stackFrame (the preference-key delivered
  /// frame measurement): the fit half at most the measured viewport,
  /// the overflow half at least twice it. viewport and stackFrame must
  /// be present, finite and positive; the calibration filler must be
  /// finite and positive in the overflow half and exactly "absent" in
  /// the fit half (calibration missing exactly when the primary's
  /// trustworthiness is in question is INVALID, never a pass).
  /// contentSize and seq are comparative observations - printed, never
  /// enforced (seq > 1 means only that earlier writes were
  /// overwritten). Every invalid path prints its stage tag with the
  /// raw line or the parsed values where they exist, bounded by the
  /// byte-bounded read, so a failed gate is diagnosable rather than
  /// lost. Anything missing, malformed, stale, extra, pending,
  /// calibration-less or inequality-violating returns false so the
  /// caller fails the test - INVALID, never a fits/overflow finding.
  /// Nothing here asserts the declared 300-point frame.
  private func printGeometryReceipt(from candidates: [URL], expectedCell: String) -> Bool {
    func invalid(_ stage: String, _ detail: String) -> Bool {
      print("scroll-geometry: invalid-\(stage) \(detail)")
      return false
    }
    guard let file = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
      let handle = try? FileHandle(forReadingFrom: file)
    else { return invalid("missing", "(no receipt file)") }
    defer { try? handle.close() }
    let data = handle.readData(ofLength: Self.phasesReadLimit + 1)
    guard data.count <= Self.phasesReadLimit
    else { return invalid("oversized", "(>\(Self.phasesReadLimit) bytes)") }
    guard let text = String(data: data, encoding: .utf8)
    else { return invalid("encoding", "(not utf8)") }
    let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
    // Token grammar, identical semantics to the registered receipt
    // format, validated token by token to stay inside the lint
    // line-length bound: one space-separated key=value field per
    // measurement, in a fixed order, no spaces inside any value.
    let tokens = lines.count == 1 ? lines[0].split(separator: " ") : []
    func field(_ index: Int, _ key: String) -> Substring? {
      guard tokens.indices.contains(index), tokens[index].hasPrefix(key + "=")
      else { return nil }
      return tokens[index].dropFirst(key.count + 1)
    }
    func isDigits(_ value: Substring) -> Bool {
      !value.isEmpty && value.allSatisfy { $0.isNumber }
    }
    func isNumeric(_ value: Substring) -> Bool {
      !value.isEmpty && value.allSatisfy { $0.isNumber || $0 == "." }
    }
    func isPendingOrNumeric(_ value: Substring) -> Bool {
      value == "pending" || isNumeric(value)
    }
    guard tokens.count == 7,
      tokens[0] == "scroll-geometry:",
      let cell = field(1, "cell"),
      !cell.isEmpty && cell.allSatisfy({ $0.isLetter && $0.isLowercase }),
      String(cell) == expectedCell,
      let seqToken = field(2, "seq"), isDigits(seqToken),
      let viewportToken = field(3, "viewport"), isPendingOrNumeric(viewportToken),
      let contentSizeToken = field(4, "contentSize"), isPendingOrNumeric(contentSizeToken),
      let stackFrameToken = field(5, "stackFrame"), isPendingOrNumeric(stackFrameToken),
      let fillerToken = field(6, "filler"),
      isPendingOrNumeric(fillerToken) || fillerToken == "absent"
    else { return invalid("grammar", "(raw: \(text))") }
    guard let seq = Int(seqToken), seq >= 1,
      let viewport = Double(viewportToken),
      let stackFrame = Double(stackFrameToken)
    else { return invalid("pending", "(raw: \(lines[0]))") }
    // Digit-shaped strings can still parse to infinity, and a zero
    // viewport would make the overflow inequality vacuous; require
    // finite, positive measurements explicitly.
    guard viewport.isFinite, stackFrame.isFinite, viewport > 0, stackFrame > 0
    else {
      return invalid("finite", "(viewport=\(viewportToken) stackFrame=\(stackFrameToken))")
    }
    // Calibration presence, fail-closed: the overflow half must carry a
    // finite, positive filler measurement; the fit half exactly
    // "absent".
    if expectedCell == "overflow" {
      guard let filler = Double(fillerToken), filler.isFinite, filler > 0
      else { return invalid("calibration", "(filler=\(fillerToken))") }
    } else if fillerToken != "absent" {
      return invalid("calibration", "(filler=\(fillerToken))")
    }
    // The registered inequality, enforced numerically on the
    // pre-registered primary (stackFrame): the fit half at most the
    // measured viewport, the overflow half at least twice it. Anything
    // else is INVALID, never a fits/overflow finding.
    let inequalityHolds =
      expectedCell == "fit"
      ? stackFrame <= viewport
      : stackFrame >= 2 * viewport
    guard inequalityHolds
    else {
      return invalid(
        "inequality", "(cell=\(expectedCell) viewport=\(viewport) stackFrame=\(stackFrame))")
    }
    print(lines[0])
    return true
  }

  /// c18 hierarchy gate read, fail-closed: the registered scroll-pair
  /// reading requires the COMPLETE dump block, delivered through the
  /// nonce-named file (the app's stdout does not reach the retained CI
  /// job log). The capture fires on a 2-second delay, so the read polls
  /// every 50ms up to a bounded 10s deadline before declaring missing;
  /// a deadline miss, an over-cap file, a mis-encoded file or a block
  /// without both delimiters is INVALID, never an absent-hierarchy
  /// finding; a block whose own summary reports node- or
  /// depth-truncation is equally INVALID - complete means complete,
  /// not capped-and-accepted. The read cap exceeds the block's
  /// structural bound and an over-cap file is rejected whole, never
  /// truncated. On success the complete block is printed to the
  /// test's own stdout, which reaches the retained log.
  private static let dumpReadLimit = 32768

  private func printViewHierarchyDump(from candidates: [URL]) -> Bool {
    func invalid(_ stage: String) -> Bool {
      print("arx-view-dump: invalid-\(stage)")
      return false
    }
    var sawPartial = false
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
      if let file = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
        let handle = try? FileHandle(forReadingFrom: file)
      {
        let data = handle.readData(ofLength: Self.dumpReadLimit + 1)
        try? handle.close()
        guard data.count <= Self.dumpReadLimit else { return invalid("oversized") }
        guard let text = String(data: data, encoding: .utf8) else { return invalid("encoding") }
        guard
          text.hasPrefix("ARX-VIEW-DUMP-v1-BEGIN\n"),
          text.contains("\nARX-VIEW-DUMP-v1-END\n")
        else {
          // A partially visible file mid-poll is not yet terminal;
          // the atomic write makes this unlikely, but keep polling.
          sawPartial = true
          Thread.sleep(forTimeInterval: 0.05)
          continue
        }
        // Complete means complete: the block's own summary line must
        // be present, and a node- or depth-truncated capture is
        // INVALID, never accepted as the complete hierarchy.
        guard
          let summary = text.split(separator: "\n").first(where: {
            $0.hasPrefix("nodes: ")
          })
        else { return invalid("partial") }
        guard !summary.contains("node-truncated: true"),
          !summary.contains("depth-truncated: true")
        else { return invalid("truncated") }
        print(text)
        return true
      }
      Thread.sleep(forTimeInterval: 0.05)
    }
    return invalid(sawPartial ? "partial" : "missing")
  }

  /// Awaited variant for the late-displacement cell (delta 15): polls
  /// for the complete six-line capture every 50ms up to a bounded
  /// 10s deadline, so the audit is sequenced behind validated
  /// displacement evidence. The gate is semantic, not grammar only:
  /// a complete capture is accepted only when phases 0-2 all read
  /// the shared field editor (_SystemTextFieldFieldEditor, matching
  /// the focused origin-field cell) and phases 3-5 all read window
  /// (the persistent displacement). A complete capture with any
  /// other content is INVALID: the invalid-pattern marker prints
  /// together with the raw observed tokens, so the failure carries
  /// its evidence and a wrong-pattern capture can never pass as
  /// validated displacement. A deadline miss prints INVALID once,
  /// never a partial reading. Poll iterations re-read from
  /// empty/missing states silently; only the terminal state prints.
  /// Only the delta-15 cell uses this path.
  private func printResponderPhasesAwaited(from candidates: [URL], expectedLines: Int) {
    let expectedTokens = [
      "_SystemTextFieldFieldEditor", "_SystemTextFieldFieldEditor",
      "_SystemTextFieldFieldEditor", "window", "window", "window",
    ]
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
      if let lines = readResponderPhasesQuietly(from: candidates, expectedLines: expectedLines) {
        let tokens = lines.enumerated().map { index, line in
          String(line.dropFirst("pre-audit-first-responder-\(index): ".count))
        }
        if tokens == expectedTokens {
          for line in lines { print(line) }
        } else {
          print("pre-audit-first-responder: invalid-pattern")
          for (index, token) in tokens.enumerated() {
            print("invalid-pattern-observed-\(index): \(token)")
          }
        }
        return
      }
      Thread.sleep(forTimeInterval: 0.05)
    }
    print("pre-audit-first-responder: invalid-incomplete")
  }

  /// Silent single attempt used by the polling loop: identical bound
  /// and grammar to readResponderPhases, but prints nothing on a
  /// miss so a partially written file mid-poll is not yet INVALID.
  private func readResponderPhasesQuietly(from candidates: [URL], expectedLines: Int) -> [String]? {
    guard let file = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
      let handle = try? FileHandle(forReadingFrom: file)
    else { return nil }
    defer { try? handle.close() }
    let data = handle.readData(ofLength: Self.phasesReadLimit + 1)
    guard data.count <= Self.phasesReadLimit,
      let text = String(data: data, encoding: .utf8)
    else { return nil }
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).dropLast()
    let valid =
      lines.count == expectedLines
      && lines.enumerated().allSatisfy { index, line in
        line.hasPrefix("pre-audit-first-responder-\(index): ")
          && !line.dropFirst("pre-audit-first-responder-\(index): ".count).isEmpty
      }
    return valid ? lines.map(String.init) : nil
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
