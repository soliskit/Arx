import Darwin
import Foundation

// Synthetic smoke mode only: the signed app spawns its embedded helper with
// the fixture flag, so the helper refuses before any EventKit store, existing
// permission state or private provider is touched. The raw marker/JSON stream
// and the exit status pass through unmodified. This mode is never reachable
// from the production UI flow, and the app exits before any GUI.
enum SectionsHelperFixtureProbe {
  static func run() -> Int32 {
    signal(SIGPIPE, SIG_IGN)
    guard let helper = Bundle.main.url(forAuxiliaryExecutable: "ArxSectionsWorker") else {
      return 65
    }
    let process = Process()
    process.executableURL = helper
    process.arguments = ["--sections-local-fixtures"]
    let stdin = Pipe()
    process.standardInput = stdin
    process.standardOutput = FileHandle.standardOutput
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
    } catch {
      return 65
    }
    do {
      try stdin.fileHandleForWriting.write(contentsOf: Array(#"{"action":"labels"}"#.utf8))
      try stdin.fileHandleForWriting.close()
    } catch {
      process.terminate()
      return 65
    }
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      process.waitUntilExit()
      done.signal()
    }
    if done.wait(timeout: .now() + 15) == .timedOut {
      process.terminate()
      return 65
    }
    guard process.terminationReason == .exit else {
      return 65
    }
    return process.terminationStatus
  }
}
