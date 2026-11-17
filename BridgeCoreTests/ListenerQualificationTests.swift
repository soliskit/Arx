// Fixture-only lifecycle qualification. Records restart behavior; does not change socket policy.
import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing

@testable import BridgeCore

@MainActor private final class ListenerState {
  var ready = false
  var result: String?
}
@MainActor struct ListenerQualificationTests {
  private func launch(_ port: Int) throws -> (Task<Void, Never>, ListenerState, SharingController) {
    let c = SharingController(store: FixtureStore())
    try c.start()
    let server = BridgeServer(
      sharing: c, configuration: try .init(origin: "https://bridge.example.com", port: port))
    let state = ListenerState()
    let task = Task { @MainActor in
      do {
        try await server.run { await MainActor.run { state.ready = true } }
        state.result = "returned"
      } catch { state.result = String(describing: error) }
    }
    return (task, state, c)
  }
  private func settle(_ state: ListenerState) async throws {
    for _ in 0..<100 where !state.ready && state.result == nil {
      try await Task.sleep(for: .milliseconds(50))
    }
  }
  @Test func recordsOpenConnectionRestartAndRequiresExclusivePort() async throws {
    // Fresh random port avoids contaminating another test with Linux TIME_WAIT.
    let port = Int.random(in: 20000...60000)
    let (first, firstState, firstSharing) = try launch(port)
    do {
      try await settle(firstState)
      try #require(firstState.ready, "Qualification listener did not start")
      let (second, secondState, secondSharing) = try launch(port)
      do {
        try await settle(secondState)
        #expect(!secondState.ready)
        #expect(secondState.result?.contains("Address already in use") == true)
      } catch {
        second.cancel()
        await second.value
        secondSharing.stop()
        throw error
      }
      second.cancel()
      await second.value
      secondSharing.stop()
      let client = TestClient(host: "127.0.0.1", port: port)
      client.connect()
      do {
        var headers = HTTPFields()
        headers[HTTPField.Name("X-Forwarded-Proto")!] = "https"
        let response = try await client.execute(
          .init("/", method: .get, authority: "bridge.example.com", headers: headers, body: nil))
        #expect(response.status == .ok)
        // Stop with the keep-alive connection open, as in the reported failure.
        first.cancel()
        await first.value
        firstSharing.stop()
      } catch {
        try? await client.shutdown()
        throw error
      }
      try? await client.shutdown()
      let (restart, restartState, restartSharing) = try launch(port)
      do {
        try await settle(restartState)
        let addressBusy = restartState.result?.contains("Address already in use") == true
        #expect(restartState.ready || addressBusy)
        print(
          "LISTENER QUALIFICATION: exclusive bind refused; immediate open-client restart="
            + (restartState.ready ? "ready" : "address-in-use; NOT FIXED")
            + "; reuseAddress remains false; fixture only")
      } catch {
        restart.cancel()
        await restart.value
        restartSharing.stop()
        throw error
      }
      restart.cancel()
      await restart.value
      restartSharing.stop()
    } catch {
      first.cancel()
      await first.value
      firstSharing.stop()
      throw error
    }
    first.cancel()
    await first.value
    firstSharing.stop()
  }
}
