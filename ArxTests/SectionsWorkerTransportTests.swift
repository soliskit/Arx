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

  @Test func unlistedExitStatusNamesTheCode() async throws {
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
    #expect(reply.reason == "child_exit_1")
  }

  @Test func workerExitStatusesAreNamed() async throws {
    let artifacts = TempArtifacts()
    defer { artifacts.removeAll() }
    for status in [64, 70, 74] {
      let child = try makeChild(
        """
        cat > /dev/null
        exit \(status)
        """, into: artifacts)
      let reply = await call(child)
      #expect(reply.state == "unknown")
      #expect(reply.reason == "child_exit_\(status)")
    }
  }

  @Test func labelsTooLargeRefusalPassesThrough() async throws {
    let artifacts = TempArtifacts()
    defer { artifacts.removeAll() }
    let child = try makeChild(
      """
      cat > /dev/null
      printf '%s' '{"state":"unknown","reason":"labels_too_large"}'
      exit 77
      """, into: artifacts)
    let reply = await call(child)
    #expect(reply.state == "unknown")
    #expect(reply.reason == "labels_too_large")
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

  @Test func signalDeathNamesTheSignalNotTimeout() async throws {
    let artifacts = TempArtifacts()
    defer { artifacts.removeAll() }
    let child = try makeChild(
      """
      cat > /dev/null
      kill -KILL $$
      """, into: artifacts)
    let reply = await call(child)
    #expect(reply.state == "unknown")
    #expect(reply.reason == "child_signaled_9")
  }

  @Test func malformedOutputIsUndecodable() async throws {
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
    #expect(reply.reason == "output_undecodable")
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
    #expect(reply.reason == "output_too_large")
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

  @Test func nonexistentExecutableIsSpawnFailed() async throws {
    let missing = FileManager.default.temporaryDirectory
      .appendingPathComponent("sections-transport-missing-" + UUID().uuidString)
    let reply = await call(missing)
    #expect(reply.state == "unknown")
    #expect(reply.reason == "spawn_failed")
  }

  @Test func childClosingStdinEarlyIsUnavailable() async throws {
    let artifacts = TempArtifacts()
    defer { artifacts.removeAll() }
    let child = try makeChild(
      """
      exit 0
      """, into: artifacts)
    // Whether the input write lands first or meets EPIPE, the exchange refuses
    // and names the leg it actually saw.
    let reply = await call(child)
    #expect(reply.state == "unknown")
    #expect(["write_failed", "output_undecodable"].contains(reply.reason))
  }

  @Test func descendantHoldingStdoutEndsAtTheDeadline() async throws {
    let artifacts = TempArtifacts()
    defer { artifacts.removeAll() }
    let child = try makeChild(
      """
      ( exec sleep 12 ) &
      printf '%s' "$!" > "$(dirname "$0")/descendant.pid"
      cat > /dev/null
      printf '%s' '{"state":"labels","reason":"local_selection_only","lists":[]}'
      exit 0
      """, into: artifacts)
    let pidFile = child.deletingLastPathComponent().appendingPathComponent("descendant.pid")
    let started = Date()
    let reply = await call(child)
    let elapsed = Date().timeIntervalSince(started)
    // The child replied and exited, but its descendant keeps stdout open; the
    // parent stops waiting at the same deadline instead of reading forever.
    #expect(reply.state == "unknown")
    #expect(reply.reason == "timeout")
    #expect(elapsed >= 8 && elapsed < 20)
    // The fixture owns this descendant: it outlives the parent deadline by two
    // seconds and then exits on its own. Verify expiry without ever signalling
    // it, so a reused PID can never catch a blind signal.
    let pidText = try String(contentsOf: pidFile, encoding: .utf8)
    let pid = try #require(Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)))
    var gone = false
    for _ in 0..<200 {
      if kill(pid, 0) != 0, errno == ESRCH {
        gone = true
        break
      }
      try await Task.sleep(for: .milliseconds(25))
    }
    #expect(gone)
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
    #expect(reply.reason == "child_exit_1")
    #expect(launches == 1)
  }

  @MainActor @Test func fixedReasonPhrasesCoverTheNewTokens() {
    #expect(
      SectionsExperimentModel.diagnosticReason("labels_too_large")
        == "label names too large; read unknown")
    #expect(
      SectionsExperimentModel.diagnosticReason("child_exit_70")
        == "worker exited, code 70; read unknown")
    #expect(
      SectionsExperimentModel.diagnosticReason("child_signaled_6")
        == "worker stopped by signal 6; read unknown")
    #expect(
      SectionsExperimentModel.diagnosticReason("child_exit_abc")
        == "unrecognized result; read unknown")
    #expect(
      SectionsExperimentModel.diagnosticReason("child_signaled_")
        == "unrecognized result; read unknown")
    #expect(
      SectionsExperimentModel.diagnosticReason("output_too_large")
        == "reply too large; read unknown")
    #expect(
      SectionsExperimentModel.diagnosticReason("spawn_failed")
        == "worker launch failed; read unknown")
    #expect(
      SectionsExperimentModel.diagnosticReason("worker_unavailable")
        == "worker result unavailable; read unknown")
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

  @Test func markersThenSignalNameTheBoundedInterval() async throws {
    let artifacts = TempArtifacts()
    defer { artifacts.removeAll() }
    let child = try makeChild(
      """
      cat > /dev/null
      printf 'stage=input.read.before\nstage=input.read.after\nstage=permission.check.before\n'
      kill -TRAP $$
      """, into: artifacts)
    let reply = await call(child, action: "read", fields: Self.readFields)
    #expect(reply.state == "unknown")
    #expect(reply.reason == "child_signaled_5")
    #expect(reply.stage == "during permission checking")
  }

  @Test func afterMarkerComposesTheIntervalBetweenOperations() async throws {
    let artifacts = TempArtifacts()
    defer { artifacts.removeAll() }
    let child = try makeChild(
      """
      cat > /dev/null
      printf 'stage=input.read.before\nstage=input.read.after\nstage=permission.check.before\nstage=permission.check.after\n'
      kill -KILL $$
      """, into: artifacts)
    let reply = await call(child, action: "read", fields: Self.readFields)
    #expect(reply.reason == "child_signaled_9")
    #expect(reply.stage == "after permission checking, before EventKit setup")
  }

  @Test func outOfOrderMarkersAreMalformed() async throws {
    let artifacts = TempArtifacts()
    defer { artifacts.removeAll() }
    let child = try makeChild(
      """
      cat > /dev/null
      printf 'stage=input.read.after\nstage=input.read.before\n'
      printf '%s' '{"state":"unknown","reason":"fixture_no_provider"}'
      exit 69
      """, into: artifacts)
    let reply = await call(child, action: "read", fields: Self.readFields)
    #expect(reply.state == "unknown")
    #expect(reply.reason == "output_undecodable")
  }

  @Test func duplicateMarkersAreMalformed() async throws {
    let artifacts = TempArtifacts()
    defer { artifacts.removeAll() }
    let child = try makeChild(
      """
      cat > /dev/null
      printf 'stage=input.read.before\nstage=input.read.before\n'
      printf '%s' '{"state":"unknown","reason":"fixture_no_provider"}'
      exit 69
      """, into: artifacts)
    let reply = await call(child, action: "read", fields: Self.readFields)
    #expect(reply.reason == "output_undecodable")
  }

  @Test func unknownMarkerLineStaysInTheResultAndFailsDecode() async throws {
    let artifacts = TempArtifacts()
    defer { artifacts.removeAll() }
    // A line naming an operation the action never expects is not a marker: it
    // stays in the non-marker rest, which then is not a reply and fails closed.
    let child = try makeChild(
      """
      cat > /dev/null
      printf 'stage=bogus.op.before\n'
      printf '%s' '{"state":"unknown","reason":"fixture_no_provider"}'
      exit 69
      """, into: artifacts)
    let reply = await call(child, action: "read", fields: Self.readFields)
    #expect(reply.reason == "output_undecodable")
  }

  @Test func markerByteOverflowIsOutputTooLarge() async throws {
    let artifacts = TempArtifacts()
    defer { artifacts.removeAll() }
    let child = try makeChild(
      """
      cat > /dev/null
      i=0
      while [ $i -lt 24 ]; do
        printf 'stage=input.read.before\n'
        i=$((i + 1))
      done
      exit 0
      """, into: artifacts)
    let reply = await call(child, action: "read", fields: Self.readFields)
    #expect(reply.state == "unknown")
    #expect(reply.reason == "output_too_large")
  }

  @Test func partialMarkerLineAtSignalIsAbsent() async throws {
    let artifacts = TempArtifacts()
    defer { artifacts.removeAll() }
    let child = try makeChild(
      """
      cat > /dev/null
      printf 'stage=input.read.before\nstage=input.read.after\nstage=perm'
      kill -TRAP $$
      """, into: artifacts)
    let reply = await call(child, action: "read", fields: Self.readFields)
    #expect(reply.reason == "child_signaled_5")
    // Only the complete line counts; the partial tail is missing data.
    #expect(reply.stage == "after input read, before permission checking")
  }

  @Test func markersWithValidReplyStillDecode() async throws {
    let artifacts = TempArtifacts()
    defer { artifacts.removeAll() }
    let child = try makeChild(
      """
      cat > /dev/null
      printf 'stage=input.read.before\nstage=input.read.after\nstage=permission.check.before\nstage=permission.check.after\nstage=store.create.before\nstage=store.create.after\nstage=lists.enumerate.before\nstage=lists.enumerate.after\nstage=labels.validate.before\nstage=labels.validate.after\nstage=reply.encode.before\nstage=reply.encode.after\n'
      printf '%s' '{"state":"labels","reason":"local_selection_only","lists":[]}'
      exit 0
      """, into: artifacts)
    let reply = await call(child)
    #expect(reply.state == "labels")
    #expect(reply.lists?.isEmpty == true)
  }

  @Test func nearMaxReplyWithMarkersDecodes() async throws {
    let artifacts = TempArtifacts()
    defer { artifacts.removeAll() }
    let child = try makeChild(
      """
      cat > /dev/null
      printf 'stage=input.read.before\n'
      padding=$(head -c 16000 < /dev/zero | tr '\0' 'x')
      printf '{"state":"unknown","reason":"%s"}' "$padding"
      exit 0
      """, into: artifacts)
    let reply = await call(child)
    #expect(reply.state == "unknown")
    #expect(reply.reason == String(repeating: "x", count: 16000))
  }

  @Test func nonMarkerBytesOverBoundAreOutputTooLarge() async throws {
    let artifacts = TempArtifacts()
    defer { artifacts.removeAll() }
    // Under the aggregate bound but over the non-marker bound: still refuse.
    let child = try makeChild(
      """
      cat > /dev/null
      printf 'stage=input.read.before\n'
      padding=$(head -c 16400 < /dev/zero | tr '\0' 'x')
      printf '{"state":"unknown","reason":"%s"}' "$padding"
      exit 0
      """, into: artifacts)
    let reply = await call(child)
    #expect(reply.state == "unknown")
    #expect(reply.reason == "output_too_large")
  }

  @MainActor @Test func markerPhrasesAndIdentitySubReasons() {
    #expect(
      SectionsExperimentModel.diagnosticReason("identity_list_unverified")
        == "list identity unverified")
    #expect(
      SectionsExperimentModel.diagnosticReason("identity_source_unverified")
        == "account identity unverified")
    #expect(
      SectionsExperimentModel.diagnosticReason("identity_title_unverified")
        == "title identity unverified")
    #expect(
      SectionsExperimentModel.diagnosticReason(
        "child_signaled_5", stage: "during permission checking")
        == "worker stopped by signal 5 during permission checking; read unknown")
    #expect(
      SectionsExperimentModel.diagnosticReason(
        "timeout", stage: "after input read, before permission checking")
        == "worker timed out after input read, before permission checking; read unknown")
    // Without a validated stage the phrases stay exactly as before.
    #expect(
      SectionsExperimentModel.diagnosticReason("child_signaled_5")
        == "worker stopped by signal 5; read unknown")
    #expect(
      SectionsExperimentModel.diagnosticReason("timeout")
        == "worker timed out; read unknown")
  }
}
