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
/// hierarchy to stdout so audit findings can be attributed to concrete views,
/// and (c18) writes the same block to a nonce-named file when the launch
/// supplies ARX_DUMP_NONCE. The tested app's stdout does not reach the
/// retained CI job log in this workflow (the marker block appears in no
/// retained log), so the registered hierarchy gate is delivered through the
/// file, the same channel family as the responder phases and geometry
/// receipts. Absent a nonce, the stdout print still serves local runs.
/// There is no workflow change.
///
/// c19 writer stages: c18 showed the file can be absent with the cause
/// unobservable. The writer now records its own stages in-band through
/// the same file - but ONLY after the FULL existing authorization
/// (fixture store AND launch flag AND latch AND valid nonce) evaluates
/// true; a launch failing any element returns silently exactly as
/// before and its stage stays UNKNOWN, never observed through a safety
/// relaxation. Stages: "entered" (authorized, capture scheduled),
/// "after-sleep" (the delayed capture task ran), "incomplete:
/// window-not-found" (the owned-window guard failed - terminal), and
/// "stage: complete" as a header of the full block. Last-write-wins,
/// atomic. A file-absent read then means only {never invoked, gate
/// element false, write-level failure}; the same-process geometry
/// receipt landing is an association that bounds, not excludes, the
/// write-failure branch.
///
/// c21: comparative AppKit scroll-view evidence. The traversal records
/// each encountered NSScrollView's frame (this block's audit-convention
/// screen coordinates), its clip view's bounds and its document view's
/// frame (both document coordinates), correlated by traversal index;
/// "scroll-views: 0" records explicit absence. The records stay bounded
/// by the existing traversal cap and the read limit, and carry no
/// labels, identifiers or text. These are AppKit values captured once
/// at dump time - a different measurement family AND a different time
/// than the SwiftUI preference receipts, which are written on layout
/// events. A dump-versus-receipt disagreement discriminates measurement
/// families or capture timing; it does not conclusively establish a
/// mechanism.
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
      // c19: the stage file exists only when the full authorization
      // above passed AND the nonce is valid; every write below is
      // behind this check.
      let dumpFile: URL? = {
        guard let nonce = ProcessInfo.processInfo.environment["ARX_DUMP_NONCE"],
          nonce.range(of: "^[0-9A-Fa-f-]{36}$", options: .regularExpression) != nil
        else { return nil }
        return FileManager.default.temporaryDirectory
          .appendingPathComponent("arx-dump-\(nonce).txt")
      }()
      writeStageBlock(["stage: entered"], to: dumpFile)
      Task { @MainActor in
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        writeStageBlock(["stage: after-sleep"], to: dumpFile)
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }),
          let content = window.contentView
        else {
          writeStageBlock(["stage: incomplete", "incomplete: window-not-found"], to: dumpFile)
          return
        }
        var lines = [
          "schema: arx-view-dump/1",
          "stage: complete",
          "captured: \(ISO8601DateFormatter().string(from: Date()))",
          "screen: \(NSScreen.main?.frame ?? .zero)",
          "window: \(window.frame)",
          "ref-constants: root900 (62,142,900,472) sidebar260 (62,142,260,472)"
            + " (hardcoded match constants from an earlier run, not measurements)",
        ]
        var remaining = 300
        var depthCapped = false
        var scrollRecords: [String] = []
        dump(
          content, depth: 0, in: window, screenHeight: NSScreen.main?.frame.height ?? 0,
          lines: &lines, remaining: &remaining, depthCapped: &depthCapped,
          scrollRecords: &scrollRecords)
        lines.append(
          "nodes: \(300 - remaining) node-truncated: \(remaining == 0)"
            + " depth-truncated: \(depthCapped)")
        // c21: explicit count first, so zero scroll views records
        // absence rather than silence; one bounded record per view.
        lines.append("scroll-views: \(scrollRecords.count)")
        lines.append(contentsOf: scrollRecords)
        let block =
          "ARX-VIEW-DUMP-v1-BEGIN\n" + lines.joined(separator: "\n")
          + "\nARX-VIEW-DUMP-v1-END\n"
        print(block)
        // c18: deliver the complete block through the nonce-named file
        // (same channel family as the responder phases and geometry
        // receipts). The block is bounded by construction (300-node and
        // depth-16 caps) and written atomically.
        if let dumpFile {
          try? block.write(to: dumpFile, atomically: true, encoding: .utf8)
        }
      }
    #endif
  }

  #if DEBUG
    /// c19: a minimal delimited block carrying only fixed-vocabulary
    /// stage tokens - never dynamic text. Best-effort: a failed write
    /// reads file-absent on the test side, inside the registered bound.
    private static func writeStageBlock(_ stageLines: [String], to file: URL?) {
      guard let file else { return }
      let block =
        "ARX-VIEW-DUMP-v1-BEGIN\nschema: arx-view-dump/1\n"
        + stageLines.joined(separator: "\n") + "\nARX-VIEW-DUMP-v1-END\n"
      try? block.write(to: file, atomically: true, encoding: .utf8)
    }

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
      lines: inout [String], remaining: inout Int, depthCapped: inout Bool,
      scrollRecords: inout [String]
    ) {
      guard remaining > 0 else { return }
      guard depth <= 16 else {
        depthCapped = true
        return
      }
      remaining -= 1
      let nodeIndex = 300 - remaining
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
      if let scrollView = view as? NSScrollView {
        // c21: comparative record, correlated by traversal index. frame
        // uses this block's audit-convention screen coordinates; clip
        // bounds and document frame stay in document coordinates.
        scrollRecords.append(
          "scrollview node=\(nodeIndex) frame=\(audit)"
            + " clip-bounds=\(scrollView.contentView.bounds)"
            + " document-frame=\(scrollView.documentView.map { "\($0.frame)" } ?? "absent")")
      }
      for subview in view.subviews {
        dump(
          subview, depth: depth + 1, in: window, screenHeight: screenHeight, lines: &lines,
          remaining: &remaining, depthCapped: &depthCapped, scrollRecords: &scrollRecords)
      }
    }
  #endif
}
