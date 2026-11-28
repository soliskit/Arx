//
//  SectionsWorkerTransport.swift
//  Arx
//
//  Transport to the embedded section-reading helper. Moved without behavior
//  change from the qualified local-proof build; no UI lives here.
//

import Darwin
import Foundation

nonisolated struct SectionsList: Codable, Identifiable, Sendable {
  let id: String
  let sourceID: String
  let title: String
  let sourceTitle: String
}

nonisolated struct SectionsItem: Codable, Sendable {
  let id: String
  let title: String
}

// One batch name-reporting row: fixed fields only. The worker attaches
// reminderID to every row it returns, including rows whose identity check
// failed; actualSection is present only on a verified name read. Every display
// use passes the same bounded re-allowlist as the single-read fields.
nonisolated struct SectionsEntry: Codable, Sendable {
  let state: String
  let reason: String
  let reminderID: String?
  let actualSection: String?
  var errorDomain: String? = nil
  var errorCode: Int? = nil
  var exceptionName: String? = nil
}

nonisolated struct SectionsReply: Codable, Sendable {
  var state: String
  var reason: String
  var lists: [SectionsList]?
  var item: SectionsItem?
  var sectionMatched: Bool?
  // Bounded capture fields and structured error detail. The worker
  // may send these; stage is only ever composed by the parent from validated
  // marker lines, never accepted from the stream.
  var expectedSection: String?
  var actualSection: String?
  // Batch rows for action "sections"; nil on single-read and labels replies.
  var results: [SectionsEntry]?
  var detail: String?
  // Parent-composed, closed-format transport facts for an unreadable reply.
  // Never accepted from the worker stream.
  var transport: String?
  var errorDomain: String?
  var errorCode: Int?
  var exceptionName: String?
  var stage: String?
  var requestNonce: String?
  var requestBound: Bool?
  var sourceRevision: String?
  var sourceManifest: String?
  var buildBound: Bool?
  var helperFileSHA256: String?
}

// Closed vocabulary for every reason shown or mapped at the display boundary.
nonisolated enum SectionsDiagnostics {

  // Closed vocabulary at the final display/copy boundary. Never echo worker text.
  nonisolated static func diagnosticReason(_ reason: String, stage: String? = nil) -> String {
    // The interval phrase is parent-composed from validated marker lines only.
    let interval = stage.map { " " + $0 } ?? ""
    // Numbered child fates are fixed tokens too: ASCII digits only, and the
    // number is all that ever crosses this boundary.
    for (prefix, phrase) in [
      ("child_signaled_", "worker stopped by signal "), ("child_exit_", "worker exited, code "),
    ] where reason.hasPrefix(prefix) {
      let digits = reason.dropFirst(prefix.count)
      guard !digits.isEmpty, digits.allSatisfy({ $0 >= "0" && $0 <= "9" }) else {
        return "unrecognized result; read unknown"
      }
      return phrase + digits + interval + "; read unknown"
    }
    return switch reason {
    case "existing_permission_unavailable": "existing permission unavailable"
    case "label_bound_exceeded": "label limit exceeded"
    case "labels_unverified": "labels unverified"
    case "selection_unavailable": "selection unavailable"
    case "selection_timeout": "selection timed out"
    case "selection_not_exactly_one": "expected one reminder"
    case "identity_unverified": "object binding unverified"
    case "identity_list_unverified": "list identity unverified"
    case "identity_source_unverified": "account identity unverified"
    case "identity_title_unverified": "title identity unverified"
    case "private_framework_unavailable": "private framework unavailable"
    case "membership_api_unavailable": "membership API unavailable"
    case "membership_unverified": "membership unverified"
    case "membership_nil_no_error": "membership unverified (empty result, no error)"
    case "membership_none_3009": "membership unverified (provider code -3009)"
    case "membership_error": "membership unverified (lookup error)"
    case "store_unavailable": "private store unavailable"
    case "view_init_unavailable": "section view unavailable"
    case "fetch_selector_unavailable": "membership lookup unavailable"
    case "id_construction_unavailable": "membership identifier construction unavailable"
    case "membership_section_identity": "membership unverified (section identity)"
    case "membership_unnamed": "membership unverified (section unnamed)"
    case "section_name_mismatch": "expected section did not match"
    case "private_api_exception": "private API exception"
    case "denied": "scope refused"
    case "timeout": "worker timed out" + interval + "; read unknown"
    case "read_busy": "section reading busy; read unknown"
    case "worker_unavailable": "worker result unavailable; read unknown"
    case "spawn_unavailable": "worker launch unavailable; read unknown"
    case "input_unavailable": "worker input unavailable; read unknown"
    case "request_binding_unverified": "worker request binding unverified; read unknown"
    case "build_binding_unverified": "worker build binding unverified; read unknown"
    case "helper_identity_unverified":
      "worker file identity unverified" + interval + "; read unknown"
    case "spawn_failed": "worker launch failed; read unknown"
    case "pipe_setup_failed": "worker channel setup failed; read unknown"
    case "write_failed": "worker write failed; read unknown"
    case "read_failed": "worker read failed; read unknown"
    case "output_too_large": "reply too large; read unknown"
    case "output_undecodable": "reply not readable; read unknown"
    case "labels_too_large": "label names too large; read unknown"
    case "sections_too_large": "section labels too large; read unknown"
    case "sections_bound_exceeded": "list reminder limit exceeded; read unknown"
    case "exact_object_name": "section label read"
    case "exact_object_candidate": "candidate section matched"
    case "fixture": "synthetic fixture"
    default: "unrecognized result; read unknown"
    }
  }
}

