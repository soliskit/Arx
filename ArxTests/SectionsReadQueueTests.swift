//
//  SectionsReadQueueTests.swift
//  ArxTests
//
//  Queue behavior with a stand-in reader. No helper or Reminders data is used.
//  Tests wait on queue state events and a gate, never on sleeps.
//

import BridgeCore
import Foundation
import Testing

@testable import Arx

// Records starts and the highest number of reads in flight at once.
nonisolated final class QueueProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var starts: [String] = []
  private var inFlight = 0
  private var peak = 0

  func begin(_ key: SectionsReadQueue.Key) {
    lock.lock()
    starts.append(key.listID)
    inFlight += 1
    peak = max(peak, inFlight)
    lock.unlock()
  }
  func end() {
    lock.lock()
    inFlight -= 1
    lock.unlock()
  }
  var snapshot: (starts: [String], peak: Int) {
    lock.lock()
    defer { lock.unlock() }
    return (starts, peak)
  }
}

// Holds reads open until the test opens it.
actor QueueGate {
  private var isOpen = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    if isOpen { return }
    await withCheckedContinuation { waiters.append($0) }
  }
  func open() {
    isOpen = true
    for waiter in waiters { waiter.resume() }
    waiters = []
  }
}

struct SectionsReadQueueTests {
  private func makeQueue(
    _ probe: QueueProbe, gate: QueueGate? = nil, deadline: UInt64 = 10_000_000_000
  ) -> SectionsReadQueue {
    SectionsReadQueue(startDeadlineNanoseconds: deadline) { key in
      probe.begin(key)
      if let gate {
        await gate.wait()
      } else {
        await Task.yield()
      }
      probe.end()
      return SectionsReply(state: "sections", reason: key.listID, results: [])
    }
  }

  @Test func readsNeverOverlap() async {
    let probe = QueueProbe()
    let queue = makeQueue(probe)
    await withTaskGroup(of: Void.self) { group in
      for index in 0..<6 {
        group.addTask { _ = await queue.read(sourceID: "s", listID: "list\(index)") }
      }
    }
    #expect(probe.snapshot.starts.count == 6)
    #expect(probe.snapshot.peak == 1)
  }

  @Test func aCallerNeverJoinsAReadThatAlreadyStarted() async {
    let probe = QueueProbe()
    let gate = QueueGate()
    let queue = makeQueue(probe, gate: gate)
    let first = Task { await queue.read(sourceID: "s", listID: "a") }
    await queue.waitUntil { running, _, _ in running }
    // The same list again, after the first read started: it waits for its own read.
    let second = Task { await queue.read(sourceID: "s", listID: "a") }
    await queue.waitUntil { _, lists, callers in lists == 1 && callers == 1 }
    await gate.open()
    _ = await first.value
    _ = await second.value
    #expect(probe.snapshot.starts == ["a", "a"])
    #expect(probe.snapshot.peak == 1)
  }

  @Test func callersForOneWaitingListShareOneRead() async {
    let probe = QueueProbe()
    let gate = QueueGate()
    let queue = makeQueue(probe, gate: gate)
    let first = Task { await queue.read(sourceID: "s", listID: "a") }
    await queue.waitUntil { running, _, _ in running }
    let callers = (0..<3).map { _ in Task { await queue.read(sourceID: "s", listID: "b") } }
    // All three callers are queued behind the running read, in one waiting list.
    await queue.waitUntil { _, lists, count in lists == 1 && count == 3 }
    await gate.open()
    _ = await first.value
    for caller in callers { #expect(await caller.value.reason == "b") }
    #expect(probe.snapshot.starts == ["a", "b"])
  }

  @Test func aReadThatDoesNotStartBeforeItsDeadlineIsDroppedAsBusy() async {
    let probe = QueueProbe()
    let gate = QueueGate()
    let queue = makeQueue(probe, gate: gate, deadline: 20_000_000)
    let first = Task { await queue.read(sourceID: "s", listID: "a") }
    await queue.waitUntil { running, _, _ in running }
    // The running read is held open, so this one cannot start and must expire.
    let late = await queue.read(sourceID: "s", listID: "b")
    #expect(late.state == "unknown")
    #expect(late.reason == "read_busy")
    #expect(SectionsReader.labels(from: late, ids: ["x"])["x"]?.name == nil)
    await queue.waitUntil { _, lists, count in lists == 0 && count == 0 }
    await gate.open()
    let finished = await first.value
    #expect(finished.reason == "a")
    // The dropped read never ran.
    #expect(probe.snapshot.starts == ["a"])
  }
}
