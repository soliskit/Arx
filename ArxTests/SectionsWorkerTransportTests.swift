//
//  SectionsWorkerTransportTests.swift
//  Arx
//
//  Created by David Solis on 11/17/26.
//

import Foundation
import Testing

@testable import Arx

// Synthetic children only: scripts and the same app executable in its fixture
// worker mode. No EventKit store, permission state or private provider is
// reachable from any child these tests launch.
@Suite(.serialized)
struct SectionsWorkerTransportTests {
  private static let readFields: [String: String] = [
    "sourceID": "fixture-source",
    "listID": "fixture-list",
    "reminderID": "fixture-item",
    "expectedSection": "Fixture section",
    "scratchConfirmed": "yes",
  ]

  // Every fixture path a test creates is removed by that test's own defer; the
  // explicit reference keeps the box alive until the test body has completed.
  private final class TempArtifacts {
    var paths: [URL] = []
    func removeAll() {
      for path in paths {
        try? FileManager.default.removeItem(at: path)
      }
    }
  }

  private func makeChild(_ body: String, into artifacts: TempArtifacts) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("sections-transport-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    artifacts.paths.append(directory)
    let script = directory.appendingPathComponent("child.sh")
    try ("#!/bin/sh\n" + body + "\n").write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    return script
  }

  private func call(
    _ child: URL, action: String = "labels", fields: [String: String] = [:]
  ) async -> SectionsReply {
    await Task.detached {
      SectionsWorkerTransport.call(executable: child, arguments: [], action: action, fields: fields)
    }.value
  }

  @Test func launchWritesInputAndDecodesReply() async throws {
    let artifacts = TempArtifacts()
    defer { artifacts.removeAll() }
    let child = try makeChild(
      """
      input=$(cat)
      case "$input" in
        *'"action":"labels"'*) ;;
        *) exit 64 ;;
      esac
      printf '%s' '{"state":"labels","reason":"local_selection_only","lists":[]}'
      exit 0
      """, into: artifacts)
    let reply = await call(child)
    #expect(reply.state == "labels")
    #expect(reply.lists?.isEmpty == true)
  }

  @Test func acceptedWorkerStatusesReturnReply() async throws {
    let artifacts = TempArtifacts()
    defer { artifacts.removeAll() }
    for status in [69, 77] {
      let child = try makeChild(
        """
        cat > /dev/null
        printf '%s' '{"state":"unknown","reason":"fixture_no_provider"}'
        exit \(status)
        """, into: artifacts)
      let reply = await call(child, action: "read", fields: Self.readFields)
      #expect(reply.state == "unknown")
      #expect(reply.reason == "fixture_no_provider")
    }
  }

  @Test func unlistedExitStatusIsUnavailable() async throws {
    let artifacts = TempArtifacts()
    defer { artifacts.removeAll() }
    let child = try makeChild(
      """
      cat > /dev/null
      printf '%s' '{"state":"section","reason":"exact_object_candidate","sectionMatched":true}'
      exit 1
      """, into: artifacts)
    let reply = await call(child, action: "read", fields: Self.readFields)
    #expect(reply.state == "unknown")
    #expect(reply.reason == "worker_unavailable")
  }

  @Test func workerDeadlineExitIsReportedAsTimeout() async throws {
    let artifacts = TempArtifacts()
    defer { artifacts.removeAll() }
    let child = try makeChild(
      """
      cat > /dev/null
      exit 124
      """, into: artifacts)
    let reply = await call(child)
    #expect(reply.state == "unknown")
    #expect(reply.reason == "timeout")
  }

  @Test func signalDeathIsUnavailableNotTimeout() async throws {
    let artifacts = TempArtifacts()
    defer { artifacts.removeAll() }
    let child = try makeChild(
      """
      cat > /dev/null
      kill -KILL $$
      """, into: artifacts)
    let reply = await call(child)
    #expect(reply.state == "unknown")
    #expect(reply.reason == "worker_unavailable")
  }

  @Test func malformedOutputIsUnavailable() async throws {
    let artifacts = TempArtifacts()
    defer { artifacts.removeAll() }
    let child = try makeChild(
      """
      cat > /dev/null
      printf '%s' 'not a sections reply'
      exit 0
      """, into: artifacts)
    let reply = await call(child)
    #expect(reply.state == "unknown")
    #expect(reply.reason == "worker_unavailable")
  }

  @Test func oversizedOutputIsUnavailableWithoutReachingTheDeadline() async throws {
    let artifacts = TempArtifacts()
    defer { artifacts.removeAll() }
    let child = try makeChild(
      """
      cat > /dev/null
      dd if=/dev/zero bs=1024 count=20 2>/dev/null | tr '\\0' 'x'
      exit 0
      """, into: artifacts)
    let started = Date()
    let reply = await call(child)
    let elapsed = Date().timeIntervalSince(started)
    // The parent drains while the child runs, so a full pipe never stalls the
    // writer into the deadline; oversize is classified from the byte count.
    #expect(reply.state == "unknown")
    #expect(reply.reason == "worker_unavailable")
    #expect(elapsed < 8)
  }