// The child is the ArxSectionsWorker helper tool embedded in this app bundle.
// It has no GUI, listener or permission request. Missing inherited access refuses.
enum SectionsWorkerTransport {
  // Fixed marker protocol: the worker emits complete lines "stage=<op>.<before|after>"
  // in program order, all before the result JSON. The parent validates them as
  // an in-order subsequence of the expected per-action sequence and composes a
  // bounded interval phrase from the last complete line. Byte bounds, fail
  // closed: non-marker bytes <= 16384, complete marker lines <= 512, and the
  // aggregate buffer <= 16896 at all times, so no partial or unknown line can
  // accumulate without bound.
  nonisolated static let markerByteCap = 512
  nonisolated static let nonMarkerByteCap = 16384
  nonisolated static let aggregateByteCap = 16896
  // The batch action also carries the per-reminder reader markers: four fixed
  // lines (108 bytes) for each of at most 200 reminders, plus the outer lines.
  // Only the batch action gets this larger marker bound.
  nonisolated static let sectionsMarkerByteCap = 24_576
  nonisolated static func markerCap(for action: String) -> Int {
    action == "sections" ? sectionsMarkerByteCap : markerByteCap
  }
  // Reader markers the batch worker's reader emits for each reminder, inside
  // the sections.read window. Within one reminder they come in this order, but
  // a stream may lose lines or repeat a cycle, so the parser counts cycles
  // rather than demanding one exact sequence.
  nonisolated static let sectionsInnerStages = [
    "objects.bind.before", "objects.bind.after",
    "membership.call.before", "membership.call.after",
  ]
  nonisolated static let sectionsReminderBound = 200
  // The batch reply carries up to 64KB of fixed-shape rows plus its marker
  // prefix; every other action keeps the original bounds.
  nonisolated static func outputCaps(for action: String) -> (nonMarker: Int, aggregate: Int) {
    action == "sections"
      ? (65_536, 65_536 + sectionsMarkerByteCap + 64) : (nonMarkerByteCap, aggregateByteCap)
  }
  // Zero validated markers is its own closed wording, stated as-is: the child
  // died before the first marker, or the marker output was lost. It is never
  // silently folded into the plain no-stage phrases.
  nonisolated static let noMarkerStage =
    "no stage marker received (checkpoint not reached or output lost)"
  nonisolated static let expectedStages: [String: [String]] = [
    "labels": [
      "input.read", "permission.check", "store.create", "lists.enumerate",
      "labels.validate", "reply.encode",
    ],
    "locate": [
      "input.read", "permission.check", "store.create", "calendar.bind",
      "predicate.create", "reminders.fetch", "row.check", "reply.encode",
    ],
    "read": [
      "input.read", "permission.check", "store.create", "calendar.bind",
      "framework.load", "objects.bind", "membership.call", "reply.encode",
    ],
    "sections": [
      "input.read", "permission.check", "store.create", "calendar.bind",
      "sections.enumerate", "framework.load", "sections.read", "reply.encode",
    ],
  ]
  nonisolated static let stagePhrases: [String: String] = [
    "input.read": "input read",
    "permission.check": "permission checking",
    "store.create": "EventKit setup",
    "lists.enumerate": "list enumeration",
    "labels.validate": "label checking",
    "reply.encode": "report encoding",
    "calendar.bind": "list binding",
    "predicate.create": "query setup",
    "reminders.fetch": "reminder lookup",
    "row.check": "reminder check",
    "framework.load": "framework loading",
    "objects.bind": "object selection",
    "membership.call": "section lookup",
    "sections.enumerate": "reminder enumeration",
    "sections.read": "section reads",
  ]

