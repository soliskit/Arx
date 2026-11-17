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
    #expect(!model.report.contains("Disposable"))
    #expect(!model.report.contains("PRIVATE"))
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
}
