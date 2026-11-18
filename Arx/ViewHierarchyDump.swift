//
//  ViewHierarchyDump.swift
//  Arx
//
//  DEBUG-only AppKit view hierarchy dump for diagnosing audit findings.
//

#if DEBUG
  import AppKit
#endif

/// Prints a bounded snapshot of the owned fixture window's AppKit view
/// hierarchy to stdout so audit findings can be attributed to concrete views.
/// xcodebuild captures the tested app's stdout into the run's .xcresult
/// bundle, which the existing CI workflow already uploads; the delimited
/// block is extracted from that bundle during analysis. There is no file
/// transport and no workflow change.
///
/// Fail-closed: it prints nothing unless ALL of the following hold - a DEBUG
/// build, the runtime model is the fixture store (no EventKit store exists),
/// and the explicit --arx-dump-view-hierarchy argument is present (only the
/// audit test passes it). A latch schedules the capture only once per launch.
/// The block carries only bounded data: per node it records depth, a class
/// token projected from a fixed vocabulary, hidden state, identifier/label
/// PRESENCE booleans (never values), and exact-frame matches against the
/// audit's flagged frames. Never dynamic class text, labels, identifiers,
/// titles, paths, environment, or other windows. Depth and node counts are
/// capped and both truncations are reported. The capture is a best-effort
/// timestamped observation of the native view tree (which is not 1:1 with
/// the AX tree); geometry is compared against the audit's at analysis time
/// and any mismatch is inconclusive. Absent, partial or malformed markers
/// mean UNKNOWN, never "no such hosts". No-op in non-DEBUG builds.
@MainActor
enum ViewHierarchyDump {
  static let launchArgument = "--arx-dump-view-hierarchy"

  #if DEBUG
    private static var requested = false
  #endif

  static func runIfRequested(isFixture: Bool) {
    #if DEBUG
      guard isFixture,
        ProcessInfo.processInfo.arguments.contains(launchArgument),
        !requested
      else { return }
      requested = true
      Task { @MainActor in
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }),
          let content = window.contentView
        else { return }
        var lines = [
          "schema: arx-view-dump/1",
          "captured: \(ISO8601DateFormatter().string(from: Date()))",
          "screen: \(NSScreen.main?.frame ?? .zero)",
          "window: \(window.frame)",
          "reference-frames: root (62.0, 142.0, 900.0, 472.0) sidebar (62.0, 142.0, 260.0, 472.0)",
        ]
        var remaining = 300
        var depthCapped = false
        dump(
          content, depth: 0, in: window, screenHeight: NSScreen.main?.frame.height ?? 0,
          lines: &lines, remaining: &remaining, depthCapped: &depthCapped)
        lines.append(
          "nodes: \(300 - remaining) node-truncated: \(remaining == 0)"
            + " depth-truncated: \(depthCapped)")
        print("ARX-VIEW-DUMP-v1-BEGIN")
        print(lines.joined(separator: "\n"))
        print("ARX-VIEW-DUMP-v1-END")
      }
    #endif
  }

  #if DEBUG
    private static let flaggedFrames: [(name: String, rect: CGRect)] = [
      ("root900", CGRect(x: 62, y: 142, width: 900, height: 472)),
      ("sidebar260", CGRect(x: 62, y: 142, width: 260, height: 472)),
    ]

    /// Fixed-vocabulary projection of a view's class. Unknown classes become
    /// "other"; no dynamic or type-parameter text ever leaves the process.
    private static func classToken(_ view: NSView) -> String {
      switch String(String(describing: Swift.type(of: view)).split(separator: "<").first ?? "") {
      case "NSHostingView": return "ns-hosting-view"
      case "NSSplitView": return "ns-split-view"
      case "NSScrollView": return "ns-scroll-view"
      case "NSClipView": return "ns-clip-view"
      case "NSVisualEffectView": return "ns-visual-effect-view"
      case "NSView": return "ns-view"
      default: return "other"
      }
    }

    private static func dump(
      _ view: NSView, depth: Int, in window: NSWindow, screenHeight: CGFloat,
      lines: inout [String], remaining: inout Int, depthCapped: inout Bool
    ) {
      guard remaining > 0 else { return }
      guard depth <= 16 else {
        depthCapped = true
        return
      }
      remaining -= 1
      let screen = window.convertToScreen(view.convert(view.bounds, to: nil))
      let audit = CGRect(
        x: screen.minX, y: screenHeight - screen.maxY, width: screen.width, height: screen.height)
      let matches = flaggedFrames.compactMap { entry -> String? in
        let r = entry.rect
        let close: (CGFloat, CGFloat) -> Bool = { abs($0 - $1) < 0.5 }
        return close(audit.minX, r.minX) && close(audit.minY, r.minY)
          && close(audit.width, r.width) && close(audit.height, r.height) ? entry.name : nil
      }
      let hasIdentifier = !view.accessibilityIdentifier()
        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      let hasLabel = !(view.accessibilityLabel() ?? "")
        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      lines.append(
        "\(String(repeating: "  ", count: depth))\(classToken(view))"
          + " hidden=\(view.isHidden)"
          + " hasIdentifier=\(hasIdentifier)"
          + " hasLabel=\(hasLabel)"
          + " match=\(matches.isEmpty ? "-" : matches.joined(separator: ","))")
      for subview in view.subviews {
        dump(
          subview, depth: depth + 1, in: window, screenHeight: screenHeight, lines: &lines,
          remaining: &remaining, depthCapped: &depthCapped)
      }
    }
  #endif
}
