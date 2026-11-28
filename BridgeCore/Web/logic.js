"use strict";
// Pure wire-shape and date logic shared by the page and the Node test runner.
// The served file is the same file node --test loads, so tests cover the code
// the browser actually runs. Keep this file free of DOM, network and timers.
// The IIFE keeps the helpers out of the global lexical scope: app.js is a
// separate classic script and redeclares these names from ArxLogic.
(() => {
  const formatDate = (d) =>
    [
      d.year,
      String(d.month).padStart(2, "0"),
      String(d.day).padStart(2, "0"),
    ].join("-");
  const formatTime = (d) =>
    d.hour === undefined
      ? ""
      : [
          String(d.hour).padStart(2, "0"),
          String(d.minute).padStart(2, "0"),
        ].join(":");
  function validSession(state) {
    return (
      typeof state?.csrf === "string" &&
      state.csrf.length > 0 &&
      Array.isArray(state.rights?.lists) &&
      state.rights.lists.every((id) => typeof id === "string") &&
      ["read", "manage", "delete"].every(
        (key) => typeof state.rights[key] === "boolean",
      )
    );
  }
  // Validate wire shapes before sending, not native recurrence semantics or ranges.
  // An unidentifiable malformed wire replay must still keep the server's unknown outcome.
  function validateAdvancedJSON(alarms, repeats) {
    const object = (v) =>
      v !== null && typeof v === "object" && !Array.isArray(v);
    const number = (v) => typeof v === "number" && Number.isFinite(v);
    const integer = (v) => Number.isSafeInteger(v);
    const string = (v) => typeof v === "string";
    const date = (v) => {
      if (!string(v)) {
        return false;
      }
      const parts =
        /^(\d{4}-\d{2}-\d{2})T(\d{2}):(\d{2}):(\d{2})(Z|[+-](\d{2}):(\d{2}))$/.exec(
          v,
        );
      return (
        parts !== null &&
        Number.isFinite(Date.parse(v)) &&
        Number(parts[2]) < 24 &&
        Number(parts[3]) < 60 &&
        Number(parts[4]) < 60 &&
        (parts[5] === "Z" ||
          (Number(parts[6]) < 24 && Number(parts[7]) < 60)) &&
        new Date(parts[1]).toISOString().startsWith(parts[1])
      );
    };
    const optional = (v, check) => v === undefined || v === null || check(v);
    const validAlarm = (v) =>
      object(v) &&
      ["relativeOffset", "latitude", "longitude", "radius"].every((k) =>
        optional(v[k], number),
      ) &&
      ["proximity", "label"].every((k) => optional(v[k], string)) &&
      optional(v.absoluteDate, date);
    const validRepeat = (v) =>
      object(v) &&
      string(v.frequency) &&
      integer(v.interval) &&
      ["count", "firstDayOfWeek"].every((k) => optional(v[k], integer)) &&
      optional(v.calendarIdentifier, string) &&
      optional(v.endDate, date) &&
      [
        "daysOfMonth",
        "monthsOfYear",
        "weeksOfYear",
        "daysOfYear",
        "positions",
      ].every((k) =>
        optional(v[k], (a) => Array.isArray(a) && a.every(integer)),
      ) &&
      optional(
        v.daysOfWeek,
        (a) =>
          Array.isArray(a) &&
          a.every((d) => object(d) && integer(d.day) && integer(d.week)),
      );
    if (
      !Array.isArray(alarms) ||
      !Array.isArray(repeats) ||
      !alarms.every(validAlarm) ||
      !repeats.every(validRepeat)
    ) {
      throw Error(
        "Check the alarm and repeat JSON field types and required keys. Nothing was sent or changed.",
      );
    }
  }
  // Section labels are read-only and arrive beside the reminders, keyed by id.
  // Anything that is not exactly a name or an unknown reason, or is missing, is
  // Unknown, and a lookup that failed is never shown as an empty answer.
  const UNKNOWN_TEXT = "Unknown";
  const compareText = (a, b) => {
    if (a < b) {
      return -1;
    }
    return a > b ? 1 : 0;
  };
  function sectionLabel(sections, id) {
    const raw =
      sections !== null &&
      typeof sections === "object" &&
      !Array.isArray(sections)
        ? Object.getOwnPropertyDescriptor(sections, id)?.value
        : undefined;
    const hasName = typeof raw?.name === "string" && raw.name.length > 0;
    const hasReason = typeof raw?.unknownReason === "string";
    if (hasName && !hasReason) {
      return { kind: "named", name: raw.name };
    }
    return {
      kind: "unknown",
      reason: hasReason && !hasName ? raw.unknownReason : "",
    };
  }
  function sectionText(label) {
    return label.kind === "named" ? label.name : UNKNOWN_TEXT;
  }
  // Distinct filter choices for the rows on this page: every named section by
  // name, then Unknown when any row has one.
  function sectionChoices(rows, sections) {
    const names = new Set();
    let unknown = false;
    for (const row of rows) {
      const label = sectionLabel(sections, row.id);
      if (label.kind === "named") {
        names.add(label.name);
      } else {
        unknown = true;
      }
    }
    const choices = [...names]
      .sort(compareText)
      .map((name) => ({ kind: "named", name }));
    if (unknown) {
      choices.push({ kind: "unknown" });
    }
    return choices;
  }
  function matchesFilter(label, filter) {
    if (!filter || filter.kind === "all") {
      return true;
    }
    if (filter.kind === "unknown") {
      return label.kind === "unknown";
    }
    return label.kind === "named" && label.name === filter.name;
  }
  // Groups keep the server's row order inside each group. Named groups come
  // first by name, Unknown last. grouped=false returns one group in row order.
  function arrangeBySection(rows, sections, filter, grouped) {
    const kept = [];
    for (const row of rows) {
      const label = sectionLabel(sections, row.id);
      if (matchesFilter(label, filter)) {
        kept.push({ row, label });
      }
    }
    if (!grouped) {
      return [{ title: "", label: null, rows: kept.map((k) => k.row) }];
    }
    const groups = new Map();
    for (const { row, label } of kept) {
      const key = label.kind === "named" ? `n:${label.name}` : "u";
      if (!groups.has(key)) {
        groups.set(key, { title: sectionText(label), label, rows: [] });
      }
      groups.get(key).rows.push(row);
    }
    return [...groups.values()].sort((a, b) => {
      if (a.label.kind !== b.label.kind) {
        return a.label.kind === "named" ? -1 : 1;
      }
      return compareText(a.title, b.title);
    });
  }
  globalThis.ArxLogic = {
    formatDate,
    formatTime,
    validSession,
    validateAdvancedJSON,
    sectionLabel,
    sectionText,
    sectionChoices,
    arrangeBySection,
  };
})();
