//
//  ArxApp.swift
//  Arx
//
//  Created by David Solis on 11/14/26.
//

import SwiftUI

@main
struct ArxApp: App {
  var body: some Scene {
    WindowGroup {
      #if os(macOS)
        ContentView()
          .frame(minWidth: 680, minHeight: 420)
      #else
        ContentView()
      #endif
    }
    #if os(macOS)
      .windowResizability(.contentMinSize)
    #endif
  }
}
