//
//  ColumnAccessibilityProbe.swift
//  Arx
//
//  Labels the AppKit hosting views that hold each column's SwiftUI content.
//

import SwiftUI

/// Supplies accessibility descriptions for the AppKit hosting view that
/// SwiftUI's NavigationSplitView bridging places below the split-view
/// container of each column. AppKit NSView accessibility and SwiftUI's
/// generated AX tree are documented as separate layers, and modifiers on our
/// own content do not reach that hosting view; the accessibility audit flags
/// undescribed groups in that area of the tree. A current audit finding is
/// bound to an owned target only when the finding's own element carries the
/// installed identifier; ownership of any previously flagged object is never
/// inferred. The probe never assigns a role and never changes
/// accessibility-element flags: the target keeps whatever role and exposure
/// AppKit derives, and the UI tests observe by identifier across all roles.
///
/// The probe sits inside its own column, so walking up the superview chain
/// reaches exactly the split-view container hosting that column: the first
/// ancestor that is a direct child of an NSSplitView and a member of its
/// arrangedSubviews (which excludes divider views). The probe's target is
/// the nearest NSHostingView ancestor on the probe's OWN path strictly
/// below that container, identified by class - never by child position or
/// sibling search. The walk stops at the first such container whether or
/// not a hosting-view ancestor was found below it: a column whose path
/// holds no hosting view installs nothing and emits no record, rather than
/// adopting a view from another layout level. In the captured fixture
/// hierarchy that ancestor sits directly below the container for the detail
/// column and a few plain container views below it for the sidebar column.
/// Both relations (container still an arranged subview of the split view,
/// target still its descendant on the probe's path) are revalidated at
/// write time, on the main actor, after a generation check cancels stale
/// async runs. Discovery and revalidation walks are bounded.
///
/// The coordinator weakly remembers the OBSERVED target, its container, and
/// the column from the first inspection of an episode, whether or not
/// anything was changed, plus a per-property record of each change actually
/// made (with the exact original value - nil and "" are different
/// originals). While the observed target, container, and column are
/// unchanged the probe NEVER installs or re-installs: it only keeps or
/// drops its change records as the current values match or diverge, so it
/// can never fight another owner for a field. Only a real target, container,
/// or column change starts a new episode: the old observation is reconciled
/// (each recorded change restored to its exact original, and only while the
/// current value still equals the installed one) before the new target is
/// inspected. An existing value - even one equal to the probe's - is never
/// adopted as the probe's own. Children, frames, visibility, roles, and
/// accessibility-element flags are never touched. The probe is a plain
/// NSView in background layout.
struct ColumnAccessibilityProbe: NSViewRepresentable {
  enum Column {
    case sidebar
    case detail

    var label: String {
      switch self {
      case .sidebar:
        return String(
          localized: "Lists to share", comment: "Accessibility description of the sidebar column")
      case .detail:
        return String(
          localized: "Sharing", comment: "Accessibility description of the detail column")
      }
    }

    var identifier: String {
      switch self {
      case .sidebar: return "column-sidebar"
      case .detail: return "column-detail"
      }
    }

    var token: String {
      switch self {
      case .sidebar: return "sidebar"
      case .detail: return "detail"
      }
    }
  }

  let column: Column

  final class Coordinator {
    weak var observed: NSView?
    weak var observedContainer: NSView?
    var observedColumn: Column?
    var labelChange: (original: String?, installed: String)?
    var identifierChange: (original: String, installed: String)?
    var targetRecordEmitted = false
    var generation: UInt = 0
  }

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> NSView {
    NSView()
  }

  func updateNSView(_ nsView: NSView, context: Context) {
    let coordinator = context.coordinator
    coordinator.generation &+= 1
    let generation = coordinator.generation
    DispatchQueue.main.async { [weak nsView, weak coordinator] in
      guard let view = nsView, let coordinator, coordinator.generation == generation else { return }
      labelContainer(for: view, column: column, coordinator: coordinator)
    }
  }

