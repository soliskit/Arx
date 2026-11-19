//
//  ArxApp.swift
//  Arx
//
//  Created by David Solis on 11/14/26.
//

import SwiftUI

@main
struct ArxApp: App {
  @State private var model = BridgeViewModel()
  var body: some Scene {
    Window("Arx", id: "main") {
      #if os(macOS)
        #if DEBUG
          if minimalFixtureRequested {
            MinimalFixtureView()
          } else {
            mainContent
          }
        #else
          mainContent
        #endif
      #else
        ContentView(model: model)
      #endif
    }
    #if os(macOS)
      .windowResizability(.contentMinSize)
    #endif
  }

  #if os(macOS)
    /// The production content: the full app UI plus the DEBUG-gated view
    /// hierarchy dump hook. Defined once so the DEBUG minimal-fixture branch
    /// can bypass it without duplicating the modifier chain.
    @ViewBuilder private var mainContent: some View {
      ContentView(model: model)
        .frame(minWidth: 680, minHeight: 420)
        .onAppear { ViewHierarchyDump.runIfRequested(isFixture: model.fixture) }
    }
  #endif

  #if os(macOS) && DEBUG
    /// True only when a fixture UI test passes --arx-minimal-fixture. The
    /// minimal reproduction fixture exists for audit diagnosis only; Release
    /// builds never compile this check or the view it selects.
    private var minimalFixtureRequested: Bool {
      ProcessInfo.processInfo.arguments.contains("--arx-minimal-fixture")
    }
  #endif
}
