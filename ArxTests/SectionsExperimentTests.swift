import Testing

@testable import Arx

@MainActor struct SectionsExperimentTests {
  @Test func fixtureDoesNotAuthorizeRealRead() {
    let model = SectionsExperimentModel(fixture: true)
    #expect(model.fixture)
    #expect(!model.canLocate && !model.canRun)
    #expect(model.item == nil && !model.finished)
    #expect(model.message.contains("Fixture"))
  }

  @Test func exactScratchSelectionRequired() {
    let model = SectionsExperimentModel(fixture: true)
    model.scratch = true
    #expect(!model.canLocate)
    model.selectedList = "wrong"
    #expect(!model.canLocate)
    model.selectedList = "fixture-list"
    #expect(model.canLocate)
    model.locate()
    #expect(model.item?.id == "fixture-item")
    #expect(!model.canRun)
    model.confirmed = true
    model.expectedSection = "  "
    #expect(!model.canRun)
    model.expectedSection = "Test section"
    #expect(model.canRun)
  }

  @Test func oneShotResultDoesNotDiscloseSelection() {
    let model = SectionsExperimentModel(fixture: true)
    model.selectedList = "fixture-list"
    model.scratch = true
    model.locate()
    model.confirmed = true
    model.expectedSection = "PRIVATE section text"
    model.run()
    #expect(model.finished)
    #expect(model.lists.isEmpty && model.item == nil)
    #expect(model.report.contains("Section matched: yes"))
    #expect(!model.report.contains("fixture-item"))
    #expect(!model.report.contains("fixture-source"))
    #expect(model.report.contains("Reminder: Disposable Sections check"))
    #expect(model.report.contains("Expected section: PRIVATE section text"))
    #expect(model.report.contains("Test list: Arx Test A"))
    #expect(!model.report.contains("Fixture account"))
    let before = model.report
    model.loadLabels()
    model.locate()
    model.run()
    #expect(model.report == before)
    #expect(model.item == nil)
  }

  @Test func selectionChangeClearsReminderConfirmation() {
    let model = SectionsExperimentModel(fixture: true)
    model.selectedList = "fixture-list"
    model.scratch = true
    model.locate()
    model.confirmed = true
    model.clearSelection()
    #expect(model.item == nil && !model.confirmed && !model.canRun)
  }
  @Test func unknownSelectionStopsWithoutRead() {
    let model = SectionsExperimentModel(
      fixture: true,
      fixtureReplies: [
        "locate": SectionsReply(state: "unknown", reason: "selection_not_exactly_one")
      ])
    model.selectedList = "fixture-list"
    model.scratch = true
    model.locate()
    #expect(model.finished && model.item == nil && !model.canRun)
    #expect(model.report.contains("not established"))
  }

  @Test func mismatchStopsWithoutRetry() {
    let model = SectionsExperimentModel(
      fixture: true,
      fixtureReplies: [
        "read": SectionsReply(
          state: "unknown", reason: "identity_or_membership_unverified", sectionMatched: false)
      ])
    model.selectedList = "fixture-list"
    model.scratch = true
    model.locate()
    model.confirmed = true
    model.expectedSection = "Fixture section"
    model.run()
    #expect(model.finished && !model.canRun && model.item == nil)
    #expect(model.report.contains("not established"))
  }

