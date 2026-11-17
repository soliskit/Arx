//
//  BridgeServer.swift
//  Arx
//
//  Created by David Solis on 11/15/26.
//

import Foundation
import HTTPTypes
import Hummingbird
import Logging

public struct BridgeConfiguration: Sendable {
  public let origin: String
  public let host: String
  public let port: Int
  public init(origin: String, port: Int = 8765) throws {
    guard let url = URL(string: origin), url.scheme == "https", let host = url.host,
      url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
      url.path.isEmpty || url.path == "/", (1024...65535).contains(port),
      !host.contains(":"), !host.contains("localhost"), host != "127.0.0.1"
    else { throw BridgeFailure.invalid }
    let authority = host.lowercased() + (url.port.map { ":\($0)" } ?? "")
    self.origin = "https://" + authority
    self.host = authority
    self.port = port
  }
}

public struct BridgeServer: Sendable {
  let sharing: SharingController
  public let configuration: BridgeConfiguration
  public init(sharing: SharingController, configuration: BridgeConfiguration) {
    self.sharing = sharing
    self.configuration = configuration
  }
  public func application(onRunning: @escaping @Sendable () async -> Void = {})
    -> some ApplicationProtocol
  {
    let router = Router()
    for path in ["/", "/app.js", "/style.css", "/api/session", "/api/lists"] {
      router.get(RouterPath(path)) { request, _ in await handle(request) }
    }
    for path in ["/api/pair", "/api/read", "/api/mutate"] {
      router.post(RouterPath(path)) { request, _ in await handle(request) }
    }
    var logger = Logger(label: "ArxBridge")
    logger.logLevel = .critical  // no request/body/auth data in routine logs
    return Application(
      router: router,
      configuration: .init(
        address: .hostname("127.0.0.1", port: configuration.port), backlog: 32, reuseAddress: false),
      onServerRunning: { _ in await onRunning() }, logger: logger)
  }
  public func run(onRunning: @escaping @Sendable () async -> Void = {}) async throws {
    try await application(onRunning: onRunning).runService()
  }
  private struct PairRequest: Decodable { var secret: String }
  private struct ReadRequest: Decodable {
    var listID: String
    var after: String?
    var before: String?
  }
  private struct SessionResponse: Encodable {
    var rights: ClientRights
    var csrf: String
  }
  private struct ErrorResponse: Encodable { var error: String }
  private struct WriteResponse: Encodable { var reminder: SharedReminder? }
  private func header(_ name: String, _ request: Request) -> String? {
    guard let field = HTTPField.Name(name) else { return nil }
    return request.headers[field]
  }
  private func handle(_ request: Request) async -> Response {
    do {
      guard request.head.authority?.lowercased() == configuration.host,
        header("Host", request) == nil,
        header("X-Forwarded-Proto", request) == "https",
        request.uri.query == nil
      else { throw BridgeFailure.denied }
      if let origin = header("Origin", request), origin != configuration.origin {
        throw BridgeFailure.denied
      }
      let path = request.uri.path
      if request.method == .get, ["/", "/app.js", "/style.css"].contains(path) {
        let name = path == "/" ? "index.html" : String(path.dropFirst())
        guard
          let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Web"),
          let data = try? Data(contentsOf: url)
        else { throw BridgeFailure.unavailable }
        return response(
          .ok, data: data,
          contentType: path == "/"
            ? "text/html; charset=utf-8"
            : path == "/app.js" ? "text/javascript; charset=utf-8" : "text/css; charset=utf-8")
      }
      if request.method == .post {
        guard header("Origin", request) == configuration.origin,
          header("Content-Type", request)?.lowercased() == "application/json"
        else { throw BridgeFailure.denied }
      }
      if path == "/api/pair" {
        let pair: PairRequest = try await decode(request)
        let state = try await sharing.exchange(pair.secret)
        var result = try json(
          SessionResponse(
            rights: try await sharing.sessionState(state.token).rights, csrf: state.csrf))
        result.headers[.setCookie] =
          "__Host-arx=\(state.token); Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age=86400"
        return result
      }
      let cookies =
        header("Cookie", request)?.split(separator: ";").map {
          $0.trimmingCharacters(in: .whitespaces)
        } ?? []
      let matching = cookies.filter { $0.hasPrefix("__Host-arx=") }
      guard matching.count == 1 else { throw BridgeFailure.denied }
      let token = String(matching[0].dropFirst("__Host-arx=".count))
      if path == "/api/session" {
        let state = try await sharing.sessionState(token)
        return try json(SessionResponse(rights: state.rights, csrf: state.csrf))
      }
      if path == "/api/lists" { return try json(try await sharing.sharedLists(token)) }
      // Read is POST so list identifiers don't enter access-log URLs/history.
      if path == "/api/read" {
        let input: ReadRequest = try await decode(request)
        guard header("X-CSRF-Token", request) == (try await sharing.sessionState(token)).csrf else {
          throw BridgeFailure.denied
        }
        return try json(
          try await sharing.read(
            token, list: input.listID, after: input.after, before: input.before))
      }
      if path == "/api/mutate" {
        guard header("X-CSRF-Token", request) == (try await sharing.sessionState(token)).csrf else {
          throw BridgeFailure.denied
        }
        let command: Mutation = try await decode(request, limit: 1_048_576)
        return try json(
          WriteResponse(
            reminder: try await sharing.mutate(
              token, csrf: header("X-CSRF-Token", request) ?? "", command: command)))
      }
      throw BridgeFailure.denied
    } catch {
      let status: HTTPResponse.Status
      let message: String
      switch error {
      case BridgeFailure.conflict:
        status = .conflict
        message = "This reminder changed. Refresh and review before trying again."
      case BridgeFailure.invalid:
        status = .badRequest
        message = "Check the fields and confirmation."
      case BridgeFailure.ambiguous:
        status = .conflict
        message =
          "Result uncertain. Refresh and check Reminders. Do not repeat this operation blindly."
      case BridgeFailure.tooLarge:
        status = .contentTooLarge
        message =
          "This reminder request exceeds 1 MiB, including its original copy. Shorten the notes."
      case BridgeFailure.rateLimited:
        status = .tooManyRequests
        message = "Requests temporarily limited. Try later."
      case BridgeFailure.unavailable:
        status = .serviceUnavailable
        message = "The store or bridge is unavailable."
      default:
        status = .forbidden
        message = "Access unavailable. Refresh or pair again."
      }
      return (try? json(ErrorResponse(error: message), status: status))
        ?? response(.internalServerError, data: Data())
    }
  }
  private func decode<T: Decodable>(_ request: Request, limit: Int = 65_536) async throws -> T {
    let body: ByteBuffer
    do {
      body = try await request.body.collect(upTo: limit)
    } catch {
      if limit == 1_048_576,
        let error = error as? any HTTPResponseError, error.status == .contentTooLarge
      {
        throw BridgeFailure.tooLarge
      }
      throw error
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    // A body that does not parse is a bad request, not a lost session.
    do { return try decoder.decode(T.self, from: Data(body.readableBytesView)) } catch {
      throw BridgeFailure.invalid
    }
  }
  private func json<T: Encodable>(_ value: T, status: HTTPResponse.Status = .ok) throws -> Response
  {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return response(status, data: try encoder.encode(value))
  }
  private func response(
    _ status: HTTPResponse.Status, data: Data, contentType: String = "application/json"
  ) -> Response {
    var fields = HTTPFields()
    for (name, value) in [
      ("Content-Type", contentType), ("Cache-Control", "no-store"),
      ("X-Content-Type-Options", "nosniff"),
      (
        "Content-Security-Policy",
        "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'"
      ),
      ("Referrer-Policy", "no-referrer"), ("X-Frame-Options", "DENY"),
    ] { fields[HTTPField.Name(name)!] = value }
    return Response(status: status, headers: fields, body: .init(byteBuffer: .init(bytes: data)))
  }
}
