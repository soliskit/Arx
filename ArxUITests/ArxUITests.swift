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

  /// Shared body of the minimal-fixture control runs: relaunch into the
  /// minimal fixture with the given extra arguments, record the pre-audit
  /// state observations and a window render (evidence for interpreting any
  /// contrast finding against actual pixels, mirroring the full-app
  /// audit's capture), then run the SAME strict audit handler as the
  /// full-app audit and assert on its collected issues. Observations are
  /// never assertions.
  private func runMinimalFixtureAudit(
    extraArguments: [String], artifactName: String,
    expectedPhaseLines: Int = 3, awaitCompletePhases: Bool = false
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
    app.launchEnvironment = ["ARX_RESPONDER_PHASES_NONCE": nonce]
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
    defer { for file in phasesFileCandidates { try? FileManager.default.removeItem(at: file) } }
    XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
    let application = app!

    print("pre-audit-app-state: \(application.state.rawValue)")
    print("pre-audit-window-enabled: \(application.windows["main"].isEnabled)")
    // Additive observation (delta 8): record the actual window frame per
    // cell, because the no-scroll family demonstrated that geometry
    // varies with content. Observation only, never an assertion.
    print("pre-audit-window-frame: \(application.windows["main"].frame)")
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