  @Test func duplicateScratchListNamesRefuseSelection() {
    let model = SectionsExperimentModel(fixture: true)
    model.lists.append(
      SectionsList(
        id: "other-list", sourceID: "other-source", title: "Arx Test A",
        sourceTitle: "Other account"))
    model.selectedList = "fixture-list"
    model.scratch = true
    #expect(!model.canLocate)
    model.locate()
    #expect(model.item == nil)
  }
  @Test func fixedDiagnosticReasonsAndSteps() {
    let reasons = [
      "existing_permission_unavailable", "label_bound_exceeded", "labels_unverified",
      "selection_unavailable", "selection_timeout", "selection_not_exactly_one",
      "identity_unverified", "private_framework_unavailable", "membership_api_unavailable",
      "membership_unverified", "membership_nil_no_error", "membership_none_3009",
      "membership_error", "store_unavailable", "view_init_unavailable",
      "fetch_selector_unavailable", "id_construction_unavailable",
      "membership_section_identity", "membership_unnamed", "section_name_mismatch",
      "private_api_exception", "denied",
      "timeout", "worker_unavailable", "PRIVATE reminder name and ID",
    ]
    for action in ["labels", "locate", "read"] {
      for reason in reasons {
        let model = SectionsExperimentModel(
          fixture: true,
          fixtureReplies: [action: SectionsReply(state: "unknown", reason: reason)])
        model.selectedList = "fixture-list"
        model.scratch = true
        if action == "labels" {
          model.loadLabels()
        } else {
          model.locate()
          if action == "read" {
            model.confirmed = true
            model.expectedSection = "PRIVATE section"
            model.run()
          }
        }
        #expect(model.finished && !model.canRun && model.item == nil && model.lists.isEmpty)
        let step = action == "locate" ? "selection" : action
        #expect(model.report.contains("Step: " + step))
        #expect(
          model.report.contains("Reason: " + SectionsExperimentModel.diagnosticReason(reason)))
        // The unrecognized reason's canary text never crosses into the report.
        // The owner-approved expected section name appears only on a read stop.
        #expect(!model.report.contains("PRIVATE reminder name and ID"))
        #expect(!model.message.contains("PRIVATE"))
        if action == "read" {
          #expect(model.report.contains("Expected section: PRIVATE section"))
        } else {
          #expect(!model.report.contains("PRIVATE"))
        }
        #expect(!model.report.contains("fixture-list") && !model.report.contains("fixture-source"))
        let stopped = model.report
        model.loadLabels()
        model.locate()
        model.run()
        #expect(model.report == stopped)
      }
    }
    #expect(SectionsExperimentModel.diagnosticReason("timeout").contains("read unknown"))
    #expect(SectionsExperimentModel.diagnosticReason("worker_unavailable").contains("read unknown"))
    let splitCodes = [
      "membership_nil_no_error", "membership_none_3009", "membership_error",
      "membership_section_identity", "membership_unnamed", "store_unavailable",
      "view_init_unavailable", "fetch_selector_unavailable", "id_construction_unavailable",
    ]
    let splitPhrases = splitCodes.map { SectionsExperimentModel.diagnosticReason($0) }
    // Each split site has its own mapped phrase, pairwise distinct, never the
    // unrecognized default; the legacy combined reason keeps its own mapping.
    #expect(splitPhrases.allSatisfy { !$0.contains("unrecognized") })
    // The provider-signalled no-section outcome is a confirmed positive,
    // never "unverified"; silent nil keeps its unverified mapping.
    #expect(
      !SectionsExperimentModel.diagnosticReason("membership_none_3009").contains("unverified"))
    #expect(
      SectionsExperimentModel.diagnosticReason("membership_nil_no_error").contains("unverified"))
    #expect(Set(splitPhrases).count == splitPhrases.count)
    #expect(
      !SectionsExperimentModel.diagnosticReason("membership_unverified").contains("unrecognized"))
    #expect(
      SectionsExperimentModel.diagnosticReason("section_name_mismatch")
        != SectionsExperimentModel.diagnosticReason("membership_unverified"))
  }

  @Test func providerReportedNoSectionStateMapsToHedgedStatus() {
    // App-side fixture state coverage: a no_section state with the provider's
    // -3009 signal is a positive outcome, but the status and reason stay
    // provider-reported wording because native semantics are unproved.
    let model = SectionsExperimentModel(
      fixture: true,
      fixtureReplies: ["read": SectionsReply(state: "no_section", reason: "membership_none_3009")])
    model.selectedList = "fixture-list"
    model.scratch = true
    model.locate()
    model.confirmed = true
    model.expectedSection = "PRIVATE section"
    model.run()
    #expect(model.finished && !model.canRun && model.item == nil && model.lists.isEmpty)
    #expect(model.report.contains("Status: provider-reported not in a section"))
    #expect(
      model.report.contains(
        "Reason: " + SectionsExperimentModel.diagnosticReason("membership_none_3009")))
    #expect(!model.report.contains("confirmed") && !model.message.contains("confirmed"))
    #expect(!model.message.contains("PRIVATE"))
    #expect(model.report.contains("Expected section: PRIVATE section"))
    #expect(!model.report.contains("fixture-list") && !model.report.contains("fixture-source"))
  }

  @MainActor @Test func parentDisplayBoundaryReallowlistsWorkerFields() {
    let model = SectionsExperimentModel(
      fixture: true,
      fixtureReplies: [
        "read": SectionsReply(
          state: "unknown", reason: "private_api_exception",
          actualSection: "Forged\nStatus: matched",
          exceptionName: "NSMadeUpException\nReason: forged")
      ])
    model.selectedList = "fixture-list"
    model.scratch = true
    model.locate()
    model.confirmed = true
    model.expectedSection = "Scratch section"
    model.run()
    // The parent allowlists the exception name itself; unrecognized names,
    // including the worker's own "other", never reach the report verbatim.
    #expect(model.report.contains("Exception: unrecognized exception type"))
    // Newline-bearing or oversized returned names are dropped at the boundary.
    #expect(!model.report.contains("Forged") && !model.report.contains("NSMadeUpException"))
    #expect(model.report.contains("Expected section: Scratch section"))
    #expect(model.report.contains("Reason: private API exception"))
  }

  @MainActor @Test func matchedSectionReportShowsApprovedNamesWithCaveat() {
    let model = SectionsExperimentModel(
      fixture: true,
      fixtureReplies: [
        "read": SectionsReply(
          state: "section", reason: "exact_object_candidate", sectionMatched: true,
          expectedSection: "Scratch section", actualSection: "Scratch section")
      ])
    model.selectedList = "fixture-list"
    model.scratch = true
    model.locate()
    model.confirmed = true
    model.expectedSection = "Scratch section"
    model.run()
    #expect(model.report.contains("Status: candidate section matched"))
    #expect(model.report.contains("Returned section: Scratch section (verified in the selected"))
    #expect(model.report.contains("Section matched: yes"))
  }

  @Test func batchSummaryGroupsNamesAndSortsRows() {
    let results = [
      SectionsEntry(
        state: "section", reason: "exact_object_name", reminderID: "b", actualSection: "Bravo"),
      SectionsEntry(
        state: "section", reason: "exact_object_name", reminderID: "a", actualSection: "Alpha"),
      SectionsEntry(
        state: "section", reason: "exact_object_name", reminderID: "c", actualSection: "Alpha"),
      SectionsEntry(
        state: "unknown", reason: "membership_unnamed", reminderID: nil, actualSection: nil),
    ]
    let text = SectionsExperimentModel.batchSummary(
      results: results, listTitle: "Arx Test A",
      reply: SectionsReply(state: "sections", reason: "ok"))
    #expect(text.contains("4 reminders"))
    let lines = text.components(separatedBy: "\n")
    let alpha = lines.firstIndex(of: "Alpha: 2")
    let bravo = lines.firstIndex(of: "Bravo: 1")
    #expect(alpha != nil && bravo != nil && alpha! < bravo!)
    #expect(lines.contains("Unknown: 1"))
    let rows = lines.filter { $0.hasPrefix("a:") || $0.hasPrefix("b:") || $0.hasPrefix("c:") }
    #expect(rows == ["a: section Alpha", "b: section Bravo", "c: section Alpha"])
    #expect(text.contains("unverified reminder: Unknown ("))
  }

  @Test func batchSummaryNeverCountsNoSectionAsAName() {
    let results = [
      SectionsEntry(
        state: "no_section", reason: "membership_none_3009", reminderID: "x", actualSection: nil)
    ]
    let text = SectionsExperimentModel.batchSummary(
      results: results, listTitle: "Arx Test A",
      reply: SectionsReply(state: "sections", reason: "ok"))
    #expect(text.contains("Unknown: 1"))
    #expect(text.contains("x: Unknown (provider-reported no section (-3009))"))
    #expect(!text.contains("No section"))
  }

  @Test func batchSummaryOfEmptyListHasZeroCounts() {
    let text = SectionsExperimentModel.batchSummary(
      results: [], listTitle: "Arx Test A", reply: SectionsReply(state: "sections", reason: "ok"))
    #expect(text.contains("0 reminders"))
    #expect(text.contains("Unknown: 0"))
  }

  @Test func batchSummaryShowsFixedErrorDetailsOnly() {
    let results = [
      SectionsEntry(
        state: "unknown", reason: "membership_error", reminderID: "r1", actualSection: nil,
        errorDomain: "EKErrorDomain", errorCode: 5, exceptionName: "NSInvalidArgumentException"),
      SectionsEntry(
        state: "unknown", reason: "membership_error", reminderID: "r2", actualSection: nil,
        errorDomain: "Forged\nDomain", errorCode: 7, exceptionName: "Made\nUp"),
    ]
    let text = SectionsExperimentModel.batchSummary(
      results: results, listTitle: "Arx Test A",
      reply: SectionsReply(state: "sections", reason: "ok"))
    #expect(text.contains("[EventKit error code 5; NSInvalidArgumentException]"))
    #expect(text.contains("[unrecognized error domain code 7; unrecognized exception type]"))
    #expect(!text.contains("Forged") && !text.contains("Made"))
  }

  @MainActor @Test func stopClearsBatchReportAndNilFetchRefusalIsNamed() {
    let model = SectionsExperimentModel(
      fixture: true,
      fixtureReplies: ["sections": SectionsReply(state: "unknown", reason: "selection_unavailable")]
    )
    model.selectedList = "fixture-list"
    model.scratch = true
    model.batchReport = "old result"
    model.runBatch()
    #expect(model.finished && model.batchReport.isEmpty)
    #expect(model.message.contains("selection unavailable"))
  }

  @MainActor @Test func newBatchReadClearsOldReport() {
    let model = SectionsExperimentModel(fixture: true)
    model.selectedList = "fixture-list"
    model.scratch = true
    model.batchReport = "old result"
    model.runBatch()
    #expect(!model.batchReport.contains("old result"))
    #expect(model.batchReport.contains("2 reminders"))
  }
}