  @Test func largeValidReplyDecodesAcrossPipeCapacity() async throws {
    let artifacts = TempArtifacts()
    defer { artifacts.removeAll() }
    let child = try makeChild(
      """
      cat > /dev/null
      padding=$(head -c 15000 < /dev/zero | tr '\\0' 'x')
      printf '{"state":"unknown","reason":"%s"}' "$padding"
      exit 0
      """, into: artifacts)
    let reply = await call(child)
    #expect(reply.state == "unknown")
    #expect(reply.reason == String(repeating: "x", count: 15000))
  }

  @Test func nonexistentExecutableIsUnavailable() async throws {
    let missing = FileManager.default.temporaryDirectory
      .appendingPathComponent("sections-transport-missing-" + UUID().uuidString)
    let reply = await call(missing)
    #expect(reply.state == "unknown")
    #expect(reply.reason == "worker_unavailable")
  }

  @Test func childClosingStdinEarlyIsUnavailable() async throws {
    let artifacts = TempArtifacts()
    defer { artifacts.removeAll() }
    let child = try makeChild(
      """
      exit 0
      """, into: artifacts)
    // Whether the input write lands first or meets EPIPE, the exchange refuses.
    let reply = await call(child)
    #expect(reply.state == "unknown")
    #expect(reply.reason == "worker_unavailable")
  }

  @Test func descendantHoldingStdoutEndsAtTheDeadline() async throws {
    let artifacts = TempArtifacts()
    defer { artifacts.removeAll() }
    let child = try makeChild(
      """
      ( exec sleep 15 ) &
      printf '%s' "$!" > "$(dirname "$0")/descendant.pid"
      cat > /dev/null
      printf '%s' '{"state":"labels","reason":"local_selection_only","lists":[]}'
      exit 0
      """, into: artifacts)
    let pidFile = child.deletingLastPathComponent().appendingPathComponent("descendant.pid")
    defer {
      // The fixture owns this descendant: end exactly the recorded PID and
      // confirm it is gone before the test finishes. No other process matches.
      guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
        let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
      else { return }
      kill(pid, SIGKILL)
      var gone = false
      for _ in 0..<80 {
        if kill(pid, 0) != 0, errno == ESRCH {
          gone = true
          break
        }
        Thread.sleep(forTimeInterval: 0.025)
      }
      #expect(gone)
    }
    let started = Date()
    let reply = await call(child)
    let elapsed = Date().timeIntervalSince(started)
    // The child replied and exited, but its descendant keeps stdout open; the
    // parent stops waiting at the same deadline instead of reading forever.
    #expect(reply.state == "unknown")
    #expect(reply.reason == "timeout")
    #expect(elapsed >= 8 && elapsed < 20)
  }

  @Test func parentDeadlineStopsRunawayChild() async throws {
    let artifacts = TempArtifacts()
    defer { artifacts.removeAll() }
    let child = try makeChild(
      """
      exec sleep 60
      """, into: artifacts)
    let started = Date()
    let reply = await call(child)
    let elapsed = Date().timeIntervalSince(started)
    #expect(reply.state == "unknown")
    #expect(reply.reason == "timeout")
    #expect(elapsed >= 8 && elapsed < 20)
  }

  @Test func refusalDoesNotRetryTheChild() async throws {
    let artifacts = TempArtifacts()
    defer { artifacts.removeAll() }
    let countFile = FileManager.default.temporaryDirectory
      .appendingPathComponent("sections-launches-" + UUID().uuidString)
    artifacts.paths.append(countFile)
    let child = try makeChild(
      """
      cat > /dev/null
      printf 'launched\\n' >> '\(countFile.path)'
      exit 1
      """, into: artifacts)
    let reply = await call(child)
    let launches = try String(contentsOf: countFile, encoding: .utf8)
      .split(separator: "\n").count
    #expect(reply.state == "unknown")
    #expect(reply.reason == "worker_unavailable")
    #expect(launches == 1)
  }

  @Test func sameAppFixtureWorkerRefusesBeforeAnyProvider() async throws {
    let app = try #require(Bundle.main.executableURL)
    let reply = await Task.detached {
      SectionsWorkerTransport.call(
        executable: app,
        arguments: ["--sections-local-worker", "--sections-local-fixtures"],
        action: "read",
        fields: SectionsWorkerTransportTests.readFields
      )
    }.value
    #expect(reply.state == "unknown")
    #expect(reply.reason == "fixture_no_provider")
  }
}
