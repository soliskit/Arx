//
//  EventKitPreservationTests.swift
//  Arx
//
//  Created by David Solis on 11/15/26.
//

import BridgeCore
import EventKit
import Foundation
import Testing

@testable import Arx

@MainActor struct EventKitPreservationTests {
  @Test func notesEditPreservesNativeDateComponents() throws {
    let adapter = EventKitStore()
    // Detached, unsaved object only. No request for access or store fetch.
    let reminder = EKReminder(eventStore: EKEventStore())
    var native = DateComponents()
    native.calendar = Calendar(identifier: .gregorian)
    native.year = 2030
    native.month = 2
    native.day = 3
    native.hour = 10
    native.minute = 20
    native.second = 37
    reminder.startDateComponents = native
    reminder.dueDateComponents = native
    let savedStart = reminder.startDateComponents
    let savedDue = reminder.dueDateComponents
    try #require(savedStart?.second == 37)
    try #require(savedDue?.second == 37)
    var fields = ReminderFields(title: "Fixture")
    fields.start = .init(year: 2030, month: 2, day: 3, hour: 10, minute: 20)
    fields.due = fields.start
    let base = SharedReminder(id: "fixture", listID: "fixture", fields: fields)
    fields.notes = "Only notes changed"
    try adapter.apply(fields, to: reminder, preserving: base)
    #expect(reminder.notes == "Only notes changed")
    #expect(reminder.startDateComponents == savedStart)
    #expect(reminder.dueDateComponents == savedDue)
  }

  @Test func invalidRepeatDoesNotDirtyAnEarlierAlarmChange() throws {
    let adapter = EventKitStore()
    let reminder = EKReminder(eventStore: EKEventStore())
    reminder.title = "Fixture"
    reminder.alarms = [EKAlarm(relativeOffset: -900)]
    var fields = ReminderFields(title: "Fixture")
    fields.alarms = [.init(relativeOffset: -900)]
    let base = SharedReminder(id: "fixture", listID: "fixture", fields: fields)
    fields.alarms = [.init(relativeOffset: -3600)]
    fields.repeats = [.init(frequency: "invalid", interval: 1)]
    #expect(throws: BridgeFailure.invalid) {
      try adapter.apply(fields, to: reminder, preserving: base)
    }
    #expect(reminder.alarms?.first?.relativeOffset == -900)
    fields = base.fields
    fields.notes = "Later valid notes"
    try adapter.apply(fields, to: reminder, preserving: base)
    #expect(reminder.alarms?.first?.relativeOffset == -900)
  }
}
