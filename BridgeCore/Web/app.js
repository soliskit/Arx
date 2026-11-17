"use strict";
let csrf = "",
  rights = null,
  lists = [],
  listID = "",
  rows = [],
  editing = null,
  busy = false,
  nextPage = null,
  previousPage = null;
const uncertainWrites = [];
const el = (id) => document.getElementById(id);
const text = (tag, value) => {
  const node = document.createElement(tag);
  node.textContent = value;
  return node;
};
const formatDate = (d) =>
  [
    d.year,
    String(d.month).padStart(2, "0"),
    String(d.day).padStart(2, "0"),
  ].join("-");
const formatTime = (d) =>
  d.hour === undefined
    ? ""
    : [String(d.hour).padStart(2, "0"), String(d.minute).padStart(2, "0")].join(
        ":",
      );
function setStatus(value) {
  const warnings = uncertainWrites
    .map(
      (failure) =>
        `At ${failure.at} a ${failure.action} did not confirm: ${failure.message}`,
    )
    .join(" ");
  el("status").textContent = warnings
    ? `${value} Unresolved writes: ${warnings} Check Reminders before repeating them.`
    : value;
}
function clear() {
  nextPage = null;
  previousPage = null;
  el("pages").hidden = true;
  csrf = "";
  rights = null;
  lists = [];
  rows = [];
  listID = "";
  editing = null;
  el("workspace").hidden = true;
  el("editor").hidden = true;
  el("pairing").hidden = false;
  el("secret").value = "";
  el("lists").replaceChildren();
  el("reminders").replaceChildren();
}
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
async function sessionAlive() {
  try {
    const probe = await fetch("/api/session", {
      credentials: "same-origin",
      cache: "no-store",
    });
    if (probe.ok) {
      return validSession(await probe.json()) ? "active" : "unknown";
    }
    return probe.status === 403 ? "denied" : "unknown";
  } catch {
    return "unknown";
  }
}
async function api(path, body) {
  const options = {
    credentials: "same-origin",
    cache: "no-store",
    headers: {},
  };
  if (body !== undefined) {
    options.method = "POST";
    options.headers = {
      "Content-Type": "application/json",
      "X-CSRF-Token": csrf,
    };
    options.body = JSON.stringify(body);
    if (
      path === "/api/mutate" &&
      new TextEncoder().encode(options.body).byteLength > 1_048_576
    ) {
      const failure = Error(
        "This reminder request exceeds 1 MiB, including its original copy. Shorten the notes.",
      );
      failure.writeOutcome = "refused"; // Nothing was sent for this new operation ID.
      throw failure;
    }
  }
  const response = await fetch(path, options);
  let result;
  try {
    result = await response.json();
  } catch {
    if (response.ok) {
      if (path === "/api/session") {
        clear();
      }
      throw Error(
        "Unexpected server response. Access could not be verified. Check the connector.",
      );
    }
    result = { error: "Unexpected server response. Check the connector." };
  }
  if (!response.ok) {
    let message = result?.error || "Request failed.";
    if (response.status === 403) {
      const session =
        path === "/api/session" || path === "/api/pair"
          ? "denied"
          : await sessionAlive();
      if (session !== "active") {
        clear();
        if (session === "unknown") {
          message =
            "Access could not be verified. Refresh to check your session before pairing again.";
        }
      } else {
        message =
          "That list or reminder is no longer available to this client. Refresh to review.";
      }
    }
    const failure = Error(message);
    failure.status = response.status;
    failure.writeOutcome = result?.writeOutcome;
    throw failure;
  }
  if (path === "/api/session" && !validSession(result)) {
    clear();
    throw Error(
      "Access could not be verified. The session response was invalid. Refresh before pairing again.",
    );
  }
  return result;
}
function pageControls() {
  el("next").disabled = busy || !nextPage;
  el("previous").disabled = busy || !previousPage;
}
function controlsBusy(value) {
  for (const button of document.querySelectorAll("button")) {
    button.disabled = value;
  }
  pageControls();
}
async function run(action) {
  if (busy) {
    setStatus(
      "Still working on the previous request. Nothing new was sent. Try again in a moment.",
    );
    return;
  }
  busy = true;
  controlsBusy(true);
  try {
    await action();
  } catch (error) {
    if (!error.reported) {
      setStatus(error.message);
    }
  } finally {
    busy = false;
    controlsBusy(false);
  }
}
function dateValue(name, original) {
  const date = el(`${name}-date`).value,
    time = el(`${name}-time`).value;
  if (!date) {
    if (time) {
      throw Error("A time needs its date.");
    }
    return undefined;
  }
  // Preserve a field's own timezone if its controls are unchanged.
  if (
    original &&
    date === formatDate(original) &&
    time === formatTime(original) &&
    el("timezone").value ===
      (editing?.fields.due?.timeZone ||
        editing?.fields.start?.timeZone ||
        Intl.DateTimeFormat().resolvedOptions().timeZone)
  ) {
    return original;
  }
  const [year, month, day] = date.split("-").map(Number),
    value = { year, month, day };
  if (time) {
    const [hour, minute] = time.split(":").map(Number);
    Object.assign(value, { hour, minute, timeZone: el("timezone").value });
  }
  return value;
}
function openEditor(item) {
  editing = item;
  const f = item?.fields || { title: "", priority: 0, alarms: [], repeats: [] };
  for (const name of ["title", "notes", "url", "location"]) {
    el(name).value = f[name] || "";
  }
  el("priority").value = String(f.priority);
  el("timezone").value =
    f.due?.timeZone ||
    f.start?.timeZone ||
    Intl.DateTimeFormat().resolvedOptions().timeZone;
  for (const name of ["start", "due"]) {
    el(`${name}-date`).value = f[name] ? formatDate(f[name]) : "";
    el(`${name}-time`).value = f[name] ? formatTime(f[name]) : "";
  }
  el("alarms").value = JSON.stringify(f.alarms, null, 2);
  el("repeats").value = JSON.stringify(f.repeats, null, 2);
  el("advanced-warning").textContent = item?.unsupportedAlarms
    ? "This reminder has unsupported alarm actions. Leave alarms unchanged."
    : "";
  el("edit-heading").textContent = item ? "Edit reminder" : "New reminder";
  el("save").textContent = item ? "Save changes" : "Create reminder";
  el("editor").hidden = false;
  el("title").focus();
}
async function mutate(action, item, extra, reload) {
  const command = {
    operationID: crypto.randomUUID(),
    action,
    listID,
    itemID: item?.id,
    base: item,
    ...extra,
  };
  let result;
  try {
    result = await api("/api/mutate", command);
  } catch (error) {
    el("editor").hidden = true;
    const refused = error.writeOutcome === "refused";
    const committed = error.writeOutcome === "committed";
    if (!refused && !committed) {
      uncertainWrites.push({
        at: new Date().toLocaleTimeString(),
        action,
        message: error.message,
      });
    }
    let message = `${error.message} This ${action} may or may not have been saved. Check Reminders before repeating it.`;
    if (refused) {
      message = `${error.message} Nothing was changed.`;
    }
    if (committed) {
      message = `Change saved, but the result could not be reloaded: ${error.message}`;
    }
    setStatus(message);
    error.reported = true;
    throw error;
  }
  try {
    await reload();
  } catch (error) {
    setStatus(
      `Change saved, but the list could not be reloaded: ${error.message}`,
    );
    error.reported = true;
    throw error;
  }
  const saved = result.reminder;
  setStatus(
    saved && saved.listID === listID && !rows.some((row) => row.id === saved.id)
      ? "Change saved. The reminder is in this list but not on the page shown."
      : "Change saved. Review the refreshed result.",
  );
}
async function load(cursor = {}, target = listID) {
  const page = await api("/api/read", { listID: target, ...cursor });
  // Switch lists only once the new list has actually loaded.
  listID = target;
  for (const button of el("lists").children) {
    button.classList.toggle("selected", button.dataset.listId === listID);
  }
  rows = page.items;
  nextPage = page.next;
  previousPage = page.previous;
  el("pages").hidden = false;
  pageControls();
  el("editor").hidden = true;
  el("list-title").textContent =
    lists.find((l) => l.id === listID)?.title || "Selected list";
  el("new").hidden =
    !rights.manage || !lists.find((l) => l.id === listID)?.writable;
  const container = el("reminders");
  container.replaceChildren();
  if (!rows.length) {
    container.append(
      text(
        "p",
        nextPage || previousPage
          ? "No current reminders on this page. Continue or refresh."
          : "This list has no reminders.",
      ),
    );
  }
  for (const item of rows) {
    const card = document.createElement("article");
    card.className = "reminder";
    card.append(
      text("h3", (item.fields.completed ? "✓ " : "") + item.fields.title),
    );
    if (item.fields.notes) {
      card.append(text("p", item.fields.notes));
    }
    if (item.fields.due) {
      card.append(
        text(
          "p",
          `Due: ${formatDate(item.fields.due)}${item.fields.due.hour === undefined ? "" : ` ${formatTime(item.fields.due)}`}`,
        ),
      );
    }
    const actions = document.createElement("div");
    actions.className = "actions";
    const button = (label, action, danger = false) => {
      const b = text("button", label);
      b.type = "button";
      b.disabled = busy;
      b.className = danger ? "danger" : "";
      b.addEventListener("click", () => run(action));
      actions.append(b);
    };
    const writable = lists.find((l) => l.id === listID)?.writable;
    if (rights.manage && writable) {
      button("Edit", () => openEditor(item));
      button(item.fields.completed ? "Reopen" : "Complete", () =>
        mutate(item.fields.completed ? "reopen" : "complete", item, {}, load),
      );
      const dest = document.createElement("select");
      dest.setAttribute("aria-label", `Move ${item.fields.title} to list`);
      for (const l of lists.filter(
        (candidate) => candidate.id !== listID && candidate.writable,
      )) {
        const option = text("option", l.title);
        option.value = l.id;
        dest.append(option);
      }
      if (dest.options.length) {
        actions.append(dest);
        button("Move", () =>
          mutate("move", item, { destination: dest.value }, load),
        );
      }
    }
    if (rights.delete && writable) {
      button(
        "Delete",
        async () => {
          const recurrence = item.fields.repeats.length
            ? " This reminder repeats. EventKit controls the resulting recurrence behavior; review Reminders afterward."
            : "";
          if (!window.confirm(`Delete "${item.fields.title}"?${recurrence}`)) {
            return;
          }
          const confirmation = window.prompt(
            "Type the exact reminder title to confirm deletion:",
          );
          if (confirmation === item.fields.title) {
            await mutate("delete", item, { confirmation }, load);
          }
        },
        true,
      );
    }
    card.append(actions);
    container.append(card);
  }
}
async function refresh() {
  const state = await api("/api/session");
  csrf = state.csrf;
  rights = state.rights;
  lists = await api("/api/lists");
  el("workspace").hidden = false;
  el("pairing").hidden = true;
  el("editor").hidden = true;
  el("lists").replaceChildren();
  for (const list of lists) {
    const b = text(
      "button",
      list.title + (list.writable ? "" : " (read-only)"),
    );
    b.type = "button";
    b.dataset.listId = list.id;
    b.className = list.id === listID ? "selected" : "";
    b.addEventListener("click", () => run(() => load({}, list.id)));
    el("lists").append(b);
  }
  if (!lists.some((l) => l.id === listID)) {
    listID = "";
    rows = [];
    el("reminders").replaceChildren();
    el("list-title").textContent = lists.length
      ? "Choose a list"
      : "No lists shared";
    el("new").hidden = true;
    el("pages").hidden = true;
  } else {
    await load();
  }
  setStatus("Connected. Only your granted lists and actions are shown.");
}
el("next").addEventListener("click", () =>
  run(() => load({ after: nextPage })),
);
el("previous").addEventListener("click", () =>
  run(() => load({ before: previousPage })),
);
el("pair-form").addEventListener("submit", (event) => {
  event.preventDefault();
  run(async () => {
    const secret = el("secret").value;
    el("secret").value = "";
    await api("/api/pair", { secret });
    await refresh();
  });
});
el("refresh").addEventListener("click", () => run(refresh));
el("forget").addEventListener("click", () => {
  clear();
  setStatus(
    "Page cleared. Revoke this client in the Mac app to end its session.",
  );
});
el("new").addEventListener("click", () => run(() => openEditor(null)));
el("cancel-edit").addEventListener("click", () => {
  editing = null;
  el("editor").hidden = true;
});
el("edit-form").addEventListener("submit", (event) => {
  event.preventDefault();
  run(async () => {
    const f = structuredClone(editing?.fields || { completed: false });
    for (const name of ["title", "notes", "url", "location"]) {
      f[name] = el(name).value || undefined;
    }
    f.priority = Number(el("priority").value);
    f.start = dateValue("start", editing?.fields.start);
    f.due = dateValue("due", editing?.fields.due);
    f.alarms = JSON.parse(el("alarms").value);
    f.repeats = JSON.parse(el("repeats").value);
    if (!Array.isArray(f.alarms) || !Array.isArray(f.repeats)) {
      throw Error("Alarms and repeats must be JSON arrays.");
    }
    await mutate(editing ? "edit" : "create", editing, { fields: f }, load);
  });
});
setInterval(() => {
  if (rights && !busy) {
    run(async () => {
      await api("/api/session");
    });
  }
}, 30000);
run(async () => {
  try {
    await refresh();
  } catch {
    clear();
    setStatus("Pair this browser from the Mac app to begin.");
  }
});
