import Testing

@testable import Arx

@MainActor
struct ArxTests {
  @Test func startsWithFirstListAndNoReminder() {
    let navigation = SampleNavigation()
    #expect(navigation.selectedList?.id == "inbox")
    #expect(navigation.selectedReminder == nil)
  }

  @Test func selectsReminderWithinItsList() {
    var navigation = SampleNavigation()
    navigation.selectReminder("book")
    #expect(navigation.selectedReminder?.title == "Return the library book")
    #expect(navigation.selectedReminder?.notes == "Bring it on the next walk.")
  }

  @Test func switchingListsClearsReminderSelection() {
    var navigation = SampleNavigation()
    navigation.selectReminder("book")
    navigation.selectList("weekend")
    #expect(navigation.selectedList?.id == "weekend")
    #expect(navigation.selectedReminder == nil)
    navigation.selectReminder("walk")
    #expect(navigation.selectedReminder?.id == "walk")
  }

  @Test func cannotSelectReminderFromAnotherList() {
    var navigation = SampleNavigation()
    navigation.selectReminder("walk")
    #expect(navigation.selectedReminder == nil)
  }

  @Test func emptyListHasNoSelectedReminder() {
    var navigation = SampleNavigation()
    navigation.selectReminder("book")
    navigation.selectList("later")
    #expect(navigation.selectedList?.reminders.isEmpty == true)
    #expect(navigation.selectedReminder == nil)
  }

  @Test func invalidOrClearedSelectionsAreSafe() {
    var navigation = SampleNavigation()
    navigation.selectReminder("book")
    navigation.selectList("missing")
    #expect(navigation.selectedList == nil)
    #expect(navigation.selectedReminder == nil)
    navigation.selectList("inbox")
    navigation.selectReminder("missing")
    #expect(navigation.selectedReminder == nil)
    navigation.selectList(nil)
    #expect(navigation.selectedList == nil)
  }

  @Test func reselectingCurrentListKeepsReminderSelection() {
    var navigation = SampleNavigation()
    navigation.selectReminder("book")
    navigation.selectList("inbox")
    #expect(navigation.selectedReminder?.id == "book")
    navigation.selectReminder(nil)
    #expect(navigation.selectedReminder == nil)
  }

  @Test func emptyCollectionHasSafeEmptySelections() {
    var navigation = SampleNavigation(lists: [])
    #expect(navigation.lists.isEmpty)
    #expect(navigation.selectedList == nil)
    navigation.selectList("inbox")
    navigation.selectReminder("book")
    #expect(navigation.selectedList == nil)
    #expect(navigation.selectedReminder == nil)
  }
}

@MainActor struct BridgePanelTests {
  @Test func fixtureLaunchDoesNotRequestRealPermission() {
    let model = BridgeViewModel(fixture: true)
    #expect(model.fixture)
    #expect(model.connected)
    #expect(!model.lists.isEmpty)
    #expect(!model.running)
    #expect(!model.starting)
    #expect(model.clients.isEmpty)
    #expect(model.rights.lists.isEmpty)
    #expect(!model.rights.read && !model.rights.manage && !model.rights.delete)
  }
  @Test func invalidOriginDoesNotStartOrGrantAccess() {
    let model = BridgeViewModel(fixture: true)
    model.origin = "http://not-https.example"
    model.start()
    #expect(!model.running && !model.starting)
    #expect(!model.sharing.running)
    #expect(model.clients.isEmpty)
  }
  @Test func stopClearsSecretsAndClients() throws {
    let model = BridgeViewModel(fixture: true)
    try model.sharing.start()
    model.pair()
    #expect(!model.pairingSecret.isEmpty)
    #expect(model.clients.count == 1)
    model.stop()
    #expect(model.pairingSecret.isEmpty)
    #expect(model.clients.isEmpty)
    #expect(!model.sharing.running)
  }
}
