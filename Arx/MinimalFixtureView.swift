//
//  MinimalFixtureView.swift
//  Arx
//
//  DEBUG-only minimal reproduction fixture for accessibility audit diagnosis.
//

#if DEBUG
  import AppKit
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
  /// container structure versus box content; delta 8:
  /// --arx-minimal-detail-boxes and --arx-minimal-detail-texts split
  /// the box content into group boxes versus texts, same no-scroll
  /// family; delta 9: --arx-minimal-detail-box-connection,
  /// --arx-minimal-detail-box-new-client and
  /// --arx-minimal-detail-box-clients reduce the reproducing boxes
  /// cell to one group box each, same no-scroll family; delta 10:
  /// --arx-minimal-connection-chrome (GroupBox chrome with inert
  /// content, a new composition) and --arx-minimal-connection-contents
  /// (the connection box's exact contents without the chrome, a
  /// verbatim reduction) split chrome versus contents inside the
  /// reproducing connection box; delta 11:
  /// --arx-minimal-connection-fields and
  /// --arx-minimal-connection-caption-buttons reduce the reproducing
  /// contents cell to its verbatim fields versus caption-plus-buttons
  /// pieces, same inner shape and family; delta 12:
  /// --arx-minimal-connection-origin-field and
  /// --arx-minimal-connection-port-field reduce the reproducing fields
  /// cell to one verbatim text field each, same inner shape and
  /// family; delta 13: --arx-minimal-connection-origin-no-content-type
  /// renders the origin field identical except for the removed
  /// .textContentType(.URL) modifier, contrasted same-run with the
  /// origin-field cell, and --arx-minimal-new-client-label-field
  /// renders the existing client-label field alone in its own
  /// new-client inner shape, a verbatim reduction of the new-client
  /// box cell, and --arx-minimal-new-client-read-toggle renders the
  /// existing Read selected lists Toggle alone in the same new-client
  /// inner shape, a second verbatim reduction of that box cell;
  /// delta 14: --arx-minimal-connection-origin-field-unfocused
  /// renders the verbatim origin-field cell while displacing the
  /// window's first responder to nil, a same-control contrast on
  /// keyboard focus against the origin-field cell);
  /// delta 15: --arx-minimal-connection-origin-field-late-unfocused
  /// renders the verbatim origin-field cell while displacing the
  /// window's first responder only after the first-responder
  /// descriptor phases complete, a timing contrast against both the
  /// origin-field cell and the early-unfocused cell).
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

    /// True only when a control test passes --arx-minimal-detail-boxes:
    /// the detail column renders only the three group boxes of the box
    /// content in the same no-scroll VStack family. Isolates the boxes
    /// from the texts. Mutually exclusive with the other content
    /// switches; no existing configuration changes.
    private var detailBoxesRequested: Bool {
      ProcessInfo.processInfo.arguments.contains("--arx-minimal-detail-boxes")
    }

    /// True only when a control test passes --arx-minimal-detail-texts:
    /// the detail column renders only the title, status and revoke
    /// caption texts in the same no-scroll VStack family. Isolates the
    /// texts from the boxes.
    private var detailTextsRequested: Bool {
      ProcessInfo.processInfo.arguments.contains("--arx-minimal-detail-texts")
    }

    /// True only when a control test passes
    /// --arx-minimal-detail-box-connection: the detail column renders
    /// only the connection group box in the same no-scroll VStack
    /// family. One-box reduction of the delta-8a boxes cell.
    private var detailBoxConnectionRequested: Bool {
      ProcessInfo.processInfo.arguments.contains("--arx-minimal-detail-box-connection")
    }

    /// True only when a control test passes
    /// --arx-minimal-detail-box-new-client: the detail column renders
    /// only the new-client group box in the same no-scroll VStack
    /// family. One-box reduction of the delta-8a boxes cell.
    private var detailBoxNewClientRequested: Bool {
      ProcessInfo.processInfo.arguments.contains("--arx-minimal-detail-box-new-client")
    }

    /// True only when a control test passes
    /// --arx-minimal-detail-box-clients: the detail column renders only
    /// the clients group box in the same no-scroll VStack family.
    /// One-box reduction of the delta-8a boxes cell.
    private var detailBoxClientsRequested: Bool {
      ProcessInfo.processInfo.arguments.contains("--arx-minimal-detail-box-clients")
    }

    /// True only when a control test passes
    /// --arx-minimal-connection-chrome: the detail column renders a
    /// GroupBox("Connection") chrome wrapping one default-styled
    /// placeholder text, in the same no-scroll VStack family. This is a
    /// NEW COMPOSITION (the chrome has never carried inert content in
    /// any prior cell), not a reduction of an existing cell.
    private var connectionChromeRequested: Bool {
      ProcessInfo.processInfo.arguments.contains("--arx-minimal-connection-chrome")
    }

    /// True only when a control test passes
    /// --arx-minimal-connection-contents: the detail column renders the
    /// connection box's exact inner contents with NO GroupBox chrome,
    /// in the same no-scroll VStack family. Reduction of the
    /// reproducing delta-9a cell: it shares connectionBoxContent
    /// verbatim with connectionBox.
    private var connectionContentsRequested: Bool {
      ProcessInfo.processInfo.arguments.contains("--arx-minimal-connection-contents")
    }

    /// True only when a control test passes
    /// --arx-minimal-connection-fields: the detail column renders only
    /// the two connection text fields in the same inner shape and
    /// no-scroll family wrapper. Reduction of the reproducing
    /// delta-10b contents cell.
    private var connectionFieldsRequested: Bool {
      ProcessInfo.processInfo.arguments.contains("--arx-minimal-connection-fields")
    }

    /// True only when a control test passes
    /// --arx-minimal-connection-caption-buttons: the detail column
    /// renders only the connection caption and button row in the same
    /// inner shape and no-scroll family wrapper. Reduction of the
    /// reproducing delta-10b contents cell.
    private var connectionCaptionButtonsRequested: Bool {
      ProcessInfo.processInfo.arguments.contains("--arx-minimal-connection-caption-buttons")
    }

    /// True only when a control test passes
    /// --arx-minimal-connection-origin-field: the detail column renders
    /// only the connection origin text field in the same inner shape
    /// and no-scroll family wrapper. Reduction of the reproducing
    /// delta-11a fields cell.
    private var connectionOriginFieldRequested: Bool {
      ProcessInfo.processInfo.arguments.contains("--arx-minimal-connection-origin-field")
    }

    /// True only when a control test passes
    /// --arx-minimal-connection-port-field: the detail column renders
    /// only the connection port text field in the same inner shape and
    /// no-scroll family wrapper. Reduction of the reproducing
    /// delta-11a fields cell.
    private var connectionPortFieldRequested: Bool {
      ProcessInfo.processInfo.arguments.contains("--arx-minimal-connection-port-field")
    }

    /// True only when a control test passes
    /// --arx-minimal-connection-origin-no-content-type: the detail
    /// column renders the connection origin text field identical
    /// except for the removed .textContentType(.URL) modifier, in the
    /// same inner shape and no-scroll family wrapper. Same-run
    /// contrast with the reproducing delta-12a origin-field cell.
    private var connectionOriginNoContentTypeRequested: Bool {
      ProcessInfo.processInfo.arguments.contains("--arx-minimal-connection-origin-no-content-type")
    }

    /// True only when a control test passes
    /// --arx-minimal-new-client-label-field: the detail column renders
    /// only the new-client box's existing client-label text field in
    /// that box's own inner shape and the no-scroll family wrapper.
    /// Reduction of the reproducing delta-9b new-client box cell.
    private var newClientLabelFieldRequested: Bool {
      ProcessInfo.processInfo.arguments.contains("--arx-minimal-new-client-label-field")
    }

    /// True only when a control test passes
    /// --arx-minimal-new-client-read-toggle: the detail column renders
    /// only the new-client box's existing Read selected lists Toggle
    /// in that box's own inner shape and the no-scroll family wrapper.
    /// A second reduction of the reproducing delta-9b new-client box
    /// cell, contrasting control type against the field cells.
    private var newClientReadToggleRequested: Bool {
      ProcessInfo.processInfo.arguments.contains("--arx-minimal-new-client-read-toggle")
    }

    /// True only when a control test passes
    /// --arx-minimal-connection-origin-field-unfocused: the detail
    /// column renders the verbatim delta-12a origin-field cell while
    /// the window's first responder is displaced to nil, so the only
    /// intended difference from the origin-field cell at audit time is
    /// the field's Keyboard Focused attribute. The displacement is
    /// verified per run by the app-side first-responder descriptor
    /// prints and the window render, plus the tree comparison when a
    /// mismatch dump exists; without that evidence the cell is
    /// invalid, not negative.
    private var connectionOriginFieldUnfocusedRequested: Bool {
      ProcessInfo.processInfo.arguments.contains("--arx-minimal-connection-origin-field-unfocused")
    }

    /// True only when a control test passes
    /// --arx-minimal-connection-origin-field-late-unfocused: the detail
    /// column renders the verbatim delta-12a origin-field cell while
    /// the window's first responder is displaced to nil only after the
    /// descriptor phases (0/0.5/1.0s) complete, so its recorded
    /// descriptor triplet matches the focused origin-field cell while
    /// the audit itself runs displaced. The per-run descriptor file
    /// proves the displacement timing; without it the cell is
    /// invalid, not negative.
    private var connectionOriginFieldLateUnfocusedRequested: Bool {
      ProcessInfo.processInfo.arguments.contains(
        "--arx-minimal-connection-origin-field-late-unfocused")
    }

    /// True only when a control test passes
    /// --arx-minimal-caption-context-plain: the detail column renders
    /// the single caption text of the matched caption-context pair in
    /// its plain (no GroupBox) context half, at fixed coordinates
    /// shared with the GroupBox half.
    private var captionContextPlainRequested: Bool {
      ProcessInfo.processInfo.arguments.contains("--arx-minimal-caption-context-plain")
    }

    /// True only when a control test passes
    /// --arx-minimal-caption-context-groupbox: the detail column
    /// renders the SAME caption text of the matched caption-context
    /// pair inside GroupBox("Connection") containment, the pair's
    /// GroupBox context half, with the text at the same fixed
    /// coordinates as the plain half.
    private var captionContextGroupBoxRequested: Bool {
      ProcessInfo.processInfo.arguments.contains("--arx-minimal-caption-context-groupbox")
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
      .onAppear(perform: recordFirstResponderPhases)
    }

    /// Additive observation (delta 14 repair): record the key window's
    /// first responder as a STABLE descriptor at three short delays,
    /// for every cell, so the focus state near audit time is comparable
    /// across runs and across the displacement boundary. Observation
    /// only, never an assertion; the descriptor is a fixed token
    /// ("no-key-window", "none", or "window" when the window itself is
    /// the responder) or the responder's class name - never an
    /// address, frame or label. A focused text field typically reports
    /// AppKit's shared field editor (NSTextView); displaced focus
    /// reports the window or no useful responder. Interpretation
    /// stays observation: the tree's Keyboard Focused attribute
    /// remains the per-element evidence. The late-unfocused cell
    /// (delta 15) extends the schedule with three post-displacement
    /// phases at 1.5/2.0/2.5s, each landing 0.25s after a
    /// displacement fire, so a successful persistent displacement
    /// shows as "window" on all three; its file holds six lines.
    private func recordFirstResponderPhases() {
      // Observability repair (c3/c4): the job log never carries the app
      // process's stdout, so the same descriptors are also handed over
      // through a per-launch nonce-named file. The write side uses only
      // FileManager.default.temporaryDirectory, which Foundation
      // resolves for the current user; where it lands depends on
      // whether this build runs sandboxed, and no location is asserted
      // here. The test side checks its own deterministic candidates
      // and treats absence at every candidate as INVALID, never
      // negative. The nonce arrives via launch environment and is
      // shape-checked; the file holds only these fixed synthetic
      // descriptor lines.
      let phasesFile: URL? = {
        guard let nonce = ProcessInfo.processInfo.environment["ARX_RESPONDER_PHASES_NONCE"],
          nonce.range(of: "^[0-9A-Fa-f-]{36}$", options: .regularExpression) != nil
        else { return nil }
        return FileManager.default.temporaryDirectory
          .appendingPathComponent("arx-responder-phases-\(nonce).txt")
      }()
      // The late-unfocused cell (delta 15) adds three post-fire
      // observation phases: each lands 0.25s after a displacement
      // fire (1.25/1.75/2.25s), so it observes the outcome of its
      // own fire rather than the fire itself. Six lines total.
      let phaseDelays: [Double] =
        connectionOriginFieldLateUnfocusedRequested
        ? [0.0, 0.5, 1.0, 1.5, 2.0, 2.5] : [0.0, 0.5, 1.0]
      for (index, delay) in phaseDelays.enumerated() {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
          guard let window = NSApplication.shared.keyWindow else {
            print("pre-audit-first-responder-\(index): no-key-window")
            Self.writePhase(index, descriptor: "no-key-window", to: phasesFile)
            return
          }
          let descriptor: String
          if let responder = window.firstResponder {
            descriptor =
              responder === window
              ? "window" : String(describing: type(of: responder))
          } else {
            descriptor = "none"
          }
          print("pre-audit-first-responder-\(index): \(descriptor)")
          Self.writePhase(index, descriptor: descriptor, to: phasesFile)
        }
      }
    }

    /// Phases fire in order on the main queue, so this read-modify-write is
    /// serialized; the atomic write means a reader sees either a complete
    /// prefix or nothing, and a short file is always INVALID.
    private static func writePhase(_ index: Int, descriptor: String, to file: URL?) {
      guard let file else { return }
      let existing = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
      try? (existing + "pre-audit-first-responder-\(index): \(descriptor)\n")
        .write(to: file, atomically: true, encoding: .utf8)
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
      } else if detailBoxesRequested {
        boxesDetail
      } else if detailTextsRequested {
        textsDetail
      } else if detailBoxConnectionRequested {
        connectionBoxDetail
      } else if detailBoxNewClientRequested {
        newClientBoxDetail
      } else if detailBoxClientsRequested {
        clientsBoxDetail
      } else if connectionChromeRequested {
        connectionChromeDetail
      } else if connectionContentsRequested {
        connectionContentsDetail
      } else if connectionFieldsRequested {
        connectionFieldsDetail
      } else if connectionCaptionButtonsRequested {
        connectionCaptionButtonsDetail
      } else if connectionOriginFieldRequested {
        connectionOriginFieldDetail
      } else if connectionPortFieldRequested {
        connectionPortFieldDetail
      } else if connectionOriginNoContentTypeRequested {
        connectionOriginNoContentTypeDetail
      } else if newClientLabelFieldRequested {
        newClientLabelFieldDetail
      } else if newClientReadToggleRequested {
        newClientReadToggleDetail
      } else if connectionOriginFieldUnfocusedRequested {
        connectionOriginFieldUnfocusedDetail
      } else if connectionOriginFieldLateUnfocusedRequested {
        connectionOriginFieldLateUnfocusedDetail
      } else if captionContextPlainRequested {
        captionContextPlainDetail
      } else if captionContextGroupBoxRequested {
        captionContextGroupBoxDetail
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

    /// Delta 16a of the ladder: the plain half of the matched
    /// caption-context pair. The text is the verbatim failing caption
    /// from plainDetail (same string, font and default foreground),
    /// mounted alone so its frame is deterministic. The transparent
    /// spacers replicate the GroupBox title region and content insets
    /// measured from the connection-chrome cell's render (24pt title
    /// region above the text, 6pt leading inset), so the text's frame
    /// matches the GroupBox half's content frame BY CONSTRUCTION;
    /// the UI test still records the actual frame, and any mismatch
    /// makes the comparison inconclusive, never negative.
    @ViewBuilder private var captionContextPlainDetail: some View {
      VStack(alignment: .leading, spacing: 0) {
        Color.clear.frame(height: 24)
        HStack(alignment: .top, spacing: 0) {
          Color.clear.frame(width: 6)
          Text("Fixture small caption text")
            .font(.caption)
            .accessibilityIdentifier("caption-context-target")
        }
      }
      .padding(24)
      .frame(maxWidth: 760, maxHeight: .infinity, alignment: .topLeading)
      .navigationTitle("Fixture Sharing")
    }

    /// Delta 16b of the ladder: the GroupBox half of the matched
    /// caption-context pair. The SAME text element sits inside
    /// GroupBox("Connection") containment - the context that carries
    /// the passing caption neighbor in the full app and fixture
    /// replica. Same wrapper, same coordinates as the plain half; the
    /// only intended difference is the immediate container context.
    @ViewBuilder private var captionContextGroupBoxDetail: some View {
      VStack(alignment: .leading, spacing: 0) {
        GroupBox("Connection") {
          Text("Fixture small caption text")
            .font(.caption)
            .accessibilityIdentifier("caption-context-target")
        }
      }
      .padding(24)
      .frame(maxWidth: 760, maxHeight: .infinity, alignment: .topLeading)
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
          bridgeTitle
          bridgeStatus
        }
        .padding(24)
        .frame(maxWidth: 760, alignment: .leading)
      }
      .navigationTitle("Sharing")
    }

    /// The three group boxes alone in the no-scroll VStack family (the
    /// --arx-minimal-detail-boxes cell): box structure without the
    /// title, status or revoke caption.
    @ViewBuilder private var boxesDetail: some View {
      VStack(alignment: .leading, spacing: 20) {
        connectionBox
        newClientBox
        clientsBox
      }
      .padding(24)
      .frame(maxWidth: 760, alignment: .leading)
      .navigationTitle("Sharing")
    }

    /// The texts alone in the no-scroll VStack family (the
    /// --arx-minimal-detail-texts cell): title, status and revoke
    /// caption without any group box.
    @ViewBuilder private var textsDetail: some View {
      VStack(alignment: .leading, spacing: 20) {
        bridgeTitle
        bridgeStatus
        revokeCaption
      }
      .padding(24)
      .frame(maxWidth: 760, alignment: .leading)
      .navigationTitle("Sharing")
    }

    /// The connection group box alone in the no-scroll VStack family
    /// (the --arx-minimal-detail-box-connection cell): the same wrapper
    /// as boxesDetail, reduced to this one box.
    @ViewBuilder private var connectionBoxDetail: some View {
      VStack(alignment: .leading, spacing: 20) {
        connectionBox
      }
      .padding(24)
      .frame(maxWidth: 760, alignment: .leading)
      .navigationTitle("Sharing")
    }

    /// The new-client group box alone in the no-scroll VStack family
    /// (the --arx-minimal-detail-box-new-client cell): the same wrapper
    /// as boxesDetail, reduced to this one box.
    @ViewBuilder private var newClientBoxDetail: some View {
      VStack(alignment: .leading, spacing: 20) {
        newClientBox
      }
      .padding(24)
      .frame(maxWidth: 760, alignment: .leading)
      .navigationTitle("Sharing")
    }

    /// The clients group box alone in the no-scroll VStack family (the
    /// --arx-minimal-detail-box-clients cell): the same wrapper as
    /// boxesDetail, reduced to this one box.
    @ViewBuilder private var clientsBoxDetail: some View {
      VStack(alignment: .leading, spacing: 20) {
        clientsBox
      }
      .padding(24)
      .frame(maxWidth: 760, alignment: .leading)
      .navigationTitle("Sharing")
    }

    /// Delta 10a: the GroupBox chrome with inert content (the
    /// --arx-minimal-connection-chrome cell). NEW COMPOSITION, not a
    /// reduction: GroupBox("Connection") wrapping one default-styled
    /// placeholder text, in the same family wrapper. Tests whether the
    /// box chrome/container structure alone reproduces here.
    @ViewBuilder private var connectionChromeDetail: some View {
      VStack(alignment: .leading, spacing: 20) {
        GroupBox("Connection") {
          Text("Fixture placeholder text")
        }
      }
      .padding(24)
      .frame(maxWidth: 760, alignment: .leading)
      .navigationTitle("Sharing")
    }

    /// Delta 10b: the connection box's exact contents without the
    /// chrome (the --arx-minimal-connection-contents cell). REDUCTION
    /// of the reproducing delta-9a cell: renders connectionBoxContent,
    /// the same builder connectionBox wraps in its GroupBox, so the
    /// contents are verbatim identical by construction.
    @ViewBuilder private var connectionContentsDetail: some View {
      VStack(alignment: .leading, spacing: 20) {
        connectionBoxContent
      }
      .padding(24)
      .frame(maxWidth: 760, alignment: .leading)
      .navigationTitle("Sharing")
    }

    /// Delta 11a: the two connection text fields alone (the
    /// --arx-minimal-connection-fields cell). REDUCTION of the
    /// reproducing delta-10b contents cell: same inner
    /// VStack(alignment: .leading, spacing: 10).padding(6) shape
    /// reduced to the verbatim connectionFields pieces, same family
    /// wrapper.
    @ViewBuilder private var connectionFieldsDetail: some View {
      VStack(alignment: .leading, spacing: 20) {
        VStack(alignment: .leading, spacing: 10) {
          connectionFields
        }
        .padding(6)
      }
      .padding(24)
      .frame(maxWidth: 760, alignment: .leading)
      .navigationTitle("Sharing")
    }

    /// Delta 11b: the connection caption and button row alone (the
    /// --arx-minimal-connection-caption-buttons cell). REDUCTION of the
    /// reproducing delta-10b contents cell: same inner
    /// VStack(alignment: .leading, spacing: 10).padding(6) shape
    /// reduced to the verbatim connectionCaptionAndButtons pieces,
    /// same family wrapper.
    @ViewBuilder private var connectionCaptionButtonsDetail: some View {
      VStack(alignment: .leading, spacing: 20) {
        VStack(alignment: .leading, spacing: 10) {
          connectionCaptionAndButtons
        }
        .padding(6)
      }
      .padding(24)
      .frame(maxWidth: 760, alignment: .leading)
      .navigationTitle("Sharing")
    }

    /// Delta 12a: the connection origin text field alone (the
    /// --arx-minimal-connection-origin-field cell). REDUCTION of the
    /// reproducing delta-11a fields cell: same inner
    /// VStack(alignment: .leading, spacing: 10).padding(6) shape
    /// reduced to the verbatim connectionOriginField piece, same
    /// family wrapper.
    @ViewBuilder private var connectionOriginFieldDetail: some View {
      VStack(alignment: .leading, spacing: 20) {
        VStack(alignment: .leading, spacing: 10) {
          connectionOriginField
        }
        .padding(6)
      }
      .padding(24)
      .frame(maxWidth: 760, alignment: .leading)
      .navigationTitle("Sharing")
    }

    /// Delta 12b: the connection port text field alone (the
    /// --arx-minimal-connection-port-field cell). REDUCTION of the
    /// reproducing delta-11a fields cell: same inner
    /// VStack(alignment: .leading, spacing: 10).padding(6) shape
    /// reduced to the verbatim connectionPortField piece, same family
    /// wrapper.
    @ViewBuilder private var connectionPortFieldDetail: some View {
      VStack(alignment: .leading, spacing: 20) {
        VStack(alignment: .leading, spacing: 10) {
          connectionPortField
        }
        .padding(6)
      }
      .padding(24)
      .frame(maxWidth: 760, alignment: .leading)
      .navigationTitle("Sharing")
    }

    /// Delta 13a: the origin field without its .textContentType(.URL)
    /// modifier (the --arx-minimal-connection-origin-no-content-type
    /// cell). Same inner VStack(alignment: .leading, spacing:
    /// 10).padding(6) shape and family wrapper as the delta-12a
    /// origin-field cell so the same-run contrast isolates the
    /// removed modifier.
    @ViewBuilder private var connectionOriginNoContentTypeDetail: some View {
      VStack(alignment: .leading, spacing: 20) {
        VStack(alignment: .leading, spacing: 10) {
          connectionOriginFieldNoContentType
        }
        .padding(6)
      }
      .padding(24)
      .frame(maxWidth: 760, alignment: .leading)
      .navigationTitle("Sharing")
    }

    /// Delta 13b: the new-client box's client-label field alone (the
    /// --arx-minimal-new-client-label-field cell). REDUCTION of the
    /// reproducing delta-9b new-client box cell, using the new-client
    /// box's own inner VStack(alignment: .leading, spacing:
    /// 10).padding(6) shape - not the connection shape - inside the
    /// same family wrapper.
    @ViewBuilder private var newClientLabelFieldDetail: some View {
      VStack(alignment: .leading, spacing: 20) {
        VStack(alignment: .leading, spacing: 10) {
          clientLabelField
        }
        .padding(6)
      }
      .padding(24)
      .frame(maxWidth: 760, alignment: .leading)
      .navigationTitle("Sharing")
    }

    /// Delta 13c: the new-client box's Read selected lists Toggle
    /// alone (the --arx-minimal-new-client-read-toggle cell). A second
    /// REDUCTION of the reproducing delta-9b new-client box cell, in
    /// the new-client box's own inner VStack(alignment: .leading,
    /// spacing: 10).padding(6) shape inside the same family wrapper,
    /// contrasting control type against the single-field cells.
    @ViewBuilder private var newClientReadToggleDetail: some View {
      VStack(alignment: .leading, spacing: 20) {
        VStack(alignment: .leading, spacing: 10) {
          readSelectedListsToggle
        }
        .padding(6)
      }
      .padding(24)
      .frame(maxWidth: 760, alignment: .leading)
      .navigationTitle("Sharing")
    }

    /// Delta 14a: the verbatim delta-12a origin-field cell with
    /// keyboard focus displaced off the field (the
    /// --arx-minimal-connection-origin-field-unfocused cell). The
    /// content is exactly connectionOriginFieldDetail; the only added
    /// behavior is the DEBUG-only first-responder displacement below.
    /// SwiftUI assigns initial focus to the lone field when the window
    /// appears, so the displacement is issued immediately and twice
    /// more on short delays; the app-side first-responder descriptor
    /// prints and the window render establish per run whether the
    /// field was unfocused at audit time, with the tree comparison
    /// when a mismatch dump exists. onAppear adds no element to the
    /// view tree.
    @ViewBuilder private var connectionOriginFieldUnfocusedDetail: some View {
      connectionOriginFieldDetail
        .onAppear {
          for delay in [0.0, 0.5, 1.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
              NSApplication.shared.keyWindow?.makeFirstResponder(nil)
            }
          }
        }
    }

    /// Delta 15: the verbatim delta-12a origin-field cell with
    /// keyboard focus displaced off the field at 1.25/1.75/2.25s -
    /// after the shared descriptor phases at 0/0.5/1.0s - while the
    /// extended schedule records the responder 0.25s after each fire
    /// (1.5/2.0/2.5s). The recorded triplet 0-2 is expected to match
    /// the focused origin-field cell (field editor), and a
    /// successful persistent displacement shows phases 3-5 as
    /// "window". The test polls for the complete six-line capture
    /// before starting the audit, so the audit is sequenced behind
    /// validated evidence of displacement; the gap between the last
    /// observation (2.5s) and audit start is unobserved and declared
    /// as such. onAppear adds no element to the view tree.
    @ViewBuilder private var connectionOriginFieldLateUnfocusedDetail: some View {
      connectionOriginFieldDetail
        .onAppear {
          for delay in [1.25, 1.75, 2.25] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
              NSApplication.shared.keyWindow?.makeFirstResponder(nil)
            }
          }
        }
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

    /// The inner box content of the detail replica, composed from the
    /// same named pieces the bisection cells use, so every cell shares
    /// verbatim element definitions and differs only in which pieces
    /// are present.
    @ViewBuilder private var detailBoxContent: some View {
      VStack(alignment: .leading, spacing: 20) {
        bridgeTitle
        bridgeStatus
        connectionBox
        newClientBox
        clientsBox
        revokeCaption
      }
      .padding(24)
      .frame(maxWidth: 760, alignment: .leading)
    }

    @ViewBuilder private var bridgeTitle: some View {
      Text("Arx bridge")
        .font(.largeTitle)
    }

    @ViewBuilder private var bridgeStatus: some View {
      Text("Choose lists and actions for a new client. Highlighting a list does not share it.")
        .foregroundStyle(Color(nsColor: .labelColor))
        .accessibilityIdentifier("bridge-status")
    }

    @ViewBuilder private var revokeCaption: some View {
      Text("Revoke stops new requests. Data already viewed and changes already saved remain.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    /// The Connection group box, verbatim from ContentView's fixture
    /// path with the fixture model's disabled states.
    @ViewBuilder private var connectionBox: some View {
      GroupBox("Connection") {
        connectionBoxContent
      }
    }

    /// The exact inner body of the connection group box, extracted
    /// verbatim in delta 10 so that the box and the
    /// --arx-minimal-connection-contents cell render the identical
    /// contents. Any change here changes both cells together. Delta 11
    /// composes it from two verbatim named sub-builders so the fields
    /// and the caption-plus-buttons cells render identical pieces.
    @ViewBuilder private var connectionBoxContent: some View {
      VStack(alignment: .leading, spacing: 10) {
        connectionFields
        connectionCaptionAndButtons
      }
      .padding(6)
    }

    /// The connection box's two text fields, extracted verbatim in
    /// delta 11. Composed into connectionBoxContent and rendered alone
    /// by the --arx-minimal-connection-fields cell. Delta 12 composes
    /// it from two verbatim named single-field sub-builders so the
    /// origin-field and port-field cells render identical pieces.
    @ViewBuilder private var connectionFields: some View {
      connectionOriginField
      connectionPortField
    }

    /// The connection origin text field, extracted verbatim in
    /// delta 12. Composed into connectionFields and rendered alone by
    /// the --arx-minimal-connection-origin-field cell.
    @ViewBuilder private var connectionOriginField: some View {
      TextField("Exact remote HTTPS origin", text: $origin)
        .textContentType(.URL)
    }

    /// The connection port text field, extracted verbatim in
    /// delta 12. Composed into connectionFields and rendered alone by
    /// the --arx-minimal-connection-port-field cell.
    @ViewBuilder private var connectionPortField: some View {
      TextField("Local port", text: $port)
    }

    /// Delta 13a: the connection origin text field identical except
    /// for the removed .textContentType(.URL) modifier. Rendered alone
    /// by the --arx-minimal-connection-origin-no-content-type cell for
    /// a same-run contrast with the delta-12a origin-field cell;
    /// connectionOriginField itself is unchanged.
    @ViewBuilder private var connectionOriginFieldNoContentType: some View {
      TextField("Exact remote HTTPS origin", text: $origin)
    }

    /// The connection box's caption and button row, extracted verbatim
    /// in delta 11. Composed into connectionBoxContent and rendered
    /// alone by the --arx-minimal-connection-caption-buttons cell.
    @ViewBuilder private var connectionCaptionAndButtons: some View {
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

    /// The new-client box's client label text field, extracted
    /// verbatim in delta 13. Composed into newClientBox and rendered
    /// alone by the --arx-minimal-new-client-label-field cell.
    @ViewBuilder private var clientLabelField: some View {
      TextField("Client label", text: $clientLabel)
    }

    /// The new-client box's Read selected lists Toggle, extracted
    /// verbatim in delta 13. Composed into newClientBox and rendered
    /// alone by the --arx-minimal-new-client-read-toggle cell.
    @ViewBuilder private var readSelectedListsToggle: some View {
      Toggle("Read selected lists", isOn: $rightsRead)
    }

    /// The New client group box, verbatim from ContentView's fixture
    /// path with the fixture model's disabled states.
    @ViewBuilder private var newClientBox: some View {
      GroupBox("New client") {
        VStack(alignment: .leading, spacing: 10) {
          clientLabelField
          readSelectedListsToggle
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
    }

    /// The Clients group box, verbatim from ContentView's fixture path.
    @ViewBuilder private var clientsBox: some View {
      GroupBox("Clients") {
        VStack(alignment: .leading, spacing: 8) {
          Button("Refresh client status") {}
          Text("No client has access.")
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(6)
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
