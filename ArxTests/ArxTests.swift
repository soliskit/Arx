//
//  ArxTests.swift
//  ArxTests
//
//  Created by David Solis on 11/15/26.
//

import AppKit
import BridgeCore
import Foundation
import SwiftUI
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

@MainActor struct BridgeRestartTests {
  private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<100 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(50))
    }
    try #require(condition(), "Fixture listener did not settle")
  }
  @Test func stopWhileStartingBlocksReplacementUntilTaskFinishes() async throws {
    let model = BridgeViewModel(fixture: true)
    model.origin = "https://bridge.example.com"
    model.port = String(Int.random(in: 20000...60000))
    model.start()
    #expect(model.starting)
    model.stop()
    #expect(model.stopping)
    #expect(!model.running && !model.starting && !model.sharing.running)
    model.start()
    #expect(model.stopping && !model.starting && !model.sharing.running)
    // No actor suspension happened between Start/Stop/Start above.
    try await waitUntil { !model.stopping }
    #expect(!model.running && !model.starting)
    model.start()
    do {
      try await waitUntil { model.running || !model.starting }
      try #require(model.running)
    } catch {
      model.stop()
      try? await waitUntil { !model.stopping }
      throw error
    }
    model.stop()
    try await waitUntil { !model.stopping }
  }
  @Test func repeatedRestartRevokesOldCredentialsAndClearsStopping() async throws {
    let model = BridgeViewModel(fixture: true)
    model.origin = "https://bridge.example.com"
    model.port = String(Int.random(in: 20000...60000))
    for _ in 0..<2 {
      model.start()
      do {
        try await waitUntil { model.running || !model.starting }
        try #require(model.running)
        let (_, secret) = try model.sharing.pairClient(label: "Fixture", rights: ClientRights())
        let session = try model.sharing.exchange(secret)
        let (_, unused) = try model.sharing.pairClient(
          label: "Pending fixture", rights: ClientRights())
        model.stop()
        model.stop()
        #expect(model.stopping)
        #expect(!model.sharing.running)
        #expect(model.clients.isEmpty && model.pairingSecret.isEmpty)
        #expect(throws: BridgeFailure.denied) { try model.sharing.sessionState(session.token) }
        model.start()
        #expect(!model.starting && !model.running && model.stopping)
        try await waitUntil { !model.stopping }
        model.start()
        try await waitUntil { model.running || !model.starting }
        try #require(model.running)
        #expect(throws: BridgeFailure.denied) { try model.sharing.sessionState(session.token) }
        #expect(throws: BridgeFailure.denied) { try model.sharing.exchange(unused) }
      } catch {
        model.stop()
        try? await waitUntil { !model.stopping }
        throw error
      }
      model.stop()
      try await waitUntil { !model.stopping }
    }
  }
  @Test func stoppingPanelSnapshot() throws {
    // A frozen fixture state renders the actual view without delaying a live listener.
    let model = BridgeViewModel(fixture: true)
    model.stopping = true
    model.message = "Access revoked. Waiting for the local listener to stop."
    let view = NSHostingView(rootView: ContentView(model: model))
    view.frame = NSRect(x: 0, y: 0, width: 1200, height: 650)
    view.layoutSubtreeIfNeeded()
    let image = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: image)
    let png = try #require(image.representation(using: .png, properties: [:]))
    try png.write(to: URL(fileURLWithPath: "/tmp/arx-restart-stopping.png"))
  }
}
