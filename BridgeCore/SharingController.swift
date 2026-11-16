import Foundation

#if canImport(CryptoKit)
  import CryptoKit
#else
  import Crypto
#endif

@MainActor public final class SharingController {
  struct Client {
    var info: ClientInfo
    var pairingHash: String?
    var pairingExpiry: Date
    var sessionHash: String?
    var csrf: String?
    var issued: Date?
    var lastSeen: Date?
    var revision: UInt64 = 0
    var operations: [UUID: (Data, SharedReminder?)] = [:]
    var uncertain: Set<UUID> = []
  }
  public let store: any ReminderStore
  public private(set) var running = false
  private var clients: [UUID: Client] = [:]
  private var failedPairings: [Date] = []
  private let clock: @Sendable () -> Date
  public init(store: any ReminderStore, clock: @escaping @Sendable () -> Date = { Date() }) {
    self.store = store
    self.clock = clock
  }
  public var clientInfo: [ClientInfo] { clients.values.map(\.info).sorted { $0.label < $1.label } }
  public func start() throws {
    guard !running, store.authorized else { throw BridgeFailure.unavailable }
    running = true
  }
  public func stop() {
    running = false
    clients.removeAll()
    failedPairings.removeAll()
  }
  public func revoke(_ id: UUID) { clients.removeValue(forKey: id) }
  public func inventory() throws -> [ReminderList] {
    guard store.authorized else {
      stop()
      throw BridgeFailure.unavailable
    }
    return try store.lists()
  }
  public func pairClient(label: String, rights: ClientRights) throws -> (UUID, String) {
    guard running, clients.count < 20, !label.isEmpty, label.count <= 80,
      rights.lists.isSubset(of: Set(try inventory().map(\.id)))
    else { throw BridgeFailure.invalid }
    let id = UUID()
    let secret = Self.secret(bytes: 16)
    clients[id] = Client(
      info: ClientInfo(id: id, label: label, rights: rights, paired: false),
      pairingHash: Self.digest(secret), pairingExpiry: clock().addingTimeInterval(120))
    return (id, secret)
  }
  public func exchange(_ secret: String) throws -> (token: String, csrf: String) {
    guard running, store.authorized else {
      stop()
      throw BridgeFailure.denied
    }
    let now = clock()
    failedPairings.removeAll { now.timeIntervalSince($0) > 60 }
    guard failedPairings.count < 10 else { throw BridgeFailure.rateLimited }
    guard secret.utf8.count <= 128,
      let id = clients.first(where: {
        $0.value.pairingHash == Self.digest(secret) && $0.value.pairingExpiry > now
      })?.key, var client = clients[id]
    else {
      failedPairings.append(now)
      throw BridgeFailure.denied
    }
    let token = Self.secret(bytes: 32)
    let csrf = Self.secret(bytes: 32)
    client.pairingHash = nil
    client.sessionHash = Self.digest(token)
    client.csrf = csrf
    client.issued = now
    client.lastSeen = now
    client.info.paired = true
    clients[id] = client
    return (token, csrf)
  }
  private func session(_ token: String, csrf: String? = nil) throws -> UUID {
    guard running, store.authorized else {
      stop()
      throw BridgeFailure.denied
    }
    let now = clock()
    guard token.utf8.count <= 128,
      let id = clients.first(where: { $0.value.sessionHash == Self.digest(token) })?.key,
      var client = clients[id], let issued = client.issued, let seen = client.lastSeen,
      now.timeIntervalSince(issued) < 86_400, now.timeIntervalSince(seen) < 1800,
      csrf == nil || csrf == client.csrf
    else { throw BridgeFailure.denied }
    client.lastSeen = now
    clients[id] = client
    return id
  }
  public func sessionState(_ token: String) throws -> (rights: ClientRights, csrf: String) {
    let id = try session(token)
    return (clients[id]!.info.rights, clients[id]!.csrf!)
  }
  public func sharedLists(_ token: String) throws -> [ReminderList] {
    let id = try session(token)
    let rights = clients[id]!.info.rights
    guard rights.read else { throw BridgeFailure.denied }
    // Never return source/account inventory to a client.
    return try inventory().filter { rights.lists.contains($0.id) }.map {
      ReminderList(id: $0.id, title: $0.title, writable: $0.writable)
    }
  }
  private func require(_ id: UUID, list: String, action: Mutation.Action? = nil) throws -> UInt64 {
    guard running, store.authorized, let c = clients[id], c.info.rights.lists.contains(list),
      try store.lists().contains(where: { $0.id == list })
    else { throw BridgeFailure.denied }
    if let action {
      guard action == .delete ? c.info.rights.delete : c.info.rights.manage,
        try store.lists().contains(where: { $0.id == list && $0.writable })
      else { throw BridgeFailure.denied }
    } else if !c.info.rights.read {
      throw BridgeFailure.denied
    }
    return c.revision
  }
  public func read(_ token: String, list: String) async throws -> [SharedReminder] {
    let id = try session(token)
    let revision = try require(id, list: list)
    let rows = try await store.reminders(in: list)
    _ = try session(token)
    guard try require(id, list: list) == revision else { throw BridgeFailure.denied }
    guard rows.count <= 5000 else { throw BridgeFailure.unavailable }
    // Current store membership, not the asynchronous snapshot, is authoritative.
    return rows.compactMap {
      guard let item = try? store.current($0.id), item.listID == list else { return nil }
      return item
    }
  }
  public func mutate(_ token: String, csrf: String, command: Mutation) throws -> SharedReminder? {
    let id = try session(token, csrf: csrf)
    _ = try require(id, list: command.listID, action: command.action)
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    let encoded = try encoder.encode(command)
    if let previous = clients[id]!.operations[command.operationID] {
      guard previous.0 == encoded else { throw BridgeFailure.conflict }
      return previous.1
    }
    guard !clients[id]!.uncertain.contains(command.operationID), clients[id]!.operations.count < 500
    else { throw BridgeFailure.ambiguous }
    if let fields = command.fields {
      var basic = fields
      basic.alarms = []
      basic.repeats = []
      try basic.validate()
      if fields.alarms != command.base?.fields.alarms {
        for alarm in fields.alarms { try alarm.validate() }
      }
      if fields.repeats != command.base?.fields.repeats {
        for rule in fields.repeats { try rule.validate() }
      }
    }
    let result: SharedReminder?
    // Mark before entering store: a throwing save may already have committed.
    clients[id]!.uncertain.insert(command.operationID)
    do {
      if command.action == .create {
        guard let fields = command.fields, command.itemID == nil, command.base == nil else {
          throw BridgeFailure.invalid
        }
        result = try store.create(in: command.listID, fields: fields)
      } else {
        guard let itemID = command.itemID, let base = command.base,
          base.id == itemID, base.listID == command.listID
        else { throw BridgeFailure.denied }
        var current: SharedReminder
        do { current = try store.current(itemID) } catch { throw BridgeFailure.denied }
        guard current.listID == command.listID else { throw BridgeFailure.denied }
        guard current == base else { throw BridgeFailure.conflict }
        switch command.action {
        case .create: throw BridgeFailure.invalid
        case .edit:
          guard let fields = command.fields, fields.completed == current.fields.completed else {
            throw BridgeFailure.invalid
          }
          current.fields = fields
          result = try store.save(current, replacing: base)
        case .move:
          guard let destination = command.destination else { throw BridgeFailure.invalid }
          _ = try require(id, list: destination, action: .move)
          current.listID = destination
          result = try store.save(current, replacing: base)
        case .complete, .reopen:
          current.fields.completed = command.action == .complete
          result = try store.save(current, replacing: base)
        case .delete:
          guard command.confirmation == current.fields.title else { throw BridgeFailure.invalid }
          try store.remove(current)
          result = nil
        }
      }
    } catch {
      // Validation/conflict errors are safe to correct under a new operation ID;
      // store failures remain explicitly uncertain and are never auto-retried.
      throw error
    }
    clients[id]!.operations[command.operationID] = (encoded, result)
    clients[id]!.uncertain.remove(command.operationID)
    return result
  }
  private static func secret(bytes: Int) -> String {
    var random = SystemRandomNumberGenerator()
    return (0..<bytes).map { _ in
      String(format: "%02x", UInt8.random(in: .min ... .max, using: &random))
    }.joined()
  }
  private static func digest(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}
