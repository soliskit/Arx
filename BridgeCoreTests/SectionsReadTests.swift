//
//  SectionsReadTests.swift
//  Arx
//
//  Created by David Solis on 11/27/26.
//

import Foundation
import Testing

@testable import BridgeCore

@MainActor struct SectionsReadTests {
  func setup(lists: Set<String> = ["inbox"]) throws -> (FixtureStore, SharingController, String) {
    let store = FixtureStore()
    let controller = SharingController(store: store)
    try controller.start()
    var rights = ClientRights()
    rights.lists = lists
    rights.read = true
    let (_, secret) = try controller.pairClient(label: "Section reader", rights: rights)
    let session = try controller.exchange(secret)
    return (store, controller, session.token)
  }

  @Test func namedAndUnknownLabelsTravelWithThePage() async throws {
    let (store, controller, token) = try setup()
    store.rows["a"] = .init(id: "a", listID: "inbox", fields: .init(title: "A"))
    store.rows["b"] = .init(id: "b", listID: "inbox", fields: .init(title: "B"))
    store.sectionLabelsByID = [
      "book": .named("Alpha"),
      "a": .unknown("provider reported no section"),
    ]
    let page = try await controller.read(token, list: "inbox")
    #expect(Set(page.items.map(\.id)) == ["book", "a", "b"])
    #expect(page.sections["book"] == .named("Alpha"))
    #expect(page.sections["a"] == .unknown("provider reported no section"))
    // A reminder with no label from the store is Unknown, never an empty answer.
    #expect(page.sections["b"] == .unavailable)
    #expect(page.sections.count == page.items.count)
  }

  @Test func aStoreWithoutSectionReadingAnswersUnknownForEveryReminder() async throws {
    let (_, controller, token) = try setup()
    let page = try await controller.read(token, list: "inbox")
    #expect(!page.items.isEmpty)
    for item in page.items { #expect(page.sections[item.id] == .unavailable) }
    #expect(SectionLabel.unavailable.name == nil)
    #expect(SectionLabel.unavailable.unknownReason != nil)
  }

  @Test func labelsOnlyDescribeRemindersOnTheReturnedPage() async throws {
    let (store, controller, token) = try setup()
    store.sectionLabelsByID = ["book": .named("Alpha"), "walk": .named("Bravo")]
    let page = try await controller.read(token, list: "inbox")
    // "walk" belongs to another list, so its label never leaks into this page.
    #expect(page.sections.keys.sorted() == ["book"])
  }

  @Test func listsOverTheReadLimitAreUnknownWithoutStartingARead() async throws {
    let (store, controller, token) = try setup()
    for index in 0..<ReminderPage.sectionReadLimit {
      let id = String(format: "r-%03d", index)
      store.rows[id] = .init(id: id, listID: "inbox", fields: .init(title: id))
    }
    // "book" plus the added rows is one over the limit.
    store.sectionLabelsByID["book"] = .named("Alpha")
    let page = try await controller.read(token, list: "inbox")
    #expect(page.items.count == 100)
    #expect(store.sectionReadCount == 0)
    #expect(page.sections.count == page.items.count)
    #expect(page.sections.values.allSatisfy { $0.name == nil && $0.unknownReason != nil })
  }

  @Test func aListAtTheLimitIsStillRead() async throws {
    let (store, controller, token) = try setup()
    for index in 0..<(ReminderPage.sectionReadLimit - 1) {
      let id = String(format: "r-%03d", index)
      store.rows[id] = .init(id: id, listID: "inbox", fields: .init(title: id))
    }
    _ = try await controller.read(token, list: "inbox")
    #expect(store.sectionReadCount == 1)
  }

  @Test func wireShapeIsNameOrReasonAndPageDecodes() async throws {
    let (store, controller, token) = try setup()
    store.sectionLabelsByID = ["book": .named("Alpha")]
    let page = try await controller.read(token, list: "inbox")
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let data = try encoder.encode(page)
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let sections = try #require(object["sections"] as? [String: [String: Any]])
    #expect(sections["book"]?["name"] as? String == "Alpha")
    #expect(sections["book"]?["unknownReason"] == nil)
    let decoded = try JSONDecoder().decode(ReminderPage.self, from: data)
    #expect(decoded.sections["book"] == .named("Alpha"))
  }

  @Test func sectionReadingAddsNoWritePath() throws {
    // Edit bases and mutation bodies carry no section data.
    let item = SharedReminder(id: "x", listID: "inbox", fields: .init(title: "X"))
    let itemJSON = String(decoding: try JSONEncoder().encode(item), as: UTF8.self)
    #expect(!itemJSON.localizedCaseInsensitiveContains("section"))
    let mutation = Mutation(
      action: .edit, listID: "inbox", itemID: "x", base: item, fields: item.fields)
    let mutationJSON = String(decoding: try JSONEncoder().encode(mutation), as: UTF8.self)
    #expect(!mutationJSON.localizedCaseInsensitiveContains("section"))
    // The only actions are the existing six; none moves a reminder between sections.
    let actions: Set<String> = ["create", "edit", "move", "complete", "reopen", "delete"]
    for action in actions { #expect(Mutation.Action(rawValue: action) != nil) }
    #expect(Mutation.Action(rawValue: "section") == nil)
  }
}
