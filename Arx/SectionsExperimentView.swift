import Darwin
import Foundation
import SwiftUI

// No BridgeViewModel, SharingController, listener or pairing object exists here.
struct SectionsExperimentView: View {
  @State private var model = SectionsExperimentModel()

  var body: some View {
    @Bindable var model = model
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        Text("Local Sections experiment").font(.largeTitle)
        if model.fixture {
          Text("Fixture data only - no Reminders store or native provider").foregroundStyle(.orange)
        }
        Text("Sharing, browser pairing and the tunnel must stay off.")
        Text("Read-only. Existing Reminders permission only. One section read, then stop.")
        Text(model.message).accessibilityIdentifier("sections-status")
        Button("Load account and list labels") { model.loadLabels() }
          .disabled(model.busy || model.finished)
        Picker("Scratch list", selection: $model.selectedList) {
          Text("Select Arx Test A").tag("")
          ForEach(model.lists) { row in
            Text(row.title + " (" + row.sourceTitle + ")").tag(row.id)
          }
        }
        .disabled(model.busy || model.finished)
        Toggle(
          "Arx Test A is disposable and contains only my one test reminder", isOn: $model.scratch
        )
        .disabled(model.busy || model.finished)
        Button("Locate the single test reminder") { model.locate() }
          .disabled(model.busy || model.finished || !model.canLocate)
        if let item = model.item {
          Text("Confirm this exact reminder: " + item.title).privacySensitive()
          Toggle(
            "This is the disposable reminder I put in the test section", isOn: $model.confirmed
          )
          .disabled(model.busy || model.finished)
        }
        Text("Use a unique temporary section name in Arx Test A.").font(.caption)
        TextField("Expected section name from Apple Reminders", text: $model.expectedSection)
          .disabled(model.busy || model.finished)
        Button("Run one section read (10 seconds maximum)") { model.run() }
          .buttonStyle(.borderedProminent)
          .disabled(!model.canRun || model.busy || model.finished)
        if model.finished {
          Text(
            model.fixture
              ? "Stopped. Synthetic fixture only: nothing was read from or created in Apple Reminders. Close this app."
              : "Stopped. Do not retry this real read. Delete the temporary reminder and section in Apple Reminders, then close this app."
          )
          Text(model.report).textSelection(.enabled).accessibilityIdentifier("sections-report")
          Button("Copy sanitized result") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(model.report, forType: .string)
          }
        }
      }
      .padding(24)
    }
    .onChange(of: model.selectedList) { model.clearSelection() }
    .onChange(of: model.scratch) { model.clearSelection() }
    .frame(minWidth: 680, minHeight: 420)
  }
}

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

nonisolated struct SectionsReply: Codable, Sendable {
  var state: String
  var reason: String
  var lists: [SectionsList]?
  var item: SectionsItem?
  var sectionMatched: Bool?
  // Approved disposable-scope capture and structured error detail. The worker
  // may send these; stage is only ever composed by the parent from validated
  // marker lines, never accepted from the stream.
  var expectedSection: String?
  var actualSection: String?
  var detail: String?
  var errorDomain: String?
  var errorCode: Int?
  var exceptionName: String?
  var stage: String?
}

@MainActor @Observable final class SectionsExperimentModel {
  var lists: [SectionsList] = []
  var selectedList = ""
  var scratch = false
  var item: SectionsItem?
  var confirmed = false
  var expectedSection = ""
  var busy = false
  var finished = false
  var message = "No data read. Confirm the scratch setup before locating a reminder."
  var report = ""
  let fixture: Bool
  private let fixtureReplies: [String: SectionsReply]

  init(
    fixture: Bool = ProcessInfo.processInfo.arguments.contains("--sections-local-fixtures"),
    fixtureReplies: [String: SectionsReply] = [:]
  ) {
    self.fixture = fixture
    self.fixtureReplies = fixtureReplies
    if fixture {
      lists = [
        SectionsList(
          id: "fixture-list", sourceID: "fixture-source", title: "Arx Test A",
          sourceTitle: "Fixture account")
      ]
      message = "Fixture data only. No Reminders store or private provider."
      if ProcessInfo.processInfo.arguments.contains("--sections-local-fixture-result") {
        selectedList = "fixture-list"
        scratch = true
        locate()
        confirmed = true
        expectedSection = "Fixture section"
        run()
      }
    }
  }

  var list: SectionsList? { lists.first { $0.id == selectedList } }
  var canLocate: Bool {
    scratch && list?.title == "Arx Test A" && lists.filter { $0.title == "Arx Test A" }.count == 1
  }
  var canRun: Bool {
    canLocate && item != nil && confirmed
      && !expectedSection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && expectedSection.utf8.count <= 256
  }