  static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
    coordinator.generation &+= 1
    Self.restore(coordinator)
  }

  /// Ends the episode: restores each recorded change on the observed target
  /// (while its current value still equals the installed one), then ALWAYS
  /// clears the bookkeeping, including when the weak target is already gone.
  private static func restore(_ coordinator: Coordinator) {
    if let target = coordinator.observed {
      if let change = coordinator.labelChange, target.accessibilityLabel() == change.installed {
        target.setAccessibilityLabel(change.original)
      }
      if let change = coordinator.identifierChange,
        target.accessibilityIdentifier() == change.installed
      {
        target.setAccessibilityIdentifier(change.original)
      }
    }
    coordinator.observed = nil
    coordinator.observedContainer = nil
    coordinator.observedColumn = nil
    coordinator.labelChange = nil
    coordinator.identifierChange = nil
  }

  /// True when `view`'s class is SwiftUI's hosting view of any content
  /// type. There is no public type check over the generic's specialization,
  /// so identification is by demangled class name; a path with no matching
  /// ancestor simply yields no target.
  private static func isHostingView(_ view: NSView) -> Bool {
    String(describing: type(of: view)).hasPrefix("NSHostingView")
  }

  /// True when `view` is `ancestor` or below it in the superview chain
  /// (bounded walk; a cycle or runaway chain reports false).
  private static func isDescendant(_ view: NSView, of ancestor: NSView) -> Bool {
    var node: NSView? = view
    var hops = 0
    while let current = node, hops < 64 {
      if current === ancestor { return true }
      node = current.superview
      hops += 1
    }
    return false
  }

  private func labelContainer(for view: NSView, column: Column, coordinator: Coordinator) {
    guard let window = view.window, window.identifier?.rawValue == "main" else {
      // The probe left the window: this is a detach, so end the episode.
      Self.restore(coordinator)
      return
    }
    var node = view.superview
    var hosting: NSView?
    var found: (container: NSView, target: NSView)?
    var hops = 0
    while let current = node, hops < 64 {
      if let split = current.superview as? NSSplitView, split.arrangedSubviews.contains(current) {
        // The first arranged-wrapper boundary ends the walk either way.
        // Adopt only a hosting-view ancestor found strictly below this
        // container on the probe's own path; otherwise this column has no
        // target and the probe stays out of other layout levels.
        if let target = hosting, target !== current {
          found = (container: current, target: target)
        }
        break
      }
      if hosting == nil, Self.isHostingView(current) {
        hosting = current
      }
      node = current.superview
      hops += 1
    }
    if let located = found, let observed = coordinator.observed,
      located.target === observed, located.container === coordinator.observedContainer,
      coordinator.observedColumn == column
    {
      // Same observed target, container, and column: never (re)install.
      // Keep each recorded change only while the current value still equals
      // the installed one; a changed OR cleared field belongs to another
      // owner, so its record is dropped and the field is left exactly as
      // found.
      if let change = coordinator.labelChange,
        located.target.accessibilityLabel() != change.installed
      {
        coordinator.labelChange = nil
      }
      if let change = coordinator.identifierChange,
        located.target.accessibilityIdentifier() != change.installed
      {
        coordinator.identifierChange = nil
      }
      return
    }
    // A different target, container, or column, or the first inspection:
    // end the old episode, then observe the new target.
    Self.restore(coordinator)
    guard let located = found else { return }
    // Revalidate both relations at write time: the container must still be
    // an arranged subview of its split view, and the target must still be
    // its descendant on the probe's own path, in the main window.
    guard let split = located.container.superview as? NSSplitView,
      split.arrangedSubviews.contains(located.container),
      Self.isDescendant(located.target, of: located.container),
      located.target.window === window
    else { return }
    coordinator.observed = located.target
    coordinator.observedContainer = located.container
    coordinator.observedColumn = column
    let target = located.target
    let existingLabel = target.accessibilityLabel()
    if existingLabel == nil || existingLabel == "" {
      target.setAccessibilityLabel(column.label)
      coordinator.labelChange = (original: existingLabel, installed: column.label)
    }
    let existingIdentifier = target.accessibilityIdentifier()
    if existingIdentifier.isEmpty {
      target.setAccessibilityIdentifier(column.identifier)
      coordinator.identifierChange = (original: existingIdentifier, installed: column.identifier)
    }
    Self.emitTargetRecord(column: column, target: target, coordinator: coordinator)
  }

  /// Maps the observed role to a fixed token. Raw role strings never leave
  /// the process; anything outside the known set reports as `other`.
  private static func roleToken(_ view: NSView) -> String {
    guard let role = view.accessibilityRole() else { return "none" }
    switch role {
    case .group: return "group"
    case .splitGroup: return "splitGroup"
    case .unknown: return "unknown"
    default: return "other"
    }
  }

  /// Bounded per-target observation record, emitted at most once per
  /// Coordinator instance (one probe per column; in practice one episode per
  /// column per launch) and only in the DEBUG fixture dump configuration:
  /// fixed column token, booleans and closed role tokens, never strings,
  /// frames or addresses. Equality against the installed values is computed
  /// here; only booleans print. Both element reads happen after any
  /// label/identifier install in the same visit: they are two observations
  /// of a flag the probe never mutates, not a before/after pair.
  private static func emitTargetRecord(
    column: Column, target: NSView, coordinator: Coordinator
  ) {
    #if DEBUG
      let arguments = ProcessInfo.processInfo.arguments
      guard !coordinator.targetRecordEmitted,
        arguments.contains("--bridge-fixtures"),
        arguments.contains("--arx-dump-view-hierarchy")
      else { return }
      coordinator.targetRecordEmitted = true
      let elementObserved = target.isAccessibilityElement()
      let idInstalled = target.accessibilityIdentifier() == column.identifier
      let labelInstalled = target.accessibilityLabel() == column.label
      print(
        "column-probe-target: \(column.token) elementBefore=\(elementObserved) elementAfter=\(elementObserved) roleBefore=\(Self.roleToken(target)) roleAfter=\(Self.roleToken(target)) idInstalled=\(idInstalled) labelInstalled=\(labelInstalled)"
      )
    #endif
  }
}
