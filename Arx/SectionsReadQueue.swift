//
//  SectionsReadQueue.swift
//  Arx
//
//  Runs the section helper one read at a time. A caller only ever receives a
//  read that started after its own request arrived, so a section move made
//  before the call is never hidden by an older in-flight read, and no result is
//  kept after it is delivered. Callers that arrive while a read for the same
//  list is still waiting share that waiting read. At most one helper runs, and
//  at most one read per list waits. A read that has not started within the
//  start deadline is dropped and its callers get Unknown, so a page never waits
//  longer than that deadline plus one helper run (35 seconds).
//

import Foundation

actor SectionsReadQueue {
  nonisolated struct Key: Hashable, Sendable {
    let sourceID: String
    let listID: String
  }

  /// Seconds a read may wait for its turn before it is dropped.
  nonisolated static let startDeadlineSeconds: UInt64 = 10

  static let shared = SectionsReadQueue()

  private struct Waiter {
    let id: UInt64
    let continuation: CheckedContinuation<SectionsReply, Never>
  }

  private var running = false
  private var order: [Key] = []
  private var waiting: [Key: [Waiter]] = [:]
  private var nextID: UInt64 = 0
  private typealias Check = @Sendable (Bool, Int, Int) -> Bool
  private typealias Observer = (check: Check, done: CheckedContinuation<Void, Never>)
  private var observers: [Observer] = []
  private let startDeadlineNanoseconds: UInt64
  private let perform: @Sendable (Key) async -> SectionsReply

  init(
    startDeadlineSeconds: UInt64 = SectionsReadQueue.startDeadlineSeconds,
    perform: @escaping @Sendable (Key) async -> SectionsReply = { key in
      // 35 seconds covers the helper's own 30-second self-terminating alarm.
      await Task.detached {
        SectionsWorkerTransport.call(
          action: "sections", fields: ["sourceID": key.sourceID, "listID": key.listID],
          budgetSeconds: 35)
      }.value
    }
  ) {
    self.startDeadlineNanoseconds = startDeadlineSeconds * 1_000_000_000
    self.perform = perform
  }

  /// Test seam with a finer deadline than whole seconds.
  init(
    startDeadlineNanoseconds: UInt64, perform: @escaping @Sendable (Key) async -> SectionsReply
  ) {
    self.startDeadlineNanoseconds = startDeadlineNanoseconds
    self.perform = perform
  }

  func read(sourceID: String, listID: String) async -> SectionsReply {
    let key = Key(sourceID: sourceID, listID: listID)
    nextID += 1
    let id = nextID
    let deadline = startDeadlineNanoseconds
    let reply = await withCheckedContinuation { continuation in
      if waiting[key] == nil {
        order.append(key)
        waiting[key] = []
      }
      waiting[key]?.append(Waiter(id: id, continuation: continuation))
      Task {
        try? await Task.sleep(nanoseconds: deadline)
        expire(key, id: id)
      }
      startNext()
      notify()
    }
    return reply
  }

  /// For tests: resumes once the predicate holds for (running, waiting lists,
  /// waiting callers). Event driven, no polling.
  func waitUntil(_ check: @escaping @Sendable (Bool, Int, Int) -> Bool) async {
    if check(running, order.count, waitingCallers) { return }
    await withCheckedContinuation { done in observers.append((check, done)) }
  }

  private var waitingCallers: Int { waiting.values.reduce(0) { $0 + $1.count } }

  private func notify() {
    let snapshot = (running, order.count, waitingCallers)
    var remaining: [Observer] = []
    for observer in observers {
      if observer.check(snapshot.0, snapshot.1, snapshot.2) {
        observer.done.resume()
      } else {
        remaining.append(observer)
      }
    }
    observers = remaining
  }

  // A waiter whose read has not started is dropped with Unknown. A waiter whose
  // read already started is no longer in `waiting` and is left alone.
  private func expire(_ key: Key, id: UInt64) {
    guard var list = waiting[key], let index = list.firstIndex(where: { $0.id == id }) else {
      return
    }
    let waiter = list.remove(at: index)
    if list.isEmpty {
      waiting.removeValue(forKey: key)
      order.removeAll { $0 == key }
    } else {
      waiting[key] = list
    }
    waiter.continuation.resume(returning: SectionsReply(state: "unknown", reason: "read_busy"))
    notify()
  }

  private func startNext() {
    guard !running, !order.isEmpty else { return }
    let key = order.removeFirst()
    let waiters = waiting.removeValue(forKey: key) ?? []
    running = true
    Task {
      let reply = await perform(key)
      finish(waiters, with: reply)
    }
  }

  private func finish(_ waiters: [Waiter], with reply: SectionsReply) {
    for waiter in waiters { waiter.continuation.resume(returning: reply) }
    running = false
    startNext()
    notify()
  }
}
