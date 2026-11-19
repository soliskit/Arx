//
//  MinimalFixtureView.swift
//  Arx
//
//  DEBUG-only minimal reproduction fixture for accessibility audit diagnosis.
//

#if DEBUG
  import SwiftUI

  /// A plain NavigationSplitView with a navigation title and default-styled
  /// text, nothing Arx-specific, rendered only when a fixture UI test passes
  /// --arx-minimal-fixture. Running the unchanged strict accessibility audit
  /// against this control view separates findings caused by Arx's own view
  /// structure from findings the audit engine or CI environment produces on
  /// any app: a Parent/Child mismatch or contrast finding that reproduces
  /// here cannot originate in Arx's views. Never compiled into Release and
  /// never reachable through the production UI.
  struct MinimalFixtureView: View {
    var body: some View {
      NavigationSplitView {
        List {
          Text("Fixture row one")
          Text("Fixture row two")
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
      } detail: {
        VStack(alignment: .leading, spacing: 20) {
          Text("Fixture detail title")
            .font(.largeTitle)
          Text("Fixture plain status text")
          Text("Fixture small caption text")
            .font(.caption)
        }
        .padding(24)
        .navigationTitle("Fixture Sharing")
      }
    }
  }
#endif
