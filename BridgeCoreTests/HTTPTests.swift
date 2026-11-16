import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing

@testable import BridgeCore

struct HTTPTests {
  @Test @MainActor func realListenerAndRoutes() async throws {
    let sharing = SharingController(store: FixtureStore())
    try sharing.start()
    var rights = ClientRights()
    rights.lists = ["inbox"]
    rights.read = true
    rights.manage = true
    let (_, secret) = try sharing.pairClient(label: "HTTP fixture", rights: rights)
    let server = BridgeServer(
      sharing: sharing, configuration: try .init(origin: "https://bridge.example.com", port: 18765))
    let app = server.application()
    // .live actually binds and sends HTTP, not just a direct router dispatch.
    try await app.test(.live) { client in
      var headers = HTTPFields()
      headers[HTTPField.Name("Host")!] = "bridge.example.com"
      headers[HTTPField.Name("X-Forwarded-Proto")!] = "https"
      headers[.origin] = "https://bridge.example.com"
      headers[.contentType] = "application/json"
      try await client.execute(uri: "/", method: .get, headers: headers) { response in
        #expect(response.status == .ok)
        #expect(String(buffer: response.body).contains("Pair this browser"))
        #expect(!String(buffer: response.body).contains("Return the library book"))
        #expect(response.headers[.cacheControl] == "no-store")
        #expect(
          response.headers[HTTPField.Name("Content-Security-Policy")!]?.contains(
            "frame-ancestors 'none'") == true)
      }
      try await client.execute(uri: "/api/lists", method: .get, headers: headers) { response in
        #expect(response.status == .forbidden)
      }
      var wrongOrigin = headers
      wrongOrigin[.origin] = "https://attacker.example"
      try await client.execute(
        uri: "/api/pair", method: .post, headers: wrongOrigin,
        body: .init(string: "{\"secret\":\"\(secret)\"}")
      ) { response in #expect(response.status == .forbidden) }
      var pairHeaders = headers
      var cookie: String = ""
      try await client.execute(
        uri: "/api/pair", method: .post, headers: headers,
        body: .init(string: "{\"secret\":\"\(secret)\"}")
      ) { response in
        #expect(response.status == .ok)
        cookie = response.headers[.setCookie] ?? ""
        #expect(cookie.contains("Secure; HttpOnly; SameSite=Strict"))
        #expect(!String(buffer: response.body).contains(secret))
      }
      pairHeaders[.cookie] = String(cookie.split(separator: ";").first ?? "")
      try await client.execute(uri: "/api/lists", method: .get, headers: pairHeaders) { response in
        #expect(response.status == .ok)
        #expect(String(buffer: response.body).contains("Inbox"))
        #expect(!String(buffer: response.body).contains("Fixture account"))
        #expect(!String(buffer: response.body).contains("Weekend"))
      }
      try await client.execute(
        uri: "/api/read", method: .post, headers: pairHeaders,
        body: .init(string: "{\"listID\":\"inbox\"}")
      ) { response in #expect(response.status == .forbidden) }
      try await client.execute(
        uri: "/api/session?token=forbidden", method: .get, headers: pairHeaders
      ) { response in #expect(response.status == .forbidden) }
      var wrongHost = headers
      wrongHost[HTTPField.Name("Host")!] = "attacker.example"
      try await client.execute(uri: "/", method: .get, headers: wrongHost) { response in
        #expect(response.status == .forbidden)
      }
    }
    sharing.stop()
  }
}
