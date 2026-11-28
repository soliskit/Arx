//
//  SectionsReader.swift
//  Arx
//
//  Maps the embedded helper's batch reply to section labels. A name is shown
//  only for a row that the helper verified; everything else is Unknown, never
//  "no section".
//

import BridgeCore
import Foundation

nonisolated enum SectionsReader {
  /// Pure mapping, separately testable. `ids` are the reminders being served;
  /// rows for any other id are ignored, and an id answered twice is Unknown.
  static func labels(from reply: SectionsReply, ids: [String]) -> [String: SectionLabel] {
    // Both bindings must hold: the reply answers this request, and the app and
    // helper were built from the same attributed source snapshot.
    guard reply.state == "sections", reply.requestBound == true, reply.buildBound == true,
      let rows = reply.results
    else {
      let reason = SectionsDiagnostics.diagnosticReason(reply.reason)
      return Dictionary(
        ids.map { ($0, SectionLabel.unknown(reason)) }, uniquingKeysWith: { first, _ in first })
    }
    let wanted = Set(ids)
    var named: [String: String] = [:]
    var reasons: [String: String] = [:]
    var seen = Set<String>()
    var repeated = Set<String>()
    for row in rows {
      guard let id = row.reminderID, wanted.contains(id) else { continue }
      if !seen.insert(id).inserted {
        repeated.insert(id)
        continue
      }
      if row.state == "section", row.reason == "exact_object_name",
        let name = boundedName(row.actualSection)
      {
        named[id] = name
      } else {
        reasons[id] = SectionsDiagnostics.diagnosticReason(row.reason)
      }
    }
    var result: [String: SectionLabel] = [:]
    for id in ids {
      if repeated.contains(id) {
        result[id] = .unknown("membership unverified (conflicting rows)")
      } else if let name = named[id] {
        result[id] = .named(name)
      } else {
        result[id] = .unknown(reasons[id] ?? "membership unverified")
      }
    }
    return result
  }

  static func boundedName(_ value: String?) -> String? {
    guard let value, !value.isEmpty, value.utf8.count <= 256,
      !value.contains("\n"), !value.contains("\r")
    else { return nil }
    return value
  }

  /// True only for a build made from a clean tracked tree with attribution
  /// enabled. Any other build never starts the helper and serves Unknown.
  static var buildAttributed: Bool {
    ARXSectionWorker.requiresAttribution()
      && SectionsBuildAttribution.lowercaseHex(ARXSectionWorker.sourceRevision(), count: 40)
      && SectionsBuildAttribution.lowercaseHex(ARXSectionWorker.sourceManifest(), count: 64)
  }

  static let statusAttributed =
    "Sections: read-only. Names appear only for lists a client can read, or Unknown."
  static let statusUnattributed =
    "Sections: unavailable in this build (source not attributed). Clients see Unknown."

  /// One batch read of one list through the serial queue. Mapping runs on the caller's
  /// actor; only the wait is on the queue.
  static func read(sourceID: String, listID: String, ids: [String]) async
    -> [String: SectionLabel]
  {
    guard buildAttributed else {
      let reason = SectionLabel.unknown("section reading unavailable (build not attributed)")
      return Dictionary(ids.map { ($0, reason) }, uniquingKeysWith: { first, _ in first })
    }
    let reply = await SectionsReadQueue.shared.read(sourceID: sourceID, listID: listID)
    return labels(from: reply, ids: ids)
  }
}