  nonisolated struct MarkerSplit: Sendable {
    var stage: String?
    var rest: Data
    var overflow: Bool
    var malformed: Bool
  }

  nonisolated static func splitMarkers(_ output: Data, action: String) -> MarkerSplit {
    let operations = expectedStages[action] ?? []
    let expected = operations.flatMap { [$0 + ".before", $0 + ".after"] }
    var markers: [String] = []
    var markerBytes = 0
    var rest = output
    let caps = outputCaps(for: action)
    let markerLimit = markerCap(for: action)
    let inner = action == "sections" ? sectionsInnerStages : []
    // A line still open at 33+ bytes can never be a valid marker and stays in
    // the non-marker rest; a partial line at the end likewise stays behind.
    while let newline = rest.prefix(33).firstIndex(of: 0x0A) {
      let line = rest[...newline]
      guard line.count <= 32,
        let text = String(data: line, encoding: .utf8),
        text.hasPrefix("stage="), text.hasSuffix("\n")
      else { break }
      let token = String(text.dropFirst(6).dropLast(1))
      guard expected.contains(token) || inner.contains(token) else { break }
      markers.append(token)
      markerBytes += line.count
      if markerBytes > markerLimit {
        return MarkerSplit(stage: nil, rest: output, overflow: true, malformed: false)
      }
      rest = Data(rest.dropFirst(line.count))
    }
    if rest.count > caps.nonMarker {
      return MarkerSplit(stage: nil, rest: output, overflow: true, malformed: false)
    }
    // The received lines must form an in-order subsequence of the expected
    // sequence for OUTER markers: out-of-order, duplicate or unknown-position
    // outer markers are malformed output, never silently absorbed.
    var cursor = 0
    var innerPosition = -1
    var reminderCycles = 0
    // Reader markers are loss-tolerant: a lost line must never turn a valid
    // reply into a rejected one, and a present line never proves a read. A
    // marker stream cannot tell a duplicate or backward line from the next
    // reminder's cycle with lost lines, so the grammar takes the minimum-cycle
    // reading: the first reader line starts a cycle, and any line whose position
    // does not increase starts another one. The cycle count is bounded by the
    // worker's own 200-reminder limit. The window closes by OUTER progress: any
    // matched outer token after sections.read.before (including a lost
    // sections.read.after's successors, reply.encode) makes later reader lines
    // malformed. Every decoded identity and reply gate is unchanged.
    let windowClose = expected.firstIndex(of: "sections.read.before") ?? -1
    for token in markers {
      if let position = inner.firstIndex(of: token) {
        guard cursor - 1 <= windowClose else {
          return MarkerSplit(stage: nil, rest: output, overflow: false, malformed: true)
        }
        if position <= innerPosition || innerPosition < 0 {
          reminderCycles += 1
          guard reminderCycles <= sectionsReminderBound else {
            return MarkerSplit(stage: nil, rest: output, overflow: false, malformed: true)
          }
        }
        innerPosition = position
        // A reader line proves the stream passed sections.read.before, so no
        // earlier outer marker may follow it; the window stays open at that bound.
        cursor = max(cursor, windowClose + 1)
        continue
      }
      guard let hit = expected[cursor...].firstIndex(of: token) else {
        return MarkerSplit(stage: nil, rest: output, overflow: false, malformed: true)
      }
      cursor = hit + 1
    }
    var stage: String?
    if let last = markers.last {
      let isBefore = last.hasSuffix(".before")
      let operation = String(last.dropLast(isBefore ? 7 : 6))
      let phrase = stagePhrases[operation] ?? operation
      if isBefore {
        stage = "during " + phrase
      } else if let index = operations.firstIndex(of: operation), index + 1 < operations.count {
        let next = stagePhrases[operations[index + 1]] ?? operations[index + 1]
        stage = "after " + phrase + ", before " + next
      } else {
        stage = "after " + phrase
      }
    }
    return MarkerSplit(stage: stage, rest: rest, overflow: false, malformed: false)
  }