  func clearSelection() {
    item = nil
    confirmed = false
  }

  func loadLabels() {
    guard !busy, !finished else { return }
    perform(action: "labels", fields: [:]) { reply in
      self.lists = reply.lists ?? []
      self.selectedList = ""
      self.message =
        reply.state == "labels"
        ? "Select only the disposable Arx Test A list." : "Stopped: " + reply.reason
      if reply.state != "labels" { self.stop(reply, action: "labels") }
    }
  }

  func locate() {
    guard canLocate, let list, !busy, !finished else { return }
    clearSelection()
    perform(
      action: "locate",
      fields: ["sourceID": list.sourceID, "listID": list.id, "scratchConfirmed": "yes"]
    ) { reply in
      guard reply.state == "item", let item = reply.item else {
        self.stop(reply, action: "locate")
        return
      }
      self.item = item
      self.message = "Confirm the exact reminder and its expected section before Run."
    }
  }

  func run() {
    guard canRun, let list, let item, !busy, !finished else { return }
    // Disable permanently before launching. There is no retry path in this mode.
    finished = true
    perform(
      action: "read",
      fields: [
        "sourceID": list.sourceID, "listID": list.id, "reminderID": item.id,
        "expectedSection": expectedSection, "scratchConfirmed": "yes",
      ]
    ) { reply in
      self.stop(reply, action: "read")
    }
  }

  private static let detailPhrases = [
    "status_not_determined": "not determined",
    "status_restricted": "restricted",
    "status_denied": "denied",
    "status_other": "other",
  ]

  // The parent re-allowlists every worker-supplied display field at this
  // boundary; the stream is untrusted even when the worker also allowlists.
  private static let allowedExceptionNames: Set<String> = [
    "NSInvalidArgumentException", "NSInternalInconsistencyException",
    "NSRangeException", "NSGenericException",
  ]

  private static func boundedName(_ value: String?) -> String? {
    guard let value, !value.isEmpty, value.utf8.count <= 256,
      !value.contains("\n"), !value.contains("\r")
    else { return nil }
    return value
  }

  private func stop(_ reply: SectionsReply, action: String) {
    // Capture the disposable context before clearing selection state.
    let knownList = list
    let knownItem = item
    let expected = expectedSection
    finished = true
    item = nil
    lists = []
    confirmed = false
    let reason = Self.diagnosticReason(reply.reason, stage: reply.stage)
    let step = ["labels": "labels", "locate": "selection", "read": "read"][action] ?? "unknown"
    message = "Experiment stopped. " + step + ": " + reason
    let status =
      reply.state == "section" && reply.sectionMatched == true
      ? "candidate section matched" : "unknown or mismatch - stopped"
    // Only this report may leave the Mac. The disposable test list/reminder
    // names, the expected section name and the binding-verified returned name
    // are included per the owner's approval; no unrelated names, unrelated
    // reminder contents, IDs, free-text errors, raw worker output or logs.
    var lines = [
      "OS/build: " + ProcessInfo.processInfo.operatingSystemVersionString,
      "Status: " + status,
      "Step: " + step,
      "Reason: " + reason,
    ]
    if let detail = reply.detail {
      lines.append("Permission: " + (Self.detailPhrases[detail] ?? "unrecognized status token"))
    }
    if let knownList {
      lines.append("Test list: " + knownList.title + " (" + knownList.sourceTitle + ")")
    }
    if let knownItem {
      lines.append("Reminder: " + knownItem.title)
    }
    if action == "read", let expectedName = Self.boundedName(expected) {
      lines.append("Expected section: " + expectedName)
    }
    if action == "read", let actual = Self.boundedName(reply.actualSection) {
      lines.append(
        "Returned section: " + actual
          + " (verified in the selected test list and account; it may be a pre-existing section in that list)"
      )
    }
    if let domain = reply.errorDomain {
      let phrase =
        domain == "EKErrorDomain"
        ? "EventKit error"
        : domain == "NSCocoaErrorDomain" ? "Cocoa error" : "unrecognized error domain"
      var line = "Error: " + phrase
      if let code = reply.errorCode { line += " code \(code)" }
      lines.append(line)
    }
    if let exception = reply.exceptionName {
      lines.append(
        "Exception: "
          + (Self.allowedExceptionNames.contains(exception)
            ? exception : "unrecognized exception type"))
    }
    lines.append("Section matched: " + (reply.sectionMatched == true ? "yes" : "not established"))
    report = lines.joined(separator: "\n")
  }

