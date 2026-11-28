//
//  ArxApp.swift
//  Arx
//
//  Created by David Solis on 11/14/26.
//

import SwiftUI

@main
struct ArxApp: App {
  @State private var model: BridgeViewModel?

  init() {
    // The embedded helper and its fixture probe run before any UI exists.
    if ProcessInfo.processInfo.arguments.contains("--sections-local-worker") {
      exit(ARXSectionWorker.run())
    }
    if ProcessInfo.processInfo.arguments.contains("--sections-local-helper-fixtures") {
      exit(SectionsHelperFixtureProbe.run())
    }
    _model = State(initialValue: BridgeViewModel())
  }

  var body: some Scene {
    Window("Arx", id: "main") {
      if let model {
        #if os(macOS)
          ContentView(model: model)
            .frame(minWidth: 680, minHeight: 420)
        #else
          ContentView(model: model)
        #endif
      }
    }
    #if os(macOS)
      .windowResizability(.contentMinSize)
    #endif
  }
}
