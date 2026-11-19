//
//  MinimalFixtureView.swift
//  Arx
//
//  DEBUG-only minimal reproduction fixture for accessibility audit diagnosis.
//

#if DEBUG
  import SwiftUI

  /// A plain NavigationSplitView with a navigation title and default-styled
  /// text, rendered only when a fixture UI test passes
  /// --arx-minimal-fixture. It is the control half of a single-variable
  /// ladder for the strict audit's unresolved findings: the baseline run
  /// adds nothing Arx-specific, and each ladder step adds exactly one
  /// component from the full app behind its own launch argument (delta 1:
  /// --arx-minimal-probes installs the full app's two column accessibility
  /// probes, the only components there that mutate the AX tree). Running
  /// the unchanged strict accessibility audit against each step separates
  /// findings caused by that component from findings the audit engine or CI
  /// environment produces on any app. Never compiled into Release and never
  /// reachable through the production UI.
  struct MinimalFixtureView: View {
    /// True only when a control test passes --arx-minimal-probes: the
    /// single-delta switch that installs the full app's two column
    /// accessibility probes into this otherwise plain fixture.
    private var probesRequested: Bool {
      ProcessInfo.processInfo.arguments.contains("--arx-minimal-probes")
    }

    var body: some View {
      NavigationSplitView {
        List {
          Text("Fixture row one")
          Text("Fixture row two")
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        .background(sidebarProbe)
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
        .background(detailProbe)
      }
    }

    /// The full app's sidebar column probe when --arx-minimal-probes is
    /// passed, an empty background otherwise. ColumnAccessibilityProbe
    /// installs only in the DEBUG fixture dump configuration, so ordinary
    /// launches get an inert background either way.
    @ViewBuilder private var sidebarProbe: some View {
      if probesRequested {
        ColumnAccessibilityProbe(column: .sidebar)
      }
    }

    /// The full app's detail column probe when --arx-minimal-probes is
    /// passed, an empty background otherwise. The detail probe also runs
    /// its window-root experiment exactly as in the full app; that is part
    /// of the single "probes live" variable, not a second delta.
    @ViewBuilder private var detailProbe: some View {
      if probesRequested {
        ColumnAccessibilityProbe(column: .detail)
      }
    }
  }
#endif
