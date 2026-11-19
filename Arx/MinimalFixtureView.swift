//
//  MinimalFixtureView.swift
//  Arx
//
//  DEBUG-only minimal reproduction fixture for accessibility audit diagnosis.
//

#if DEBUG
  import SwiftUI

  /// A NavigationSplitView control fixture for the strict audit's
  /// unresolved findings, rendered only when a fixture UI test passes
  /// --arx-minimal-fixture. It is the control half of a single-variable
  /// ladder: the baseline run adds nothing Arx-specific, and each ladder
  /// step adds exactly one component from the full app behind its own
  /// launch argument (delta 1: --arx-minimal-probes installs the two
  /// column accessibility probes; delta 2: --arx-minimal-axgroup applies
  /// the two column accessibilityElement(children: .contain) +
  /// accessibilityLabel pairs; delta 4: --arx-minimal-content replaces
  /// the plain placeholder content with a faithful replica of the full
  /// app's fixture-mode content shape, taken from ContentView.swift;
  /// delta 5: --arx-minimal-fixture-labels and --arx-minimal-real-labels
  /// isolate the column-label variable from the content variable to
  /// fill the remaining cells of the content x labels grid; delta 6:
  /// --arx-minimal-sidebar-content and --arx-minimal-detail-content
  /// bisect the content variable by column, with --arx-minimal-content
  /// kept as their union; delta 7: --arx-minimal-detail-container and
  /// --arx-minimal-detail-noscroll bisect the detail content into
  /// container structure versus box content).
  /// Running the unchanged strict accessibility audit against each step
  /// separates findings caused by that component from findings the audit
  /// engine or CI environment produces on any app. Never compiled into
  /// Release and never reachable through the production UI.
  struct MinimalFixtureView: View {
    /// True only when a control test passes --arx-minimal-probes: the
    /// single-delta switch that installs the full app's two column
    /// accessibility probes into this otherwise plain fixture.
    private var probesRequested: Bool {
      ProcessInfo.processInfo.arguments.contains("--arx-minimal-probes")
    }

    /// True only when a control test passes --arx-minimal-axgroup: the
    /// single-delta switch that adds the full app's two column
    /// accessibilityElement(children: .contain) + accessibilityLabel
    /// modifier pairs. Those are the only accessibilityElement(children:)
    /// calls in the app source (ContentView:56 and :137); every other
    /// accessibility modifier there sets an attribute (label, identifier)
    /// without restructuring containment.
    private var axGroupRequested: Bool {
      ProcessInfo.processInfo.arguments.contains("--arx-minimal-axgroup")
    }

    /// True only when a control test passes --arx-minimal-content: the
    /// single-delta switch that swaps the plain placeholder content for
    /// the full app's fixture-mode content shape. In content mode the
    /// column titles and accessibility labels default to the full app's
    /// real strings ("Lists to share", "Sharing"), not the fixture
    /// tokens - an explicit fidelity choice, so the delta-2
    /// "Fixture lists" duplicate-role finding is not expected in
    /// content-mode runs. The two label switches below can override that
    /// default in either direction to fill the 2x2 of {plain, full
    /// content} x {fixture, real labels} as separate configurations.
    private var contentRequested: Bool {
      ProcessInfo.processInfo.arguments.contains("--arx-minimal-content")
    }

    /// True only when a control test passes --arx-minimal-sidebar-content:
    /// selects the full content shape for the sidebar column only,
    /// leaving the detail column plain. --arx-minimal-content is the
    /// union of this and --arx-minimal-detail-content, preserving its
    /// delta-4 meaning, so this switch isolates the sidebar half of the
    /// content variable.
    private var sidebarContentRequested: Bool {
      ProcessInfo.processInfo.arguments.contains("--arx-minimal-sidebar-content")
    }

    /// True only when a control test passes --arx-minimal-detail-content:
    /// selects the full content shape for the detail column only,
    /// leaving the sidebar plain. Isolates the detail half of the
    /// content variable.
    private var detailContentRequested: Bool {
      ProcessInfo.processInfo.arguments.contains("--arx-minimal-detail-content")
    }

    /// True when the sidebar column renders the full content shape:
    /// the whole-content switch (union) or the sidebar half.
    private var sidebarContentActive: Bool {
      contentRequested || sidebarContentRequested
    }

    /// True when the detail column renders the full content shape:
    /// the whole-content switch (union) or the detail half.
    private var detailContentActive: Bool {
      contentRequested || detailContentRequested
    }

    /// True only when a control test passes --arx-minimal-detail-container:
    /// the detail column renders only the ScrollView container shape
    /// with the bridge title and status text, no group boxes. Isolates
    /// the container structure from the box content. Mutually exclusive
    /// with the content switches; no existing configuration changes.
    private var detailContainerRequested: Bool {
      ProcessInfo.processInfo.arguments.contains("--arx-minimal-detail-container")
    }

    /// True only when a control test passes --arx-minimal-detail-noscroll:
    /// the detail column renders the full box content in a plain VStack
    /// WITHOUT the ScrollView wrapper. Isolates the box content from the
    /// container structure. Declared caveat: without the ScrollView the
    /// long content may clip or overflow the window; that geometry
    /// difference is part of this cell, not a hidden change.
    private var detailNoScrollRequested: Bool {
      ProcessInfo.processInfo.arguments.contains("--arx-minimal-detail-noscroll")
    }

    /// True only when a control test passes --arx-minimal-fixture-labels:
    /// forces the fixture label tokens even when content mode is on, so
    /// the content+fixture-labels cell of the 2x2 runs with the label
    /// variable isolated from the content variable.
    private var fixtureLabelsRequested: Bool {
      ProcessInfo.processInfo.arguments.contains("--arx-minimal-fixture-labels")
    }

    /// True only when a control test passes --arx-minimal-real-labels:
    /// forces the full app's real column labels on plain placeholder
    /// content, so the plain-content+real-labels cell of the 2x2 runs
    /// with the label variable isolated from the content variable.
    private var realLabelsRequested: Bool {
      ProcessInfo.processInfo.arguments.contains("--arx-minimal-real-labels")
    }

    /// The single label decision for both columns: real labels when
    /// explicitly requested, or in content mode unless fixture labels
    /// are explicitly forced; fixture tokens otherwise.
    private var useRealLabels: Bool {
      realLabelsRequested || (contentRequested && !fixtureLabelsRequested)
    }

    private var sidebarColumnLabel: String {
      useRealLabels ? "Lists to share" : "Fixture lists"
    }

    private var detailColumnLabel: String {
      useRealLabels ? "Sharing" : "Fixture Sharing"
    }

    @State private var highlighted: String?
    @State private var grantedLists: Set<String> = []
    @State private var origin = ""
    @State private var port = "8765"
    @State private var clientLabel = "Browser client"
    @State private var rightsRead = false
    @State private var rightsManage = false
    @State private var rightsDelete = false

    /// The fixture store's four collections, mirrored from
    /// BridgeCore/FixtureStore.swift so the content replica's rows match
    /// the full app's fixture rows exactly.
    private struct FixtureList: Identifiable {
      let id: String
      let title: String
      let source: String
      let writable: Bool
    }

    private static let fixtureLists = [
      FixtureList(id: "inbox", title: "Inbox", source: "Fixture account", writable: true),
      FixtureList(id: "weekend", title: "Weekend", source: "Fixture account", writable: true),
      FixtureList(id: "later", title: "Later", source: "Fixture account", writable: true),
      FixtureList(id: "readonly", title: "Read-only list", source: "", writable: false),
    ]

    var body: some View {
      NavigationSplitView {
        sidebarColumn
          .modifier(
            ColumnAXGroup(
              label: sidebarColumnLabel,
              enabled: axGroupRequested)
          )
          .background(sidebarProbe)
      } detail: {
        detailColumn
          .modifier(
            ColumnAXGroup(
              label: detailColumnLabel,
              enabled: axGroupRequested)
          )
          .background(detailProbe)
      }
    }

    @ViewBuilder private var sidebarColumn: some View {
      if sidebarContentActive {
        contentSidebar
      } else {
        plainSidebar
      }
    }

    @ViewBuilder private var detailColumn: some View {
      if detailContentActive {
        contentDetail
      } else if detailContainerRequested {
        containerDetail
      } else if detailNoScrollRequested {
        noScrollDetail
      } else {
        plainDetail
      }
    }

    /// The plain control content: two rows, three default-styled texts,
    /// nothing Arx-specific.
    private var plainSidebar: some View {
      List {
        Text("Fixture row one")
        Text("Fixture row two")
      }
      .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
    }

    private var plainDetail: some View {
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

    /// Faithful replica of the full app's fixture-mode sidebar
    /// (ContentView.swift:17-54, connected fixture path): the banner
    /// capsule, the grant-list rows with their labels and identifiers,
    /// and the Refresh button. All state is local and static during the
    /// audit; no model, store or notification is involved.
    @ViewBuilder private var contentSidebar: some View {
      VStack(alignment: .leading, spacing: 12) {
        Text("Fixture data - no real Reminders access")
          .font(.caption)
          .foregroundStyle(Color(nsColor: .labelColor))
          .padding(.horizontal, 6)
          .padding(.vertical, 2)
          .background(.background, in: .capsule)
        List(Self.fixtureLists, selection: $highlighted) { list in
          Toggle(
            isOn: Binding(
              get: { grantedLists.contains(list.id) },
              set: { enabled in
                if enabled {
                  grantedLists.insert(list.id)
                } else {
                  grantedLists.remove(list.id)
                }
              })
          ) {
            VStack(alignment: .leading) {
              Text(list.title)
              Text(list.source + (list.writable ? "" : " · Read-only"))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }
          .accessibilityLabel(list.title)
          .accessibilityIdentifier("list-grant-" + list.id)
          .tag(list.id)
        }
        Button("Refresh lists") {}
      }
      .padding()
      .navigationTitle("Lists to share")
      .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
    }

    /// Faithful replica of the full app's fixture-mode detail column
    /// (ContentView.swift:60-135): the bridge title and status text, and
    /// the three group boxes with their controls, with the same disabled
    /// states the fixture model produces (connected, never running).
    /// The ScrollView container shape holding only the bridge title
    /// and status text, no group boxes (the --arx-minimal-detail-container
    /// cell): the container structure with simple text, nothing else
    /// from the box content.
    @ViewBuilder private var containerDetail: some View {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          Text("Arx bridge")
            .font(.largeTitle)
          Text("Choose lists and actions for a new client. Highlighting a list does not share it.")
            .foregroundStyle(Color(nsColor: .labelColor))
            .accessibilityIdentifier("bridge-status")
        }
        .padding(24)
        .frame(maxWidth: 760, alignment: .leading)
      }
      .navigationTitle("Sharing")
    }

    /// The full box content in a plain VStack WITHOUT the ScrollView
    /// wrapper (the --arx-minimal-detail-noscroll cell): identical box
    /// content to contentDetail, container structure removed. The
    /// declared geometry caveat lives on detailNoScrollRequested.
    @ViewBuilder private var noScrollDetail: some View {
      detailBoxContent
        .navigationTitle("Sharing")
    }

    @ViewBuilder private var contentDetail: some View {
      ScrollView {
        detailBoxContent
      }
      .navigationTitle("Sharing")
    }

    /// The inner box content of the detail replica, shared verbatim by
    /// contentDetail (inside the ScrollView) and noScrollDetail (without
    /// it) so the two cells differ by exactly the container.
    @ViewBuilder private var detailBoxContent: some View {
      VStack(alignment: .leading, spacing: 20) {
        Text("Arx bridge")
          .font(.largeTitle)
        Text("Choose lists and actions for a new client. Highlighting a list does not share it.")
          .foregroundStyle(Color(nsColor: .labelColor))
          .accessibilityIdentifier("bridge-status")
        GroupBox("Connection") {
          VStack(alignment: .leading, spacing: 10) {
            TextField("Exact remote HTTPS origin", text: $origin)
              .textContentType(.URL)
            TextField("Local port", text: $port)
            Text("Keep the Mac, Arx and your connector running.")
              .font(.caption)
              .foregroundStyle(.primary)
            HStack {
              Button("Start bridge") {}
                .accessibilityIdentifier("bridge-start")
              Button("Stop all sharing", role: .destructive) {}
                .accessibilityIdentifier("bridge-stop")
                .disabled(true)
            }
          }
          .padding(6)
        }
        GroupBox("New client") {
          VStack(alignment: .leading, spacing: 10) {
            TextField("Client label", text: $clientLabel)
            Toggle("Read selected lists", isOn: $rightsRead)
            Toggle("Create, edit, move, complete and reopen", isOn: $rightsManage)
              .disabled(!rightsRead)
            Toggle("Delete reminders with confirmation", isOn: $rightsDelete)
              .disabled(!rightsRead)
            Text(
              "Select this new client's access. To change an existing client, revoke and pair again."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            Button("Create single-use pairing secret") {}
              .disabled(true)
          }
          .padding(6)
        }
        GroupBox("Clients") {
          VStack(alignment: .leading, spacing: 8) {
            Button("Refresh client status") {}
            Text("No client has access.")
              .foregroundStyle(.secondary)
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(6)
        }
        Text("Revoke stops new requests. Data already viewed and changes already saved remain.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(24)
      .frame(maxWidth: 760, alignment: .leading)
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

    /// Applies the full app's column modifier pair -
    /// accessibilityElement(children: .contain) plus accessibilityLabel,
    /// the only accessibilityElement(children:) calls in the app source -
    /// only when the --arx-minimal-axgroup switch is on; otherwise the
    /// content passes through untouched.
    private struct ColumnAXGroup: ViewModifier {
      let label: String
      let enabled: Bool

      @ViewBuilder func body(content: Content) -> some View {
        if enabled {
          content
            .accessibilityElement(children: .contain)
            .accessibilityLabel(label)
        } else {
          content
        }
      }
    }
  }
#endif
