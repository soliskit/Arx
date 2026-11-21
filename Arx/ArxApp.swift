//
//  ArxApp.swift
//  Arx
//
//  Created by David Solis on 11/14/26.
//

import Darwin
import SwiftUI

@main
struct ArxApp: App {
  @State private var model: BridgeViewModel?
  private let sections =
    ProcessInfo.processInfo.arguments.contains("--sections-local-experiment")
    || ProcessInfo.processInfo.arguments.contains("--sections-local-fixtures")

  init() {
    if ProcessInfo.processInfo.arguments.contains("--sections-local-worker") {
      exit(ARXSectionWorker.run())
    }
    if ProcessInfo.processInfo.arguments.contains("--sections-local-helper-fixtures") {
      exit(SectionsHelperFixtureProbe.run())
    }
    let experiment =
      ProcessInfo.processInfo.arguments.contains("--sections-local-experiment")
      || ProcessInfo.processInfo.arguments.contains("--sections-local-fixtures")
    _model = State(initialValue: experiment ? nil : BridgeViewModel())
  }
  var body: some Scene {
    Window("Arx", id: "main") {
      if sections {
        SectionsExperimentView()
      } else if let model {
        ContentView(model: model).frame(minWidth: 680, minHeight: 420)
      }

    }
    #if os(macOS)
      .windowResizability(.contentMinSize)
    #endif
  }
}
