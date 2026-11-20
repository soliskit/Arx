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
      "membership_unverified", "section_name_mismatch", "private_api_exception", "denied",
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
    #expect(
      SectionsExperimentModel.diagnosticReason("section_name_mismatch")
        != SectionsExperimentModel.diagnosticReason("membership_unverified"))
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

}
