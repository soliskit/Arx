import BridgeCore
import Foundation

@main struct FixtureServer {
  @MainActor static func main() async throws {
    // This executable never constructs EventKitStore or requests Apple access.
    guard CommandLine.arguments.count == 4 else { throw BridgeFailure.invalid }
    let origin = CommandLine.arguments[1]
    let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    let port = Int(CommandLine.arguments[3]) ?? 0
    let controller = SharingController(store: FixtureStore())
    try controller.start()
    var rights = ClientRights()
    rights.read = true
    rights.manage = true
    rights.delete = true
    rights.lists = ["inbox", "weekend"]
    let (_, secret) = try controller.pairClient(label: "Browser fixture", rights: rights)
    let server = BridgeServer(
      sharing: controller, configuration: try .init(origin: origin, port: port))
    try Data(secret.utf8).write(to: directory.appendingPathComponent("pairing"), options: .atomic)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: directory.appendingPathComponent("pairing").path)
    try await server.run {
      try? Data().write(to: directory.appendingPathComponent("ready"), options: .atomic)
    }
  }
}
