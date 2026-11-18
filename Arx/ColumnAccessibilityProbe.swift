//
//  ColumnAccessibilityProbe.swift
//  Arx
//
//  Labels the AppKit split-view containers that host each column.
//

import SwiftUI

/// Supplies accessibility descriptions for the AppKit containers that
/// SwiftUI's NavigationSplitView bridging creates above each column's hosting
/// view. AppKit NSView accessibility and SwiftUI's generated AX tree are
/// documented as separate layers, and modifiers on our own content do not
/// reach those containers; the accessibility audit flags undescribed groups
/// in that area of the tree. AppKit ignores plain NSViews by default, so a
/// description installed on a container only participates in the AX tree
/// once the container itself is exposed as an accessibility element. The
/// probe never assigns a role: the exposed element keeps whatever role
/// AppKit derives, and the UI tests observe by identifier across all roles.
/// A current audit finding is bound to an owned container only when the
/// finding's own element carries the installed identifier; ownership of any
/// previously flagged object is never inferred.
///
/// The probe sits inside its own column, so walking up the superview chain
/// reaches exactly the container hosting that column: the first ancestor that
/// is a direct child of an NSSplitView and a member of its arrangedSubviews
/// (which excludes divider views). Membership is revalidated at write time,
/// on the main actor, after a generation check cancels stale async runs.
///
/// The coordinator weakly remembers the OBSERVED target and column from the
/// first inspection of an episode, whether or not anything was changed, plus
/// a per-property record of each change actually made (with the exact
/// original value - nil and "" are different originals). While the observed
/// target and column are unchanged the probe NEVER installs or re-installs:
/// it only keeps or drops its change records as the current values match or
/// diverge, so it can never fight another owner for a field. Only a real
/// target or column change starts a new episode: the old observation is
/// reconciled (each recorded change restored to its exact original, and only
/// while the current value still equals the installed one) before the new
/// target is inspected. An existing value - even one equal to the probe's -
/// is never adopted as the probe's own. Children, frames, visibility, and
/// roles are never touched. Each target's accessibility-element flag is set
/// to true only when it is currently false, under the same per-property
/// exact-original tracking as the label and identifier. The probe is a plain
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
    var observedColumn: Column?
    var labelChange: (original: String?, installed: String)?
    var identifierChange: (original: String, installed: String)?
    var elementChange: (original: Bool, installed: Bool)?
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
      if let change = coordinator.elementChange,
        target.isAccessibilityElement() == change.installed
      {
        target.setAccessibilityElement(change.original)
      }
    }
    coordinator.observed = nil
    coordinator.observedColumn = nil
    coordinator.labelChange = nil
    coordinator.identifierChange = nil
    coordinator.elementChange = nil
  }

  private func labelContainer(for view: NSView, column: Column, coordinator: Coordinator) {
    guard let window = view.window, window.identifier?.rawValue == "main" else {
      // The probe left the window: this is a detach, so end the episode.
      Self.restore(coordinator)
      return
    }
    var node = view.superview
    var found: NSView?
    while let current = node {
      if let split = current.superview as? NSSplitView, split.arrangedSubviews.contains(current) {
        found = current
        break
      }
      node = current.superview
    }
    if let container = found, let observed = coordinator.observed,
      container === observed, coordinator.observedColumn == column
    {
      // Same observed target and column: never (re)install. Keep each
      // recorded change only while the current value still equals the
      // installed one; a changed OR cleared field belongs to another owner,
      // so its record is dropped and the field is left exactly as found.
      if let change = coordinator.labelChange,
        container.accessibilityLabel() != change.installed
      {
        coordinator.labelChange = nil
      }
      if let change = coordinator.identifierChange,
        container.accessibilityIdentifier() != change.installed
      {
        coordinator.identifierChange = nil
      }
      if let change = coordinator.elementChange,
        container.isAccessibilityElement() != change.installed
      {
        coordinator.elementChange = nil
      }
      return
    }
    // A different target, a different column on it, or the first inspection:
    // end the old episode, then observe the new target.
    Self.restore(coordinator)
    guard let container = found else { return }
    coordinator.observed = container
    coordinator.observedColumn = column
    let existingLabel = container.accessibilityLabel()
    if existingLabel == nil || existingLabel == "" {
      container.setAccessibilityLabel(column.label)
      coordinator.labelChange = (original: existingLabel, installed: column.label)
    }
    let existingIdentifier = container.accessibilityIdentifier()
    if existingIdentifier.isEmpty {
      container.setAccessibilityIdentifier(column.identifier)
      coordinator.identifierChange = (original: existingIdentifier, installed: column.identifier)
    }
    let elementBefore = container.isAccessibilityElement()
    let roleBefore = Self.roleToken(container)
    if elementBefore == false {
      container.setAccessibilityElement(true)
      coordinator.elementChange = (original: false, installed: true)
    }
    Self.emitTargetRecord(
      column: column, container: container, coordinator: coordinator,
      elementBefore: elementBefore, roleBefore: roleBefore)
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
  /// here; only booleans print.
  private static func emitTargetRecord(
    column: Column, container: NSView, coordinator: Coordinator,
    elementBefore: Bool, roleBefore: String
  ) {
    #if DEBUG
      let arguments = ProcessInfo.processInfo.arguments
      guard !coordinator.targetRecordEmitted,
        arguments.contains("--bridge-fixtures"),
        arguments.contains("--arx-dump-view-hierarchy")
      else { return }
      coordinator.targetRecordEmitted = true
      let elementAfter = container.isAccessibilityElement()
      let idInstalled = container.accessibilityIdentifier() == column.identifier
      let labelInstalled = container.accessibilityLabel() == column.label
      print(
        "column-probe-target: \(column.token) elementBefore=\(elementBefore) elementAfter=\(elementAfter) roleBefore=\(roleBefore) roleAfter=\(Self.roleToken(container)) idInstalled=\(idInstalled) labelInstalled=\(labelInstalled)"
      )
    #endif
  }
}
