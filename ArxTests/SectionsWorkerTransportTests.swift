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

  // One crash point per marker position of every action, plus the zero-marker
  // case. Marker input comes from the production sequence table; every
  // expected interval phrase below is hardcoded so the wording itself is
  // tested, not rederived. The type is file-internal (not private) because it
  // appears in the signature of the parametrized test below.
  struct CrashPoint: Sendable, CustomTestStringConvertible {
    var action: String
    var markerCount: Int
    var expectedStage: String
    var testDescription: String { "\(action) death after \(markerCount) markers" }

    static let phrases: [String: [String]] = [
      "labels": [
        "during input read",
        "after input read, before permission checking",
        "during permission checking",
        "after permission checking, before EventKit setup",
        "during EventKit setup",
        "after EventKit setup, before list enumeration",
        "during list enumeration",
        "after list enumeration, before label checking",
        "during label checking",
        "after label checking, before report encoding",
        "during report encoding",
        "after report encoding",
      ],
      "locate": [
        "during input read",
        "after input read, before permission checking",
        "during permission checking",
        "after permission checking, before EventKit setup",
        "during EventKit setup",
        "after EventKit setup, before list binding",
        "during list binding",
        "after list binding, before query setup",
        "during query setup",
        "after query setup, before reminder lookup",
        "during reminder lookup",
        "after reminder lookup, before reminder check",
        "during reminder check",
        "after reminder check, before report encoding",
        "during report encoding",
        "after report encoding",
      ],
      "read": [
        "during input read",
        "after input read, before permission checking",
        "during permission checking",
        "after permission checking, before EventKit setup",
        "during EventKit setup",
        "after EventKit setup, before list binding",
        "during list binding",
        "after list binding, before framework loading",
        "during framework loading",
        "after framework loading, before object selection",
        "during object selection",
        "after object selection, before section lookup",
        "during section lookup",
        "after section lookup, before report encoding",
        "during report encoding",
        "after report encoding",
      ],
    ]

    static let all: [CrashPoint] = phrases.flatMap { action, expected in
      let sequence = (SectionsWorkerTransport.expectedStages[action] ?? []).flatMap {
        [$0 + ".before", $0 + ".after"]
      }
      precondition(
        sequence.count == expected.count,
        "hardcoded phrases must cover every marker position of \(action)")
      return [
        CrashPoint(
          action: action, markerCount: 0,
          expectedStage: SectionsWorkerTransport.noMarkerStage)
      ]
        + expected.indices.map { index in
          CrashPoint(action: action, markerCount: index + 1, expectedStage: expected[index])
        }
    }

    var script: String {
      guard markerCount > 0 else { return "cat > /dev/null\nkill -TRAP $$" }
      let sequence = (SectionsWorkerTransport.expectedStages[action] ?? []).flatMap {
        [$0 + ".before", $0 + ".after"]
      }
      let printed = sequence.prefix(markerCount).map { "stage=" + $0 + "\\n" }.joined()
      return "cat > /dev/null\nprintf '" + printed + "'\nkill -TRAP $$"
    }
  }

  @Test(arguments: CrashPoint.all) func deathAfterEveryMarkerPointNamesTheInterval(
    point: CrashPoint
  ) async throws {
    let artifacts = TempArtifacts()
    defer { artifacts.removeAll() }
    let child = try makeChild(point.script, into: artifacts)
    let reply = await call(child, action: point.action, fields: Self.readFields)
    #expect(reply.state == "unknown")
    #expect(reply.reason == "child_signaled_5")
    #expect(reply.stage == point.expectedStage)
  }

  @Test func decodedStageFromTheStreamIsAlwaysCleared() async throws {
    let artifacts = TempArtifacts()
    defer { artifacts.removeAll() }
    let child = try makeChild(
      """
      cat > /dev/null
      printf 'stage=input.read.before\n'
      printf '%s' '{"state":"unknown","reason":"timeout","stage":"during FORGED injection"}'
      exit 69
      """, into: artifacts)
    let reply = await call(child, action: "read", fields: Self.readFields)
    #expect(reply.reason == "timeout")
    // The stream's own stage claim never survives decoding.
    #expect(reply.stage == nil)
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

  @Test func undecodableJSONReportsClosedTransportFacts() async throws {
    let artifacts = TempArtifacts()
    defer { artifacts.removeAll() }
    let child = try makeChild(
      """
      cat > /dev/null
      printf 'stage=input.read.before\nstage=input.read.after\n'
      printf '%s' 'PRIVATE not json'
      exit 69
      """, into: artifacts)
    let reply = await call(child, action: "read", fields: Self.readFields)
    #expect(reply.reason == "output_undecodable")
    let transport = try #require(reply.transport)
    #expect(transport.hasPrefix("path=json; bytes=63; body=16; exit=69; starts_with_brace=no"))
    #expect(transport.contains("stage=after input read, before permission checking"))
    #expect(!transport.contains("PRIVATE"))
  }

  @Test func malformedMarkersReportClosedTransportFacts() async throws {
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
    #expect(reply.reason == "output_undecodable")
    let transport = try #require(reply.transport)
    #expect(transport.hasPrefix("path=markers; bytes="))
    #expect(!transport.contains("fixture_no_provider"))
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
      padding=$(head -c 16000 < /dev/zero | tr '\\0' 'x')
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
      padding=$(head -c 16400 < /dev/zero | tr '\\0' 'x')
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
    // Zero validated markers is stated as its own closed ambiguity.
    #expect(
      SectionsExperimentModel.diagnosticReason(
        "timeout", stage: SectionsWorkerTransport.noMarkerStage)
        == "worker timed out no stage marker received (checkpoint not reached or output lost); read unknown"
    )
  }

  @Test func nonceEchoBindsOnlyTheExpectedRequest() async throws {
    let artifacts = TempArtifacts()
    defer { artifacts.removeAll() }
    let nonce = "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"
    let child = try makeChild(
      """
      cat >/dev/null
      printf '%s' '{"state":"unknown","reason":"fixture_no_provider","requestNonce":"\(nonce)","requestBound":false}'
      exit 69
      """, into: artifacts)
    let reply = await Task.detached {
      SectionsWorkerTransport.call(
        executable: child, arguments: [], action: "labels", fields: [:], expectedNonce: nonce)
    }.value
    #expect(reply.requestBound == true)
    #expect(reply.requestNonce == nil)
  }

  @Test func missingOrDifferentNonceCannotClaimBinding() async throws {
    let artifacts = TempArtifacts()
    defer { artifacts.removeAll() }
    let nonce = "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"
    for echo in ["", ",\"requestNonce\":\"11111111-2222-4333-8444-555555555555\""] {
      let child = try makeChild(
        """
        cat >/dev/null
        printf '%s' '{"state":"section","reason":"exact_object_candidate","sectionMatched":true,"requestBound":true\(echo)}'
        exit 0
        """, into: artifacts)
      let reply = await Task.detached {
        SectionsWorkerTransport.call(
          executable: child, arguments: [], action: "labels", fields: [:], expectedNonce: nonce)
      }.value
      #expect(reply.state == "unknown")
      #expect(reply.reason == "request_binding_unverified")
      #expect(reply.sectionMatched != true)
      #expect(reply.requestBound != true)
    }
  }

  @Test func compiledStampEchoMustMatchBothParentFields() async throws {
    let artifacts = TempArtifacts()
    defer { artifacts.removeAll() }
    let nonce = "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"
    let revision = String(repeating: "a", count: 40)
    let manifest = String(repeating: "b", count: 64)
    for mode in ["match", "revision", "manifest", "missing"] {
      let wrong = mode != "match"
      let observed = mode == "revision" ? String(repeating: "c", count: 40) : revision
      let observedManifest = mode == "manifest" ? String(repeating: "d", count: 64) : manifest
      let stampFields =
        mode == "missing"
        ? ""
        : ",\"sourceRevision\":\"\(observed)\",\"sourceManifest\":\"\(observedManifest)\""
      let child = try makeChild(
        """
        cat >/dev/null
        printf '%s' '{"state":"unknown","reason":"fixture_no_provider","requestNonce":"\(nonce)","buildBound":true\(stampFields)}'
        exit 69
        """, into: artifacts)
      let reply = await Task.detached {
        SectionsWorkerTransport.call(
          executable: child, arguments: [], action: "labels", fields: [:],
          expectedNonce: nonce, expectedRevision: revision, expectedManifest: manifest)
      }.value
      #expect(reply.buildBound == (wrong ? nil : true))
      #expect(reply.sourceRevision == nil)
      #expect(reply.sourceManifest == nil)
      if wrong { #expect(reply.reason == "build_binding_unverified") }
    }
  }

  @Test func helperDigestRefusesExpiredBudgetAndSymlink() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("sections-hash-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("helper")
    try Data("abc".utf8).write(to: file)
    let deadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
    let digest = try SectionsBuildAttribution.helperDigest(file, deadline: deadline)
    #expect(digest == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    #expect(throws: (any Error).self) {
      _ = try SectionsBuildAttribution.helperDigest(file, deadline: 0)
    }
    let oversized = directory.appendingPathComponent("oversized")
    FileManager.default.createFile(atPath: oversized.path, contents: nil)
    let handle = try FileHandle(forWritingTo: oversized)
    try handle.truncate(atOffset: 16 * 1024 * 1024 + 1)
    try handle.close()
    #expect(throws: (any Error).self) {
      _ = try SectionsBuildAttribution.helperDigest(oversized, deadline: deadline)
    }
    let link = directory.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
    #expect(throws: (any Error).self) {
      _ = try SectionsBuildAttribution.helperDigest(link, deadline: deadline)
    }
  }

  @Test func ordinaryAndUnstampedContextsUseTheRealNonceOnlyAssembly() async throws {
    let artifacts = TempArtifacts()
    defer { artifacts.removeAll() }
    let child = try makeChild(
      """
      /usr/bin/python3 -c 'import json,sys; r=json.load(sys.stdin); print(json.dumps({"state":"unknown","reason":"fixture_no_provider","requestNonce":r["requestNonce"],"buildBound":True}))'
      exit 69
      """, into: artifacts)
    let link = child.deletingLastPathComponent().appendingPathComponent("helper-link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: child)
    for enabled in [false, true] {
      let reply = await Task.detached {
        SectionsWorkerTransport.callWithBuildContext(
          executable: link, action: "labels", fields: [:],
          attributionEnabled: enabled, revision: "", manifest: "")
      }.value
      // An accidentally imposed helper-hash admission would refuse this symlink.
      #expect(reply.reason == "fixture_no_provider")
      #expect(reply.requestBound == true)
      #expect(reply.requestNonce != nil)
      #expect(reply.buildBound == nil)
      #expect(reply.sourceRevision == nil)
      #expect(reply.sourceManifest == nil)
      #expect(reply.helperFileSHA256 == nil)
    }
  }

  @Test func attributedAssemblyDetectsChangedHelperFile() async throws {
    let artifacts = TempArtifacts()
    defer { artifacts.removeAll() }
    let revision = String(repeating: "a", count: 40)
    let manifest = String(repeating: "b", count: 64)
    for mutate in [false, true] {
      let mutation = mutate ? "printf '#changed\\n' >> \"$0\"" : ":"
      let child = try makeChild(
        """
        \(mutation)
        /usr/bin/python3 -c 'import json,sys; r=json.load(sys.stdin); print(json.dumps({"state":"unknown","reason":"fixture_no_provider","requestNonce":r["requestNonce"],"sourceRevision":"\(revision)","sourceManifest":"\(manifest)"}))'
        exit 69
        """, into: artifacts)
      let reply = await Task.detached {
        SectionsWorkerTransport.callWithBuildContext(
          executable: child, action: "labels", fields: [:],
          attributionEnabled: true, revision: revision, manifest: manifest)
      }.value
      if mutate {
        #expect(reply.reason == "helper_identity_unverified")
        #expect(reply.buildBound != true)
        #expect(reply.helperFileSHA256 == nil)
      } else {
        #expect(reply.reason == "fixture_no_provider")
        #expect(reply.buildBound == true)
        #expect(reply.helperFileSHA256?.count == 64)
      }
      #expect(reply.sourceRevision == revision)
      #expect(reply.sourceManifest == manifest)
    }
  }

  // The batch worker's per-reminder reader emits four inner markers inside the
  // sections.read window; a stream may lose lines or repeat a cycle. These fixtures
  // reproduce that exact shape (the real
  // native failure was 13 outer lines, 355 bytes, then objects.bind.before).
  private static let sectionsOuterPrefix =
    [
      "input.read", "permission.check", "store.create", "calendar.bind", "sections.enumerate",
      "framework.load",
    ].flatMap { ["stage=\($0).before\n", "stage=\($0).after\n"] }
    + ["stage=sections.read.before\n"]
  private static let sectionsInner =
    [
      "stage=objects.bind.before\n", "stage=objects.bind.after\n",
      "stage=membership.call.before\n", "stage=membership.call.after\n",
    ]

  private static func sectionsOutput(
    reminders: Int, inner: [String]? = nil, closing: Bool = true, body: String = "{}"
  ) -> Data {
    var text = sectionsOuterPrefix.joined()
    for _ in 0..<reminders { text += (inner ?? sectionsInner).joined() }
    if closing {
      text += "stage=sections.read.after\nstage=reply.encode.before\nstage=reply.encode.after\n"
    }
    return Data((text + body).utf8)
  }

  @Test func sectionsMarkerPrefixMatchesTheRealFailureShape() {
    #expect(Self.sectionsOuterPrefix.joined().utf8.count == 355)
    #expect(Self.sectionsInner.joined().utf8.count == 108)
  }

  @Test func sectionsInnerMarkersAreAcceptedForOneTwoAndTwoHundredReminders() {
    for count in [0, 1, 2, 3, 200] {
      let split = SectionsWorkerTransport.splitMarkers(
        Self.sectionsOutput(reminders: count), action: "sections")
      #expect(!split.malformed)
      #expect(!split.overflow)
      #expect(String(data: split.rest, encoding: .utf8) == "{}")
    }
  }

  @Test func sectionsInnerMarkersStayWithinTheirWindowAndBound() {
    // Two hundred and one reminders exceed the worker's own bound.
    #expect(
      SectionsWorkerTransport.splitMarkers(
        Self.sectionsOutput(reminders: 201), action: "sections"
      ).malformed)
    // A reversed stream is the minimum-cycle reading (four cycles), not malformed.
    let reversed = Array(Self.sectionsInner.reversed())
    #expect(
      !SectionsWorkerTransport.splitMarkers(
        Self.sectionsOutput(reminders: 1, inner: reversed), action: "sections"
      ).malformed)
    // After the window has closed.
    var late = Self.sectionsOutput(reminders: 0, body: "")
    late.append(Data((Self.sectionsInner.joined() + "{}").utf8))
    #expect(SectionsWorkerTransport.splitMarkers(late, action: "sections").malformed)
  }

  @Test func innerSectionsMarkersAreNotAcceptedForOtherActions() {
    for action in ["labels", "locate"] {
      let split = SectionsWorkerTransport.splitMarkers(
        Data("stage=input.read.before\nstage=objects.bind.before\n{}".utf8), action: action)
      #expect(String(data: split.rest, encoding: .utf8)?.hasPrefix("stage=objects") == true)
    }
  }

  @Test func otherActionsKeepTheOriginalMarkerCap() {
    #expect(SectionsWorkerTransport.markerCap(for: "labels") == 512)
    #expect(SectionsWorkerTransport.markerCap(for: "read") == 512)
    #expect(SectionsWorkerTransport.markerCap(for: "sections") == 24_576)
    let overflow = Data(String(repeating: "stage=input.read.before\n", count: 30).utf8)
    #expect(SectionsWorkerTransport.splitMarkers(overflow, action: "labels").overflow)
  }

  @Test func batchReplyWithInnerReaderMarkersDecodesEndToEnd() async throws {
    let artifacts = TempArtifacts()
    defer { artifacts.removeAll() }
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("sections-inner-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    artifacts.paths.append(directory)
    let markerFile = directory.appendingPathComponent("markers.txt")
    try Self.sectionsOutput(reminders: 3, body: "").write(to: markerFile)
    let child = try makeChild(
      """
      cat > /dev/null
      cat '\(markerFile.path)'
      printf '%s' '{"state":"unknown","reason":"fixture_no_provider"}'
      exit 69
      """, into: artifacts)
    let reply = await call(child, action: "sections", fields: [:])
    #expect(reply.reason == "fixture_no_provider")
    #expect(reply.reason != "output_undecodable")
  }

  @Test func innerMarkersAfterTheReplyAreUndecodable() async throws {
    let artifacts = TempArtifacts()
    defer { artifacts.removeAll() }
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("sections-noise-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    artifacts.paths.append(directory)
    let markerFile = directory.appendingPathComponent("markers.txt")
    try Self.sectionsOutput(reminders: 0, body: "").write(to: markerFile)
    let child = try makeChild(
      """
      cat > /dev/null
      cat '\(markerFile.path)'
      printf '%s' '{"state":"unknown","reason":"fixture_no_provider"}'
      printf 'stage=objects.bind.before\n'
      exit 69
      """, into: artifacts)
    let reply = await call(child, action: "sections", fields: [:])
    #expect(reply.reason == "output_undecodable")
  }

  // Flexible marker builder for window cases. `outer` marker groups are named
  // so a case can drop one (a lost marker) without touching the others.
  private static func sectionsLines(
    readBefore: Bool = true, inner: [String], readAfter: Bool = true,
    encode: Bool = true, afterEncode: [String] = [], body: String = "{}"
  ) -> Data {
    var text = Self.sectionsOuterPrefix.dropLast().joined()
    if readBefore { text += "stage=sections.read.before\n" }
    text += inner.joined()
    if readAfter { text += "stage=sections.read.after\n" }
    if encode { text += "stage=reply.encode.before\nstage=reply.encode.after\n" }
    text += afterEncode.joined()
    return Data((text + body).utf8)
  }

  private func isMalformed(_ data: Data) -> Bool {
    SectionsWorkerTransport.splitMarkers(data, action: "sections").malformed
  }

  @Test func partialReaderCyclesRestartAndMixWithFullAndEmptyRows() {
    let bind = Self.sectionsInner
    let full = bind
    let cases: [[String]] = [
      [bind[0]] + full,
      [bind[0], bind[1], bind[2]] + full,
      [bind[0]] + full + [bind[0], bind[1], bind[2]] + full,
      full + full + [bind[0]],
    ]
    for lines in cases {
      let split = SectionsWorkerTransport.splitMarkers(
        Self.sectionsLines(inner: lines), action: "sections")
      #expect(!split.malformed)
      #expect(!split.overflow)
    }
    // A row with no reader markers at all (identity unverified) is just absent.
    #expect(!isMalformed(Self.sectionsLines(inner: full + full)))
  }

  @Test func duplicateAndBackwardReaderMarkersAreCountedAsCyclesAndBounded() {
    // A stream cannot tell a duplicate or backward line from the next reminder's
    // cycle with lost lines, so each is the minimum cycle reading, bounded at 200.
    let bind = Self.sectionsInner
    #expect(!isMalformed(Self.sectionsLines(inner: [bind[0], bind[1], bind[1]])))
    #expect(!isMalformed(Self.sectionsLines(inner: [bind[2], bind[1]])))
    #expect(!isMalformed(Self.sectionsLines(inner: [bind[0], bind[2], bind[1]])))
    let duplicates = { (count: Int) in Array(repeating: bind[1], count: count) }
    #expect(!isMalformed(Self.sectionsLines(inner: duplicates(200))))
    #expect(isMalformed(Self.sectionsLines(inner: duplicates(201))))
  }

  @Test func readerMarkersAfterReplyEncodeAreMalformedEvenWithoutReadAfter() {
    // sections.read.after lost: the later outer reply.encode lines close the window.
    #expect(
      isMalformed(
        Self.sectionsLines(
          inner: Self.sectionsInner, readAfter: false, afterEncode: [Self.sectionsInner[0]],
          body: "")))
    // And with read.after present.
    #expect(
      isMalformed(
        Self.sectionsLines(inner: [], afterEncode: [Self.sectionsInner[0]], body: "")))
  }

  @Test func lostOuterMarkersStillAcceptReaderMarkersBeforeLaterOuterProgress() {
    #expect(!isMalformed(Self.sectionsLines(readBefore: false, inner: Self.sectionsInner)))
    #expect(
      !isMalformed(
        Self.sectionsLines(inner: Self.sectionsInner, readAfter: false, encode: false)))
    #expect(
      !isMalformed(
        Self.sectionsLines(
          readBefore: false, inner: Self.sectionsInner, readAfter: false, encode: false)))
    // Reader lines with no outer marker before them (all lost) are not rejected by position.
    let bare = Data((Self.sectionsInner.joined() + "{}").utf8)
    #expect(!SectionsWorkerTransport.splitMarkers(bare, action: "sections").malformed)
  }

  @Test func readerLinesAdvanceTheOuterCursor() {
    let outer = Self.sectionsOuterPrefix.dropLast().joined()
    let inner = Self.sectionsInner[0]
    // Reader line, then an earlier outer marker: malformed.
    #expect(isMalformed(Data((outer + inner + "stage=framework.load.after\n{}").utf8)))
    #expect(isMalformed(Data((outer + inner + "stage=sections.enumerate.after\n{}").utf8)))
    // Earlier outer, reader, another earlier outer: malformed.
    #expect(
      isMalformed(
        Data(("stage=input.read.before\n" + inner + "stage=permission.check.before\n{}").utf8)))
    // Bare reader lines, then read.after and encode: accepted.
    #expect(
      !isMalformed(
        Data(
          (inner
            + "stage=sections.read.after\nstage=reply.encode.before\nstage=reply.encode.after\n{}")
            .utf8)))
    #expect(
      !isMalformed(
        Data((inner + "stage=reply.encode.before\nstage=reply.encode.after\n{}").utf8)))
  }

  @Test func exactTwoHundredAreAcceptedAndMarkerCapOverflowsFirst() {
    #expect(!isMalformed(Self.sectionsOutput(reminders: 200)))
    #expect(isMalformed(Self.sectionsOutput(reminders: 201)))
    let capped = SectionsWorkerTransport.splitMarkers(
      Self.sectionsOutput(reminders: 230), action: "sections")
    #expect(capped.overflow)
  }

  @Test func transportBodyBoundaryAtTwoHundredReminders() async throws {
    for (size, tooLarge) in [(65_536, false), (65_537, true)] {
      let artifacts = TempArtifacts()
      defer { artifacts.removeAll() }
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("sections-boundary-" + UUID().uuidString)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      artifacts.paths.append(directory)
      let markerFile = directory.appendingPathComponent("markers.txt")
      try Self.sectionsOutput(reminders: 200, body: "").write(to: markerFile)
      let child = try makeChild(
        """
        cat > /dev/null
        cat '\(markerFile.path)'
        /usr/bin/head -c \(size) /dev/zero | /usr/bin/tr '\\0' 'x'
        exit 0
        """, into: artifacts)
      let reply = await call(child, action: "sections", fields: [:])
      #expect((reply.reason == "output_too_large") == tooLarge)
    }
  }

}
