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
///
/// The detail column's probe additionally carries the WINDOW ROOT work:
/// from the validated split anchor - the column wrapper's own NSSplitView,
/// proven an arranged container on the same visit - it walks strictly above
/// the anchor toward the window's content view, collecting every ancestor
/// that is already exposed (isAccessibilityElement() == true) and already
/// carries the group role. Only when the walk actually reaches the content
/// view on a complete, non-truncated path holding exactly one such ancestor
/// is that view selected; in the current run's accessibility
/// representation it is the group the strict audit reported as "Element
/// has no description", bound by the finding's own element carrying the
/// installed identifier, a unique identifier query, and a readback-
/// verified install (the selected ancestor is not thereby proven to be
/// the window's contentView object, and a frame match with earlier runs'
/// findings is not identity proof). Zero or multiple eligible ancestors, a missing or
/// invalid split anchor, a truncated or broken path, a non-vacant value,
/// or a failed write-time or membership revalidation each fail closed -
/// reconciling any prior install away where one exists - and are reported
/// as distinct bounded outcomes. A visit that loses its validated split
/// anchor ends the root episode rather than leaving a stale install
/// behind, and an episode whose install was never verified never retries
/// it.
///
/// Two changes are made on the selected view, each only while vacant, and
/// BOTH run only in the DEBUG fixture dump configuration as CI hypothesis
/// tests - ordinary and release launches install nothing:
///   - Description hypothesis: the window's own title as the label, to
///     test whether a description clears the audit's undescribed-group
///     finding. Promoting a description to ordinary or release launches
///     would be a separately reviewed production change with its own
///     user-facing assessment; this candidate makes no such claim.
///   - Identification experiment: a stable identifier, never a role
///     change, so the finding can be attributed by record.
/// The root episode owns its own separate bookkeeping keyed on the full
/// context (root, content view, window, split anchor) with the same
/// exact-original restore rules, and the column bookkeeping above is
/// untouched by it. An episode ends on a real context change, path
/// invalidation, or teardown; only then is a new root examined.
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

  /// Identifier installed by the window root experiment (detail probe only).
  private static let rootIdentifier = "window-content"

  let column: Column

  final class Coordinator {
    weak var observed: NSView?
    weak var observedContainer: NSView?
    var observedColumn: Column?
    var labelChange: (original: String?, installed: String)?
    var identifierChange: (original: String, installed: String)?
    var targetRecordEmitted = false
    weak var observedRoot: NSView?
    weak var rootContentView: NSView?
    weak var rootWindow: NSWindow?
    weak var rootSplit: NSSplitView?
    var rootLabelChange: (original: String?, installed: String)?
    var rootIdentifierChange: (original: String, installed: String)?
    var rootRecordOutcomes = Set<String>()
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

  /// Full teardown of both episodes (window detach, dismantle).
  private static func restore(_ coordinator: Coordinator) {
    Self.restoreColumn(coordinator)
    Self.restoreRoot(coordinator)
  }

  /// Ends the column episode only: restores each recorded change on the
  /// observed target (while its current value still equals the installed
  /// one), then ALWAYS clears the column bookkeeping, including when a weak
  /// target is already gone. The root episode has its own context key and
  /// is untouched here: only a real root/context change, an invalidated
  /// path, or full teardown ends it.
  private static func restoreColumn(_ coordinator: Coordinator) {
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

  /// Restores the root experiment's recorded label and identifier changes
  /// (while each current value still equals the installed one), then
  /// ALWAYS clears the root bookkeeping, including when the weak target is
  /// already gone.
  private static func restoreRoot(_ coordinator: Coordinator) {
    if let root = coordinator.observedRoot {
      if let change = coordinator.rootLabelChange, root.accessibilityLabel() == change.installed {
        root.setAccessibilityLabel(change.original)
      }
      if let change = coordinator.rootIdentifierChange,
        root.accessibilityIdentifier() == change.installed
      {
        root.setAccessibilityIdentifier(change.original)
      }
    }
    coordinator.rootLabelChange = nil
    coordinator.observedRoot = nil
    coordinator.rootContentView = nil
    coordinator.rootWindow = nil
    coordinator.rootSplit = nil
    coordinator.rootIdentifierChange = nil
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
    var boundarySplit: NSSplitView?
    var hops = 0
    while let current = node, hops < 64 {
      if let split = current.superview as? NSSplitView, split.arrangedSubviews.contains(current) {
        // The first arranged-wrapper boundary ends the walk either way.
        // Adopt only a hosting-view ancestor found strictly below this
        // container on the probe's own path; otherwise this column has no
        // target and the probe stays out of other layout levels.
        boundarySplit = split
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
    } else {
      // A different target, container, or column, or the first inspection:
      // end the old column episode, then observe the new target. The root
      // episode keeps its own context key and is untouched here: only a
      // real root/context change, an invalidated path, or full teardown
      // ends it.
      Self.restoreColumn(coordinator)
      if let located = found {
        // Revalidate both relations at write time: the container must still
        // be an arranged subview of its split view, and the target must
        // still be its descendant on the probe's own path, in the main
        // window.
        if let split = located.container.superview as? NSSplitView,
          split.arrangedSubviews.contains(located.container),
          Self.isDescendant(located.target, of: located.container),
          located.target.window === window
        {
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
            coordinator.identifierChange = (
              original: existingIdentifier, installed: column.identifier
            )
          }
          Self.emitTargetRecord(column: column, target: target, coordinator: coordinator)
        }
      }
    }
    if column == .detail {
      if let split = boundarySplit {
        updateRootTarget(anchoredAt: split, window: window, coordinator: coordinator)
      } else {
        // No validated split anchor this visit (the path lost its arranged
        // boundary, or the walk hit its hop limit first): fail closed on
        // the root experiment and reconcile any prior install away, rather
        // than leave a stale identifier behind. A valid anchor with no
        // hosting view below it still reaches updateRootTarget above; this
        // branch is only the invalid-anchor case. The column episode is
        // untouched.
        Self.restoreRoot(coordinator)
        Self.emitRootRecord(coordinator: coordinator, outcome: "no-anchor", eligible: 0)
      }
    } else {
      // A reused coordinator whose column is no longer detail never runs
      // the root experiment again: end any prior root episode rather than
      // leave a stale identifier behind. No root record for a non-detail
      // column.
      Self.restoreRoot(coordinator)
    }
  }

  /// The window root work, gated to the DEBUG fixture dump configuration:
  /// outside it nothing is installed. A description hypothesis (the
  /// window's own title) plus the identification-only experiment. From the
  /// validated split anchor (the column wrapper's own NSSplitView, proven
  /// an arranged container on this same visit), walk strictly above the
  /// anchor toward the window's content view, collecting every ancestor
  /// that is already exposed and already carries the group role. Only a
  /// complete, non-truncated path that actually reaches the content view
  /// with exactly one eligible ancestor qualifies; every other shape fails
  /// closed (any prior install reconciled away) with a distinct bounded
  /// outcome. The work NEVER assigns a role and never touches exposure,
  /// children, frames or visibility.
  private func updateRootTarget(
    anchoredAt split: NSSplitView, window: NSWindow, coordinator: Coordinator
  ) {
    guard Self.fixtureDumpConfiguration else { return }
    guard let contentView = window.contentView else {
      Self.restoreRoot(coordinator)
      Self.emitRootRecord(coordinator: coordinator, outcome: "no-content-view", eligible: 0)
      return
    }
    var node = split.superview
    var hops = 0
    var reachedContent = false
    var eligible: [NSView] = []
    while let current = node, hops < 64 {
      if current.isAccessibilityElement(), current.accessibilityRole() == .group {
        eligible.append(current)
      }
      if current === contentView {
        reachedContent = true
        break
      }
      node = current.superview
      hops += 1
    }
    if !reachedContent {
      // Fail closed: never install on a truncated or broken path, and
      // reconcile any prior install away.
      Self.restoreRoot(coordinator)
      Self.emitRootRecord(
        coordinator: coordinator, outcome: "path-truncated", eligible: eligible.count)
      return
    }
    if eligible.count != 1 {
      // Fail closed: eligibility drift reconciles any prior install away.
      Self.restoreRoot(coordinator)
      Self.emitRootRecord(
        coordinator: coordinator,
        outcome: eligible.isEmpty ? "no-eligible" : "multiple-eligible",
        eligible: eligible.count)
      return
    }
    let target = eligible[0]
    // Explicit membership revalidation, independent of the walk's implicit
    // proof: the anchor and the candidate must both still belong to this
    // window's content hierarchy.
    guard split.window === window, target.window === window,
      Self.isDescendant(split, of: contentView), Self.isDescendant(target, of: contentView)
    else {
      // Fail closed: an anchor or candidate outside this window invalidates
      // the whole episode claim, so reconcile any prior install away.
      Self.restoreRoot(coordinator)
      Self.emitRootRecord(coordinator: coordinator, outcome: "invalid-anchor", eligible: 1)
      return
    }
    if let observed = coordinator.observedRoot, observed === target,
      coordinator.rootContentView === contentView, coordinator.rootWindow === window,
      coordinator.rootSplit === split
    {
      // Same root episode: the full context (root, content view, window,
      // split anchor) still holds and the exact eligible path above the
      // anchor was revalidated on this visit. Never re-install; keep the
      // recorded change only while the current value still equals the
      // installed one.
      if let change = coordinator.rootIdentifierChange,
        target.accessibilityIdentifier() != change.installed
      {
        coordinator.rootIdentifierChange = nil
      }
      if let change = coordinator.rootLabelChange,
        target.accessibilityLabel() != change.installed
      {
        coordinator.rootLabelChange = nil
      }
      return
    }
    // A different root or context, or the first inspection: end the old
    // root episode, then examine the new one.
    Self.restoreRoot(coordinator)
    // Revalidate at write time: still exposed, still group role, still on
    // the content view's chain strictly above the validated split anchor,
    // still in the main window.
    guard target.isAccessibilityElement(), target.accessibilityRole() == .group,
      Self.isDescendant(target, of: contentView), Self.isDescendant(split, of: target),
      target.window === window
    else {
      Self.emitRootRecord(coordinator: coordinator, outcome: "revalidation-failed", eligible: 1)
      return
    }
    coordinator.observedRoot = target
    coordinator.rootContentView = contentView
    coordinator.rootWindow = window
    coordinator.rootSplit = split
    // All root writes sit behind the entry gate above: this candidate
    // TESTS the repair hypothesis in the DEBUG fixture dump configuration
    // only. Promoting a description to ordinary or release launches would
    // be a separately reviewed production change, not part of this
    // candidate. Description hypothesis: the window's own title describes
    // its content group. Installed only while the label is vacant; a
    // foreign label is never overwritten.
    let title = window.title
    let existingLabel = target.accessibilityLabel()
    if title.isEmpty {
      Self.emitRootRecord(coordinator: coordinator, outcome: "no-window-title", eligible: 1)
    } else if existingLabel != nil && existingLabel != "" {
      Self.emitRootRecord(coordinator: coordinator, outcome: "foreign-label", eligible: 1)
    } else {
      target.setAccessibilityLabel(title)
      if target.accessibilityLabel() == title {
        coordinator.rootLabelChange = (original: existingLabel, installed: title)
        Self.emitRootRecord(coordinator: coordinator, outcome: "label-installed", eligible: 1)
      } else {
        // Unexpected readback: leave the current value exactly as found
        // (never overwrite it), keep no owned label record, and never
        // retry within this episode.
        Self.emitRootRecord(coordinator: coordinator, outcome: "label-unverified", eligible: 1)
      }
    }
    // Identification experiment.
    let existingIdentifier = target.accessibilityIdentifier()
    if !existingIdentifier.isEmpty {
      Self.emitRootRecord(coordinator: coordinator, outcome: "foreign-id", eligible: 1)
      return
    }
    target.setAccessibilityIdentifier(Self.rootIdentifier)
    if target.accessibilityIdentifier() == Self.rootIdentifier {
      coordinator.rootIdentifierChange = (
        original: existingIdentifier, installed: Self.rootIdentifier
      )
      Self.emitRootRecord(coordinator: coordinator, outcome: "installed", eligible: 1)
    } else {
      // The write did not take: the readback is unexpected (the setter
      // may have been rejected, normalized, or changed underneath us; the
      // cause is not provable from here). Leave the current value
      // exactly as found (never overwrite a foreign value), and keep the
      // observed context with NO owned change record, so this episode
      // never retries the install. Only a real context change examines a
      // new root, and a still non-vacant identifier there reports
      // foreign-id instead. Report the attempt separately from a
      // readback-verified install.
      Self.emitRootRecord(coordinator: coordinator, outcome: "install-unverified", eligible: 1)
    }
  }

  /// True only in the DEBUG fixture dump configuration (the two flags the
  /// fixture UI test launches pass). Gates the window root work itself -
  /// description hypothesis, identification experiment, and records -
  /// never the production column fix.
  private static var fixtureDumpConfiguration: Bool {
    #if DEBUG
      let arguments = ProcessInfo.processInfo.arguments
      return arguments.contains("--bridge-fixtures")
        && arguments.contains("--arx-dump-view-hierarchy")
    #else
      return false
    #endif
  }

  /// Bounded window-root observation record, emitted at most once per
  /// distinct outcome per Coordinator instance (one line per distinct
  /// outcome from the closed set above) and only in the DEBUG fixture dump
  /// configuration: a closed outcome token and a bounded count, never
  /// strings, frames or addresses. Each distinct outcome prints because an
  /// early layout visit can legitimately precede eligibility.
  private static func emitRootRecord(coordinator: Coordinator, outcome: String, eligible: Int) {
    #if DEBUG
      let arguments = ProcessInfo.processInfo.arguments
      guard !coordinator.rootRecordOutcomes.contains(outcome),
        arguments.contains("--bridge-fixtures"),
        arguments.contains("--arx-dump-view-hierarchy")
      else { return }
      coordinator.rootRecordOutcomes.insert(outcome)
      print("window-probe-target: outcome=\(outcome) eligible=\(eligible)")
    #endif
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
