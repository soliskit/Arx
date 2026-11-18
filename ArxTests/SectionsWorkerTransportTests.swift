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

  private func makeChild(_ body: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("sections-transport-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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
    let child = try makeChild(
      """
      input=$(cat)
      case "$input" in
        *'"action":"labels"'*) ;;
        *) exit 64 ;;
      esac
      printf '%s' '{"state":"labels","reason":"local_selection_only","lists":[]}'
      exit 0
      """)
    let reply = await call(child)
    #expect(reply.state == "labels")
    #expect(reply.lists?.isEmpty == true)
  }

  @Test func acceptedWorkerStatusesReturnReply() async throws {
    for status in [69, 77] {
      let child = try makeChild(
        """
        cat > /dev/null
        printf '%s' '{"state":"unknown","reason":"fixture_no_provider"}'
        exit \(status)
        """)
      let reply = await call(child, action: "read", fields: Self.readFields)
      #expect(reply.state == "unknown")
      #expect(reply.reason == "fixture_no_provider")
    }
  }

  @Test func unlistedExitStatusIsUnavailable() async throws {
    let child = try makeChild(
      """
      cat > /dev/null
      printf '%s' '{"state":"section","reason":"exact_object_candidate","sectionMatched":true}'
      exit 1
      """)
    let reply = await call(child, action: "read", fields: Self.readFields)
    #expect(reply.state == "unknown")
    #expect(reply.reason == "worker_unavailable")
  }

  @Test func workerDeadlineExitIsReportedAsTimeout() async throws {
    let child = try makeChild(
      """
      cat > /dev/null
      exit 124
      """)
    let reply = await call(child)
    #expect(reply.state == "unknown")
    #expect(reply.reason == "timeout")
  }

  @Test func signalDeathIsUnavailableNotTimeout() async throws {
    let child = try makeChild(
      """
      cat > /dev/null
      kill -KILL $$
      """)
    let reply = await call(child)
    #expect(reply.state == "unknown")
    #expect(reply.reason == "worker_unavailable")
  }

  @Test func malformedOutputIsUnavailable() async throws {
    let child = try makeChild(
      """
      cat > /dev/null
      printf '%s' 'not a sections reply'
      exit 0
      """)
    let reply = await call(child)
    #expect(reply.state == "unknown")
    #expect(reply.reason == "worker_unavailable")
  }

  @Test func oversizedOutputIsUnavailable() async throws {
    let child = try makeChild(
      """
      cat > /dev/null
      dd if=/dev/zero bs=1024 count=20 2>/dev/null | tr '\\0' 'x'
      exit 0
      """)
    let reply = await call(child)
    #expect(reply.state == "unknown")
    #expect(reply.reason == "worker_unavailable")
  }

  @Test func parentDeadlineStopsRunawayChild() async throws {
    let child = try makeChild(
      """
      exec sleep 60
      """)
    let started = Date()
    let reply = await call(child)
    let elapsed = Date().timeIntervalSince(started)
    #expect(reply.state == "unknown")
    #expect(reply.reason == "timeout")
    #expect(elapsed >= 8 && elapsed < 20)
  }

  @Test func refusalDoesNotRetryTheChild() async throws {
    let countFile = FileManager.default.temporaryDirectory
      .appendingPathComponent("sections-launches-" + UUID().uuidString)
    let child = try makeChild(
      """
      cat > /dev/null
      printf 'launched\\n' >> '\(countFile.path)'
      exit 1
      """)
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