  // Closed format only: fixed tokens and decimal counts computed by the parent.
  // No byte of the worker's output is copied into the summary.
  nonisolated static func transportSummary(
    path: String, total: Int, body: Int, exitStatus: Int32? = nil,
    startsWithBrace: Bool? = nil, stage: String? = nil
  ) -> String {
    var parts = ["path=" + path, "bytes=\(total)", "body=\(body)"]
    if let exitStatus { parts.append("exit=\(exitStatus)") }
    if let startsWithBrace { parts.append("starts_with_brace=" + (startsWithBrace ? "yes" : "no")) }
    if let stage { parts.append("stage=" + stage) }
    return parts.joined(separator: "; ")
  }

  nonisolated static func call(
    action: String, fields: [String: String], budgetSeconds: UInt64 = 10
  ) -> SectionsReply {
    guard let executable = Bundle.main.url(forAuxiliaryExecutable: "ArxSectionsWorker") else {
      return SectionsReply(state: "unknown", reason: "spawn_unavailable")
    }
    return callWithBuildContext(
      executable: executable, action: action, fields: fields,
      attributionEnabled: ARXSectionWorker.requiresAttribution(),
      revision: ARXSectionWorker.sourceRevision(), manifest: ARXSectionWorker.sourceManifest(),
      budgetSeconds: budgetSeconds)
  }

  // Exact production orchestration, separately callable with disposable child
  // fixtures. No fixture uses the real app helper or a provider.
  nonisolated static func callWithBuildContext(
    executable: URL, action: String, fields: [String: String],
    attributionEnabled: Bool, revision: String, manifest: String,
    budgetSeconds: UInt64 = 10
  ) -> SectionsReply {
    // All admission hashing and the child exchange share one budget. Batch
    // callers pass a budget above the worker's 30-second self-terminating
    // alarm; every other caller keeps the original 10 seconds.
    let deadline = DispatchTime.now().uptimeNanoseconds + budgetSeconds * 1_000_000_000
    let nonce = UUID().uuidString
    if !attributionEnabled
      || !SectionsBuildAttribution.lowercaseHex(revision, count: 40)
      || !SectionsBuildAttribution.lowercaseHex(manifest, count: 64)
    {
      // Preserve the ordinary one-read route without imposing source-stamp or
      // helper-file admission. It reports no established build attribution.
      var ordinary = call(
        executable: executable, arguments: [], action: action, fields: fields,
        expectedNonce: nonce, deadline: deadline)
      ordinary.requestNonce = nonce
      return ordinary
    }
    var result = SectionsReply(state: "unknown", reason: "helper_identity_unverified")
    do {
      let beforeHash = try SectionsBuildAttribution.helperDigest(executable, deadline: deadline)
      result = call(
        executable: executable, arguments: [], action: action, fields: fields,
        expectedNonce: nonce, expectedRevision: revision, expectedManifest: manifest,
        deadline: deadline)
      let afterHash = try SectionsBuildAttribution.helperDigest(executable, deadline: deadline)
      guard beforeHash == afterHash else {
        throw SectionsBuildAttribution.AttributionFailure.unverified
      }
      result.helperFileSHA256 = beforeHash
    } catch {
      result = SectionsReply(
        state: "unknown", reason: "helper_identity_unverified", stage: result.stage)
    }
    // These values originate in the parent, never from decoded worker text.
    result.requestNonce = nonce
    result.sourceRevision = revision
    result.sourceManifest = manifest
    return result
  }

