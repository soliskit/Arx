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
            "Stopped. Do not retry this real read. Delete the temporary reminder and section in Apple Reminders, then close this app."
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

  private func stop(_ reply: SectionsReply, action: String) {
    finished = true
    item = nil
    lists = []
    confirmed = false
    let reason = Self.diagnosticReason(reply.reason)
    let step = ["labels": "labels", "locate": "selection", "read": "read"][action] ?? "unknown"
    message = "Experiment stopped. " + step + ": " + reason
    let status =
      reply.state == "section" && reply.sectionMatched == true
      ? "candidate section matched" : "unknown or mismatch - stopped"
    // Only this report may leave the Mac. No worker output, IDs, text or logs.
    report =
      "OS/build: " + ProcessInfo.processInfo.operatingSystemVersionString + "\nStatus: " + status
      + "\nStep: " + step + "\nReason: " + reason
      + "\nSection matched: " + (reply.sectionMatched == true ? "yes" : "not established")
  }

  // Closed vocabulary at the final display/copy boundary. Never echo worker text.
  static func diagnosticReason(_ reason: String) -> String {
    switch reason {
    case "existing_permission_unavailable": "existing permission unavailable"
    case "label_bound_exceeded": "label limit exceeded"
    case "labels_unverified": "labels unverified"
    case "selection_unavailable": "selection unavailable"
    case "selection_timeout": "selection timed out"
    case "selection_not_exactly_one": "expected one reminder"
    case "identity_unverified": "object binding unverified"
    case "private_framework_unavailable": "private framework unavailable"
    case "membership_api_unavailable": "membership API unavailable"
    case "membership_unverified": "membership unverified"
    case "section_name_mismatch": "expected section did not match"
    case "private_api_exception": "private API exception"
    case "denied": "scope refused"
    case "timeout": "worker timed out; read unknown"
    case "worker_unavailable": "worker result unavailable; read unknown"
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
  nonisolated static func call(action: String, fields: [String: String]) -> SectionsReply {
    let refused = SectionsReply(state: "unknown", reason: "worker_unavailable")
    guard let executable = Bundle.main.executableURL else { return refused }
    var input = fields
    input["action"] = action
    guard let bytes = try? JSONEncoder().encode(input), bytes.count <= 4096 else { return refused }
    let process = Process()
    process.executableURL = executable
    process.arguments = ["--sections-local-worker"]
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
    let until = DispatchTime.now().uptimeNanoseconds + 10_000_000_000
    do {
      try process.run()
      try stdin.fileHandleForWriting.write(contentsOf: bytes)
      try stdin.fileHandleForWriting.close()
      // Worker enforces SIGALRM at entry; parent also kills it after 10 seconds.
      while process.isRunning && DispatchTime.now().uptimeNanoseconds < until {
        Thread.sleep(forTimeInterval: 0.025)
      }
      if process.isRunning {
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
        return SectionsReply(state: "unknown", reason: "timeout")
      }
      let output = try stdout.fileHandleForReading.readToEnd() ?? Data()
      guard output.count <= 16384,
        let result = try? JSONDecoder().decode(SectionsReply.self, from: output),
        [0, 69, 77].contains(process.terminationStatus)
      else { return refused }
      return result
    } catch {
      if process.isRunning {
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
      }
      return refused
    }
  }
}
