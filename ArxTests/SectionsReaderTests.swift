//
//  SectionsReaderTests.swift
//  ArxTests
//
//  Pure mapping checks for helper replies. No helper, provider or Reminders
//  data is involved.
//

import BridgeCore
import Testing

@testable import Arx

struct SectionsReaderTests {
  private func row(
    _ id: String?, _ name: String?, state: String = "section",
    reason: String = "exact_object_name"
  ) -> SectionsEntry {
    SectionsEntry(state: state, reason: reason, reminderID: id, actualSection: name)
  }

  private func reply(_ rows: [SectionsEntry], bound: Bool? = true, build: Bool? = true)
    -> SectionsReply
  {
    var value = SectionsReply(state: "sections", reason: "local_selection_only", results: rows)
    value.requestBound = bound
    value.buildBound = build
    return value
  }

  @Test func verifiedRowsAreNamed() {
    let out = SectionsReader.labels(
      from: reply([row("a", "Alpha"), row("b", "Bravo")]), ids: ["a", "b"])
    #expect(out["a"] == .named("Alpha"))
    #expect(out["b"] == .named("Bravo"))
  }

  @Test func everyOtherRowIsUnknown() {
    let rows = [
      row("a", nil, state: "unknown", reason: "membership_none_3009"),
      row("b", "Bravo", reason: "exact_object_candidate"),
      row("c", ""),
    ]
    let out = SectionsReader.labels(from: reply(rows), ids: ["a", "b", "c", "missing"])
    for id in ["a", "b", "c", "missing"] {
      #expect(out[id]?.name == nil)
      #expect(out[id]?.unknownReason != nil)
    }
  }

  @Test func rowsForOtherIDsAreIgnoredAndRepeatsAreUnknown() {
    let rows = [row("a", "Alpha"), row("a", "Bravo"), row("other", "Zed"), row(nil, "Nil")]
    let out = SectionsReader.labels(from: reply(rows), ids: ["a"])
    #expect(out.keys.sorted() == ["a"])
    #expect(out["a"]?.name == nil)
  }

  @Test func unboundOrFailedRepliesAreAllUnknown() {
    let unbound = SectionsReader.labels(from: reply([row("a", "Alpha")], bound: nil), ids: ["a"])
    #expect(unbound["a"]?.name == nil)
    let failed = SectionsReader.labels(
      from: SectionsReply(state: "unknown", reason: "timeout"), ids: ["a", "b"])
    #expect(failed.count == 2)
    #expect(failed.values.allSatisfy { $0.name == nil && $0.unknownReason != nil })
  }

  @Test func missingBuildBindingIsAllUnknown() {
    for build in [nil, false] as [Bool?] {
      let out = SectionsReader.labels(
        from: reply([row("a", "Alpha")], build: build), ids: ["a"])
      #expect(out["a"]?.name == nil)
      #expect(out["a"]?.unknownReason != nil)
    }
  }

  @Test func unattributedBuildsNeverReadSections() async {
    guard !SectionsReader.buildAttributed else { return }
    let out = await SectionsReader.read(sourceID: "s", listID: "l", ids: ["a", "b"])
    #expect(out.count == 2)
    #expect(out.values.allSatisfy { $0.name == nil && $0.unknownReason != nil })
  }

  @Test func overlongOrMultilineNamesAreUnknown() {
    let long = String(repeating: "x", count: 257)
    let out = SectionsReader.labels(
      from: reply([row("a", long), row("b", "two\nlines")]), ids: ["a", "b"])
    #expect(out["a"]?.name == nil)
    #expect(out["b"]?.name == nil)
  }

  @Test func repeatedIdsNeverTrapOnFailureOrOverLimitPaths() {
    let failed = SectionsReader.labels(
      from: SectionsReply(state: "unknown", reason: "timeout"), ids: ["a", "a", "b"])
    #expect(failed.count == 2)
    #expect(failed.values.allSatisfy { $0.name == nil && $0.unknownReason != nil })
  }

  @Test func noReasonPhraseReadsAsNoSection() {
    let keys = [
      "existing_permission_unavailable",
      "label_bound_exceeded",
      "labels_unverified",
      "selection_unavailable",
      "selection_timeout",
      "selection_not_exactly_one",
      "identity_unverified",
      "identity_list_unverified",
      "identity_source_unverified",
      "identity_title_unverified",
      "private_framework_unavailable",
      "membership_api_unavailable",
      "membership_unverified",
      "membership_nil_no_error",
      "membership_none_3009",
      "membership_error",
      "store_unavailable",
      "view_init_unavailable",
      "fetch_selector_unavailable",
      "id_construction_unavailable",
      "membership_section_identity",
      "membership_unnamed",
      "section_name_mismatch",
      "private_api_exception",
      "denied",
      "timeout",
      "read_busy",
      "worker_unavailable",
      "spawn_unavailable",
      "input_unavailable",
      "request_binding_unverified",
      "build_binding_unverified",
      "helper_identity_unverified",
      "spawn_failed",
      "pipe_setup_failed",
      "write_failed",
      "read_failed",
      "output_too_large",
      "output_undecodable",
      "labels_too_large",
      "sections_too_large",
      "sections_bound_exceeded",
      "exact_object_name",
      "exact_object_candidate",
      "fixture",
    ]
    for key in keys {
      let text = SectionsDiagnostics.diagnosticReason(key)
      #expect(!text.lowercased().contains("no section"), "\(key)")
    }
  }
}