  // Closed vocabulary at the final display/copy boundary. Never echo worker text.
  static func diagnosticReason(_ reason: String, stage: String? = nil) -> String {
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
    case "section_name_mismatch": "expected section did not match"
    case "private_api_exception": "private API exception"
    case "denied": "scope refused"
    case "timeout": "worker timed out" + interval + "; read unknown"
    case "worker_unavailable": "worker result unavailable; read unknown"
    case "spawn_unavailable": "worker launch unavailable; read unknown"
    case "input_unavailable": "worker input unavailable; read unknown"
    case "spawn_failed": "worker launch failed; read unknown"
    case "pipe_setup_failed": "worker channel setup failed; read unknown"
    case "write_failed": "worker write failed; read unknown"
    case "read_failed": "worker read failed; read unknown"
    case "output_too_large": "reply too large; read unknown"
    case "output_undecodable": "reply not readable; read unknown"
    case "labels_too_large": "label names too large; read unknown"
    case "exact_object_candidate": "candidate section matched"
    case "fixture": "synthetic fixture"
    default: "unrecognized result; read unknown"
    }
  }

  private func perform(
    action: String, fields: [String: String],
    completion: @escaping @MainActor (SectionsReply) -> Void
  ) {
    busy = true
    message = "Working locally. No sharing or network connection."
    if fixture {
      busy = false
      if let overridden = fixtureReplies[action] {
        completion(overridden)
        return
      }
      switch action {
      case "labels":
        completion(SectionsReply(state: "labels", reason: "fixture", lists: lists))
      case "locate":
        completion(
          SectionsReply(
            state: "item", reason: "fixture",
            item: SectionsItem(id: "fixture-item", title: "Disposable Sections check")))
      default:
        completion(SectionsReply(state: "section", reason: "fixture", sectionMatched: true))
      }
      return
    }
    Task {
      let reply = await Task.detached {
        SectionsWorkerTransport.call(action: action, fields: fields)
      }.value
      busy = false
      completion(reply)
    }
  }
}

// The child is this SAME app executable, signed with the existing app identity.
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
    // A line still open at 33+ bytes can never be a valid marker and stays in
    // the non-marker rest; a partial line at the end likewise stays behind.
    while let newline = rest.prefix(33).firstIndex(of: 0x0A) {
      let line = rest[...newline]
      guard line.count <= 32,
        let text = String(data: line, encoding: .utf8),
        text.hasPrefix("stage="), text.hasSuffix("\n")
      else { break }
      let token = String(text.dropFirst(6).dropLast(1))
      guard expected.contains(token) else { break }
      markers.append(token)
      markerBytes += line.count
      if markerBytes > markerByteCap {
        return MarkerSplit(stage: nil, rest: output, overflow: true, malformed: false)
      }
      rest = Data(rest.dropFirst(line.count))
    }
    if rest.count > nonMarkerByteCap {
      return MarkerSplit(stage: nil, rest: output, overflow: true, malformed: false)
    }
    // The received lines must form an in-order subsequence of the expected
    // sequence: out-of-order, duplicate or unknown-position markers are
    // malformed output, never silently absorbed.
    var cursor = 0
    for token in markers {
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

  nonisolated static func call(action: String, fields: [String: String]) -> SectionsReply {
    guard let executable = Bundle.main.executableURL else {
      return SectionsReply(state: "unknown", reason: "spawn_unavailable")
    }
    return call(
      executable: executable, arguments: ["--sections-local-worker"], action: action, fields: fields
    )
  }

  // Synthetic tests substitute the child executable and arguments. The protocol,
  // 10-second deadline, output bound and exit-status rules below stay identical.
  nonisolated static func call(
    executable: URL, arguments: [String], action: String, fields: [String: String]
  ) -> SectionsReply {
    var input = fields
    input["action"] = action
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
    let until = DispatchTime.now().uptimeNanoseconds + 10_000_000_000
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
          if output.count < aggregateByteCap {
            output.append(contentsOf: chunk.prefix(min(count, aggregateByteCap - output.count)))
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
    if split.overflow || total > aggregateByteCap {
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
      return SectionsReply(state: "unknown", reason: "output_undecodable")
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
      return SectionsReply(state: "unknown", reason: "output_undecodable")
    }
    // The worker's JSON is untrusted: the interval stage is never accepted from
    // the stream. A decoded reply always carries no stage; only the parent's
    // own transport-fate replies attach one, composed from validated markers.
    result.stage = nil
    return result
  }
}