  // Synthetic tests substitute the child executable and arguments. The protocol,
  // 10-second deadline, output bound and exit-status rules below stay identical.
  nonisolated static func call(
    executable: URL, arguments: [String], action: String, fields: [String: String],
    expectedNonce: String? = nil, expectedRevision: String? = nil,
    expectedManifest: String? = nil, deadline: UInt64? = nil
  ) -> SectionsReply {
    var input = fields
    input["action"] = action
    if let expectedNonce {
      guard UUID(uuidString: expectedNonce)?.uuidString == expectedNonce else {
        return SectionsReply(state: "unknown", reason: "input_unavailable")
      }
      input["requestNonce"] = expectedNonce
    }
    guard let bytes = try? JSONEncoder().encode(input), bytes.count <= 4096 else {
      return SectionsReply(state: "unknown", reason: "input_unavailable")
    }
    let process = Process()
    process.executableURL = executable
    process.arguments = arguments
    let stdin = Pipe()
    let stdout = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    // No private diagnostic stream is retained or allowed to fill a pipe.
    process.standardError = FileHandle.nullDevice
    // A fast permission refusal may close stdin before this write. Ignore only
    // SIGPIPE for this thread so EPIPE becomes a caught error, not app death.
    var blocked = sigset_t()
    var previous = sigset_t()
    sigemptyset(&blocked)
    sigaddset(&blocked, SIGPIPE)
    pthread_sigmask(SIG_BLOCK, &blocked, &previous)
    defer {
      var pending = sigset_t()
      sigpending(&pending)
      if sigismember(&pending, SIGPIPE) == 1 {
        var received: Int32 = 0
        sigwait(&blocked, &received)
      }
      pthread_sigmask(SIG_SETMASK, &previous, nil)
    }
    // One deadline bounds everything that waits on the child: the input write,
    // the run and the output drain. Launch itself is a single spawn call that
    // refuses fast on a missing child. The worker enforces SIGALRM at entry.
    let until = deadline ?? (DispatchTime.now().uptimeNanoseconds + 10_000_000_000)
    guard DispatchTime.now().uptimeNanoseconds < until else {
      return SectionsReply(state: "unknown", reason: "timeout")
    }
    do {
      try process.run()
    } catch {
      // A missing or unexecutable child refuses without any waiting.
      return SectionsReply(state: "unknown", reason: "spawn_failed")
    }
    // Both pipe ends must be nonblocking so no child behavior can stall the
    // parent past the deadline; failing to set that refuses the exchange closed.
    let descriptor = stdout.fileHandleForReading.fileDescriptor
    let writeDescriptor = stdin.fileHandleForWriting.fileDescriptor
    func makeNonblocking(_ fd: Int32) -> Bool {
      let flags = fcntl(fd, F_GETFL)
      return flags >= 0 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0
    }
    guard makeNonblocking(descriptor), makeNonblocking(writeDescriptor) else {
      kill(process.processIdentifier, SIGKILL)
      process.waitUntilExit()
      return SectionsReply(state: "unknown", reason: "pipe_setup_failed")
    }
    // The input write shares the deadline: a child that never reads cannot stall
    // the parent, and a fast refusal closing stdin fails the write with EPIPE.
    var writeComplete = false
    var written = 0
    while !writeComplete && DispatchTime.now().uptimeNanoseconds < until {
      let count = bytes.withUnsafeBytes { buffer -> Int in
        guard let base = buffer.baseAddress else { return 0 }
        return write(writeDescriptor, base + written, buffer.count - written)
      }
      if count > 0 {
        written += count
        writeComplete = written == bytes.count
      } else if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
        Thread.sleep(forTimeInterval: 0.025)
      } else {
        // EPIPE from a fast refusal, or another write error: the child never got
        // the full input, so the exchange cannot produce an accepted reply.
        break
      }
    }
    try? stdin.fileHandleForWriting.close()
    // Drain stdout while the child runs so a full pipe can never stall it into
    // the deadline; bytes past the aggregate bound are counted and discarded.
    // Each read rechecks the deadline, so even a continuously writing child
    // cannot hold the parent past it.
    let caps = outputCaps(for: action)
    var output = Data()
    var total = 0
    var sawEOF = false
    var readFailed = false
    var chunk = [UInt8](repeating: 0, count: 8192)
    drain: while DispatchTime.now().uptimeNanoseconds < until {
      while DispatchTime.now().uptimeNanoseconds < until {
        let count = chunk.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
        if count > 0 {
          total += count
          if output.count < caps.aggregate {
            output.append(contentsOf: chunk.prefix(min(count, caps.aggregate - output.count)))
          }
        } else if count == 0 {
          sawEOF = true
          break
        } else if errno == EAGAIN || errno == EWOULDBLOCK {
          break
        } else {
          readFailed = true
          break drain
        }
      }
      // The exchange completes only when the output stream has closed AND the
      // child has finished; a reply already at EOF never makes the parent kill
      // a child that has simply not been reaped yet.
      if sawEOF && !process.isRunning { break }
      // A descendant holding stdout open after the child exits reaches this same
      // deadline; the parent never blocks on a post-exit read again.
      Thread.sleep(forTimeInterval: 0.025)
    }
    if readFailed {
      if process.isRunning {
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
      }
      return SectionsReply(state: "unknown", reason: "read_failed")
    }
    // Marker extraction happens before fate classification so a stopped child
    // can name the bounded interval it reached. Overflow and malformed marker
    // sequences fail closed here, after any needed kill.
    let split = splitMarkers(output, action: action)
    if split.overflow || total > caps.aggregate {
      if process.isRunning {
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
      }
      return SectionsReply(state: "unknown", reason: "output_too_large")
    }
    if split.malformed {
      if process.isRunning {
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
      }
      return SectionsReply(
        state: "unknown", reason: "output_undecodable",
        transport: transportSummary(path: "markers", total: total, body: split.rest.count))
    }
    if process.isRunning {
      kill(process.processIdentifier, SIGKILL)
      process.waitUntilExit()
      return SectionsReply(
        state: "unknown", reason: "timeout", stage: split.stage ?? noMarkerStage)
    }
    process.waitUntilExit()
    if !sawEOF {
      // The child exited but its output stream never closed before the deadline.
      return SectionsReply(
        state: "unknown", reason: "timeout", stage: split.stage ?? noMarkerStage)
    }
    if process.terminationReason == .exit && process.terminationStatus == 124 {
      return SectionsReply(
        state: "unknown", reason: "timeout", stage: split.stage ?? noMarkerStage)
    }
    // Each transport leg names its own fixed stop reason; none of these tokens
    // carries worker output, only the failed leg and a tiny status number.
    guard writeComplete else { return SectionsReply(state: "unknown", reason: "write_failed") }
    guard process.terminationReason == .exit else {
      return SectionsReply(
        state: "unknown", reason: "child_signaled_\(process.terminationStatus)",
        stage: split.stage ?? noMarkerStage)
    }
    guard [0, 69, 77].contains(process.terminationStatus) else {
      return SectionsReply(
        state: "unknown", reason: "child_exit_\(process.terminationStatus)",
        stage: split.stage ?? noMarkerStage)
    }
    guard var result = try? JSONDecoder().decode(SectionsReply.self, from: split.rest) else {
      return SectionsReply(
        state: "unknown", reason: "output_undecodable",
        transport: transportSummary(
          path: "json", total: total, body: split.rest.count,
          exitStatus: process.terminationStatus, startsWithBrace: split.rest.first == 0x7B,
          stage: split.stage))
    }
    // The worker's JSON is untrusted: the interval stage is never accepted from
    // the stream. A decoded reply always carries no stage; only the parent's
    // own transport-fate replies attach one, composed from validated markers.
    result.stage = nil
    result.transport = nil
    result.requestBound = nil
    result.buildBound = nil
    result.helperFileSHA256 = nil
    if let expectedNonce {
      guard result.requestNonce == expectedNonce else {
        return SectionsReply(state: "unknown", reason: "request_binding_unverified")
      }
      result.requestBound = true
    }
    if let expectedRevision, let expectedManifest {
      guard result.sourceRevision == expectedRevision, result.sourceManifest == expectedManifest
      else {
        return SectionsReply(state: "unknown", reason: "build_binding_unverified")
      }
      result.buildBound = true
    }
    result.sourceRevision = nil
    result.sourceManifest = nil
    // Never display or trust a worker-supplied binding verdict.
    result.requestNonce = nil
    return result
  }
}
