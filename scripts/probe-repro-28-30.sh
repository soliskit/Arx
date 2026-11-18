#!/bin/bash
# Diagnostic reproduction probes for issues #28 and #30. Fixture data only: no
# real Reminders, and no network beyond the app's own loopback listener. Every
# probe records evidence; a probe may reproduce its bug or show that it does
# not occur, and neither outcome fails this script. Harness failures (no
# window, missing elements, refused bridge) do fail it.
set -euo pipefail
if [[ "${CI:-}" == true && "${ARX_FIXTURE_DISPLAY_READY:-}" != 1 ]]; then
  exec swift scripts/fixture-display.swift "$0"
fi
APP="${PWD}/.build/Build/Products/Debug/Arx.app"
[[ -d "${APP}" ]] || { echo "Built app not found"; exit 1; }
OUT="repro-probes.txt"
: > "${OUT}"
PID=""
SECRET=""
PAIR_HEADERS=""
PAIR_BODY=""
cleanup() {
  if [[ -n "${TOTAL_WATCHDOG:-}" ]]; then
    kill "${TOTAL_WATCHDOG}" 2>/dev/null || true
    bounded_reap "${TOTAL_WATCHDOG}" 5
  fi
  # The app runs in its own session (see launch), so the group kill owns its
  # descendants too. The kill targets the recorded group unconditionally: a
  # leader that exited first must not skip surviving members, and relaunch
  # never reuses this variable before this point. A recycled pgid belonging to
  # someone else is a stated residual risk, bounded by the short lifetime.
  if [[ -n "${PID}" ]]; then
    kill -TERM -- -"${PID}" 2>/dev/null || true
    bounded_reap_group "${PID}" 10
    kill -KILL -- -"${PID}" 2>/dev/null || true
  fi
  [[ -n "${PAIR_HEADERS}" ]] && rm -f "${PAIR_HEADERS}"
  [[ -n "${PAIR_BODY}" ]] && rm -f "${PAIR_BODY}"
  # Clear only the fixture-owned pairing secret, and only while the pasteboard
  # still holds exactly it; never erase unrelated clipboard contents. A failed
  # or wedged pasteboard read/write is reported, never silent.
  if [[ -n "${SECRET}" ]]; then
    local_paste=""
    local_paste=$(bounded "${PASTE_LIMIT}" "${OUTCOME_FILE}" pbpaste 2>/dev/null)
    local_paste_outcome=$(cat "${OUTCOME_FILE}" 2>/dev/null || true)
    if [[ "${local_paste_outcome}" != "ok" ]]; then
      echo "CLEANUP WARNING: pasteboard read ${local_paste_outcome:-no-outcome}; the fixture pairing secret may remain on the pasteboard" >>"${OUT}"
    elif [[ "${local_paste}" == "${SECRET}" ]]; then
      printf '' | bounded "${PASTE_LIMIT}" "${OUTCOME_FILE}" pbcopy
      local_clear_outcome=$(cat "${OUTCOME_FILE}" 2>/dev/null || true)
      if [[ "${local_clear_outcome}" != "ok" ]]; then
        echo "CLEANUP WARNING: pasteboard clear ${local_clear_outcome:-no-outcome}; the fixture pairing secret may remain on the pasteboard" >>"${OUT}"
      fi
    fi
  fi
  rm -f "${OUTCOME_FILE}"
}
trap cleanup EXIT
native() {
  osascript - "$@" <<'APPLESCRIPT'
on attributeValue(node, attributeName)
  tell application "System Events" to return value of attribute attributeName of node
end attributeValue
on optionalAttribute(node, attributeName)
  try
    return my attributeValue(node, attributeName)
  on error
    return missing value
  end try
end optionalAttribute
on detailGroup(groupIndex)
  tell application "System Events" to tell process "Arx"
    return group groupIndex of scroll area 1 of group 2 of splitter group 1 of group 1 of window 1
  end tell
end detailGroup
on pressButton(groupIndex, buttonIndex)
  tell application "System Events" to tell process "Arx"
    set targetButton to button buttonIndex of (my detailGroup(groupIndex))
    perform action "AXPress" of targetButton
  end tell
end pressButton
on pressIdentifier(expectedID)
  tell application "System Events" to tell process "Arx"
    set nodes to entire contents of window 1
  end tell
  repeat with nodeRef in nodes
    set node to contents of nodeRef
    if my optionalAttribute(node, "AXIdentifier") is expectedID then
      tell application "System Events" to perform action "AXPress" of node
      return
    end if
  end repeat
  error "No element with identifier " & expectedID
end pressIdentifier
on setField(groupIndex, fieldIndex, newValue)
  tell application "System Events" to tell process "Arx"
    set frontmost to true
    set targetField to text field fieldIndex of (my detailGroup(groupIndex))
    set focused of targetField to true
    delay 0.3
    keystroke "a" using command down
    keystroke newValue
    keystroke return
  end tell
end setField
on logStatics(tag, containerRef)
  repeat with nodeRef in containerRef
    set node to contents of nodeRef
    if my optionalAttribute(node, "AXRole") is "AXStaticText" then
      log (tag & "|" & (my optionalAttribute(node, "AXValue") as text))
    end if
  end repeat
end logStatics
on logStatus()
  tell application "System Events" to tell process "Arx"
    set nodes to entire contents of scroll area 1 of group 2 of splitter group 1 of group 1 of window 1
  end tell
  my logStatics("STATUS", nodes)
end logStatus
on logClients()
  tell application "System Events" to tell process "Arx"
    set nodes to entire contents of (my detailGroup(3))
  end tell
  my logStatics("CLIENT", nodes)
end logClients
on logLabels()
  tell application "System Events" to tell process "Arx"
    set nodes to entire contents of window 1
  end tell
  set wanted to {"list-grant-inbox", "list-grant-weekend", "list-grant-later", "list-grant-readonly"}
  set found to {}
  repeat with nodeRef in nodes
    set node to contents of nodeRef
    if my optionalAttribute(node, "AXRole") is "AXCheckBox" then
      set identifier to my optionalAttribute(node, "AXIdentifier") as text
      if wanted contains identifier then
        if found contains identifier then error "Duplicate list toggle identifier: " & identifier
        set end of found to identifier
        log ("CHECKBOX|" & identifier)
        repeat with attributeRef in {"AXTitle", "AXDescription", "AXLabel", "AXHelp"}
          set attributeName to contents of attributeRef
          log ("  " & attributeName & "=" & (my optionalAttribute(node, attributeName) as text))
        end repeat
      end if
    end if
  end repeat
  if (count of found) is not 4 then error "Expected 4 list toggles, found " & (count of found)
end logLabels
on run argv
  tell application "System Events" to tell process "Arx" to set frontmost to true
  if item 1 of argv is "labels" then
    my logLabels()
  else if item 1 of argv is "status" then
    my logStatus()
  else if item 1 of argv is "clients" then
    my logClients()
  else if item 1 of argv is "setfield" then
    my setField((item 2 of argv) as integer, (item 3 of argv) as integer, item 4 of argv)
  else if item 1 of argv is "press" then
    my pressButton((item 2 of argv) as integer, (item 3 of argv) as integer)
  else if item 1 of argv is "pressid" then
    my pressIdentifier(item 2 of argv)
  else
    error "Unknown probe command: " & item 1 of argv
  end if
end run
APPLESCRIPT
}
export -f native
# --- bounded execution helpers --------------------------------------------
# bounded LIMIT OUTCOME_FILE COMMAND [ARGS...]
# Runs COMMAND through a python3 supervisor in its own process group.
#  - The leader runs up to LIMIT seconds; on expiry the whole group (children
#    and grandchildren) is SIGKILLed and reaped.
#  - After the leader exits, the group gets a short grace to finish; lingering
#    descendants are then killed, so a pipe-holding grandchild cannot keep an
#    outer command substitution open.
#  - Child stdout/stderr pass through pipes the supervisor owns and relays, so
#    the supervisor's exit always closes any outer capture.
#  - On SIGTERM/SIGINT/SIGHUP (runner cancellation) the supervisor kills the
#    group before dying.
# The outcome is out-of-band: the supervisor writes exactly one token to
# OUTCOME_FILE - "ok", "failed:<exit>" (the leader's own status, including a
# leader that itself exits 124), "failed:signaled", or "timeout" - and exits 0
# unless the supervisor itself failed, so no exit code is ambiguous.
bounded() {
  local limit="$1" outcome_file="$2"; shift 2
  : > "${outcome_file}"
  # Never exits nonzero: a supervisor-internal failure (including a missing
  # python3) becomes a typed "supervisor-error" outcome, so callers read one
  # channel and no call site needs a condition around this function.
  python3 - "${limit}" "${outcome_file}" bash -c '"$@"' bounded-invoke "$@" <<'PYBOUNDED' || printf 'supervisor-error' > "${outcome_file}"
import os, signal, subprocess, sys, threading, time

limit = float(sys.argv[1])
outcome_path = sys.argv[2]
cmd = sys.argv[3:]
grace = 2.0

# Block cancellation signals before the child exists so a runner cancel
# landing between Popen and handler registration is held pending, then
# delivered to the installed handler. The child's original mask is restored
# before exec so supervised commands see ordinary signal semantics. A cancel
# landing before the supervisor itself starts (shell -> python exec) remains
# outside this protection and can orphan the group; that interval is stated,
# not claimed covered.
watched = (signal.SIGTERM, signal.SIGINT, signal.SIGHUP)
saved_mask = signal.pthread_sigmask(signal.SIG_BLOCK, watched)

def restore_child_mask():
    signal.pthread_sigmask(signal.SIG_SETMASK, saved_mask)

proc = subprocess.Popen(cmd, start_new_session=True,
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                        preexec_fn=restore_child_mask)

def relay(stream, target):
    try:
        while True:
            chunk = stream.read1(65536)
            if not chunk:
                return
            target.write(chunk)
            target.flush()
    except (ValueError, OSError):
        return

out_thread = threading.Thread(target=relay, args=(proc.stdout, sys.stdout.buffer), daemon=True)
err_thread = threading.Thread(target=relay, args=(proc.stderr, sys.stderr.buffer), daemon=True)
out_thread.start()
err_thread.start()

signaled = False
def kill_group():
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass
def handler(signum, frame):
    global signaled
    signaled = True
for sig in watched:
    signal.signal(sig, handler)
signal.pthread_sigmask(signal.SIG_UNBLOCK, watched)

deadline = time.monotonic() + limit
outcome = None
while True:
    rc = proc.poll()
    if rc is not None:
        # Flush output up to the grace window, then unconditionally reconcile
        # the owned group: a descendant that closed its descriptors is just as
        # dead to us as one still holding them.
        gdeadline = time.monotonic() + grace
        while time.monotonic() < gdeadline and (out_thread.is_alive() or err_thread.is_alive()):
            time.sleep(0.05)
        kill_group()
        proc.wait()
        if signaled:
            outcome = "failed:signaled"
        else:
            outcome = "ok" if rc == 0 else "failed:%d" % rc
        break
    if signaled:
        kill_group()
        proc.wait()
        outcome = "failed:signaled"
        break
    if time.monotonic() > deadline:
        kill_group()
        proc.wait()
        outcome = "timeout"
        break
    time.sleep(0.05)

out_thread.join(timeout=5)
err_thread.join(timeout=5)
with open(outcome_path, "w") as handle:
    handle.write(outcome)
if signaled:
    signal.signal(signal.SIGTERM, signal.SIG_DFL)
    os.kill(os.getpid(), signal.SIGTERM)
sys.exit(0)
PYBOUNDED
  return 0
}
# probe_call LIMIT STAGE COMMAND [ARGS...]
# A probe call that must succeed. A timeout, failure, or supervisor error is a
# typed harness failure recorded by fixed stage token (never raw argv, so no
# secret can reach the evidence file) and aborts the script: polling a wedged
# AX session again cannot recover it.
probe_call() {
  local limit="$1" stage="$2"; shift 2
  local outcome
  bounded "${limit}" "${OUTCOME_FILE}" "$@"
  outcome=$(cat "${OUTCOME_FILE}" 2>/dev/null || true)
  case "${outcome}" in
    ok) ;;
    timeout)
      echo "HARNESS FAILURE: probe stage ${stage} timed out after ${limit}s" >>"${OUT}"
      exit 1 ;;
    failed:*|supervisor-error)
      echo "HARNESS FAILURE: probe stage ${stage} ${outcome}" >>"${OUT}"
      exit 1 ;;
    *)
      echo "HARNESS FAILURE: probe stage ${stage} produced no typed outcome" >>"${OUT}"
      exit 1 ;;
  esac
}
# Bounded TERM-then-KILL for a direct child pid (the total watchdog); polls
# up to LIMIT seconds before the KILL and reaps with wait.
bounded_reap() {
  local pid="$1" limit="$2" _
  for _ in $(seq 1 "${limit}"); do
    if ! kill -0 "${pid}" 2>/dev/null; then
      wait "${pid}" 2>/dev/null || true
      return 0
    fi
    sleep 1
  done
  kill -KILL "${pid}" 2>/dev/null || true
  wait "${pid}" 2>/dev/null || true
  return 0
}
# Bounded wait for a whole process GROUP (the app, which is not our child and
# is reaped by init, never by us). Existence is checked on the group, not the
# leader, so a leader that exits first cannot hide surviving members.
bounded_reap_group() {
  local pgid="$1" limit="$2" _
  for _ in $(seq 1 "${limit}"); do
    kill -0 -- -"${pgid}" 2>/dev/null || return 0
    sleep 1
  done
  return 0
}
OUTCOME_FILE="${TMPDIR:-/tmp}/arx-probe-outcome.$$"
: > "${OUTCOME_FILE}"
# Per-call bounds; environment overrides exist only so the harness's own
# integration tests can run with tiny limits. CI uses the defaults.
LABELS_LIMIT="${ARX_PROBE_LIMIT_LABELS:-180}"
CLIENTS_LIMIT="${ARX_PROBE_LIMIT_CLIENTS:-120}"
PRESSID_LIMIT="${ARX_PROBE_LIMIT_PRESSID:-120}"
CALL_LIMIT="${ARX_PROBE_LIMIT_CALL:-60}"
PASTE_LIMIT="${ARX_PROBE_LIMIT_PASTE:-10}"
WINDOW_LIMIT="${ARX_PROBE_LIMIT_WINDOW:-15}"
# Total backstop. TERM is trapped so the bounded cleanup still runs; bash
# defers a TERM trap while blocked in a command substitution. Conservative
# worst case, not a hard wallclock guarantee (OS scheduling and
# uninterruptible sleeps are outside it): TOTAL_LIMIT (900s) + the longest
# per-call bound (180s nominal + up to 2s group grace + up to 10s relay
# joins) + bounded cleanup (~60s: watchdog reap 5s, app group TERM/poll 10s,
# and two pasteboard calls at 10s nominal + 12s overhead each) is about
# 1150s. Cleanup is killed-watchdog-first, so it rests on its own finite
# waits, not on the KILL fallback. The KILL after a grace period is the last
# resort if even that deferral fails; it skips cleanup. The watchdog is a
# single python3 process with no children, so killing its pid fully owns it.
TOTAL_LIMIT="${ARX_PROBE_LIMIT_TOTAL:-900}"
TOTAL_GRACE=200
python3 - "${TOTAL_LIMIT}" "${TOTAL_GRACE}" "$$" "${OUT}" <<'PYWATCHDOG' &
import os, signal, sys, time
limit, grace, target, out_path = float(sys.argv[1]), float(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
time.sleep(limit)
try:
    with open(out_path, "a") as handle:
        handle.write("HARNESS FAILURE: total probe time exceeded %ds" % limit + chr(10))
except OSError:
    pass
try:
    os.kill(target, signal.SIGTERM)
except (ProcessLookupError, PermissionError):
    sys.exit(0)
time.sleep(grace)
try:
    os.kill(target, signal.SIGKILL)
except (ProcessLookupError, PermissionError):
    pass
PYWATCHDOG
TOTAL_WATCHDOG=$!
trap 'exit 1' TERM INT

launch() {
  if [[ -n "${PID}" ]]; then
    kill -TERM -- -"${PID}" 2>/dev/null || true
    bounded_reap_group "${PID}" 10
    kill -KILL -- -"${PID}" 2>/dev/null || true
  fi
  # Spawn the app in its own session so cleanup can kill its whole group.
  PID=$(python3 - "${APP}/Contents/MacOS/Arx" --bridge-fixtures "$@" <<'PYSPAWN'
import subprocess, sys
log = open("fixture-probe.log", "ab")
proc = subprocess.Popen(sys.argv[1:], start_new_session=True, stdout=log, stderr=subprocess.STDOUT)
print(proc.pid)
PYSPAWN
)
  local bounds _ window_outcome
  for _ in $(seq 1 30); do
    bounds=$(bounded "${WINDOW_LIMIT}" "${OUTCOME_FILE}" osascript -e 'tell application "System Events" to tell process "Arx" to get (position of window 1) & (size of window 1)' 2>/dev/null)
    window_outcome=$(cat "${OUTCOME_FILE}" 2>/dev/null || true)
    case "${window_outcome}" in
      ok) [[ -n "${bounds}" ]] && return 0 ;;
      failed:*) ;; # window not up yet; keep polling
      *)
        echo "HARNESS FAILURE: probe stage window-bounds ${window_outcome:-no-outcome}" >>"${OUT}"
        exit 1 ;;
    esac
    sleep 1
  done
  echo "HARNESS FAILURE: probe stage window-bounds no app window after 30 attempts" >>"${OUT}"
  exit 1
}
STATUS_FOUND=0
wait_status() {
  local pattern="$1" _ snapshot status_outcome
  STATUS_FOUND=0
  for _ in $(seq 1 60); do
    snapshot=$(bounded "${CALL_LIMIT}" "${OUTCOME_FILE}" native status 2>&1)
    status_outcome=$(cat "${OUTCOME_FILE}" 2>/dev/null || true)
    case "${status_outcome}" in
      ok)
        if [[ "${snapshot}" == *"${pattern}"* ]]; then
          STATUS_FOUND=1
          return 0
        fi ;;
      failed:*) ;; # transient query failure while the bridge comes up; keep polling
      *)
        echo "HARNESS FAILURE: probe stage wait-status ${status_outcome:-no-outcome}" >>"${OUT}"
        exit 1 ;;
    esac
    sleep 1
  done
  return 0
}
echo "== #28: exposed label and help attributes of the list toggles ==" >>"${OUT}"
launch
probe_call "${LABELS_LIMIT}" ax-labels native labels >>"${OUT}" 2>&1
echo "== #30(c): overlong pairing label while the service runs ==" >>"${OUT}"
probe_call "${CALL_LIMIT}" set-bridge-url native setfield 1 1 "https://bridge.example.test"
probe_call "${PRESSID_LIMIT}" press-bridge-start native pressid bridge-start
wait_status "Listening on 127.0.0.1:8765"
if [[ "${STATUS_FOUND}" -ne 1 ]]; then
  echo "HARNESS FAILURE: bridge did not start; status lines follow" >>"${OUT}"
  probe_call "${CALL_LIMIT}" bridge-status-after-refusal native status >>"${OUT}" 2>&1
  exit 1
fi
printf -v LONG_LABEL '%081d' 0
probe_call "${CALL_LIMIT}" set-long-label native setfield 2 1 "${LONG_LABEL}"
probe_call "${CALL_LIMIT}" pair-long-label native press 2 1
sleep 1
{
  echo "status after an 81-character label and Pair:"
  probe_call "${CALL_LIMIT}" status-after-long-label native status
} >>"${OUT}" 2>&1
echo "== #30(a): client status before and after manual refresh ==" >>"${OUT}"
probe_call "${CALL_LIMIT}" set-client-name native setfield 2 1 "Browser client"
probe_call "${CALL_LIMIT}" pair-client native press 2 1
sleep 1
BASELINE_CLIENTS=$(probe_call "${CLIENTS_LIMIT}" clients-baseline native clients 2>&1)
{
  echo "client rows BEFORE pair exchange (baseline):"
  echo "${BASELINE_CLIENTS}"
} >>"${OUT}" 2>&1
if [[ "${BASELINE_CLIENTS}" != *"Browser client"* || "${BASELINE_CLIENTS}" != *"Awaiting pairing"* ]]; then
  echo "HARNESS FAILURE: baseline client row for the new client is missing or not awaiting pairing" >>"${OUT}"
  exit 1
fi
probe_call "${CALL_LIMIT}" copy-secret native press 2 2
SECRET=$(probe_call "${PASTE_LIMIT}" read-secret pbpaste)
if [[ -z "${SECRET}" ]]; then
  echo "HARNESS FAILURE: no pairing secret on the pasteboard" >>"${OUT}"
  exit 1
fi
PAIR_HEADERS=$(mktemp)
PAIR_BODY=$(mktemp)
HTTP_CODE=$(curl -sS --max-time 15 -D "${PAIR_HEADERS}" -o "${PAIR_BODY}" -w '%{http_code}' \
  -H "Host: bridge.example.test" \
  -H "X-Forwarded-Proto: https" \
  -H "Origin: https://bridge.example.test" \
  -H "Content-Type: application/json" \
  -d "{\"secret\":\"${SECRET}\"}" \
  http://127.0.0.1:8765/api/pair) || HTTP_CODE="curl-failed"
COOKIE_OK=0
if grep -qiE '^set-cookie: __Host-arx=[^;[:space:]]+' "${PAIR_HEADERS}"; then
  COOKIE_OK=1
fi
JSON_OK=0
if python3 - "${PAIR_BODY}" <<'PY'
import json, sys
try:
    with open(sys.argv[1]) as handle:
        body = json.load(handle)
except Exception:
    sys.exit(1)
csrf = body.get("csrf") if isinstance(body, dict) else None
rights = body.get("rights") if isinstance(body, dict) else None
ok = isinstance(csrf, str) and len(csrf) > 0 and isinstance(rights, dict) and len(rights) > 0
sys.exit(0 if ok else 1)
PY
then
  JSON_OK=1
fi
rm -f "${PAIR_HEADERS}" "${PAIR_BODY}"
PAIR_HEADERS=""
PAIR_BODY=""
if [[ "${HTTP_CODE}" != "200" || "${COOKIE_OK}" -ne 1 || "${JSON_OK}" -ne 1 ]]; then
  echo "HARNESS FAILURE: pair exchange not admitted (HTTP ${HTTP_CODE}); response contents withheld" >>"${OUT}"
  exit 1
fi
{
  echo "pair exchange admitted: HTTP 200, typed session response (non-empty csrf string and rights object), non-empty session cookie; values withheld"
  echo "client rows AFTER pair exchange, BEFORE manual refresh:"
  probe_call "${CLIENTS_LIMIT}" clients-after-pair native clients
} >>"${OUT}" 2>&1
probe_call "${CALL_LIMIT}" press-refresh native press 3 1
sleep 1
POST_REFRESH=$(probe_call "${CLIENTS_LIMIT}" clients-after-refresh native clients 2>&1)
{
  echo "client rows AFTER manual refresh:"
  echo "${POST_REFRESH}"
} >>"${OUT}" 2>&1
if [[ "${POST_REFRESH}" != *"Browser client"* || "${POST_REFRESH}" != *"Paired"* ]]; then
  echo "HARNESS FAILURE: refreshed client row does not show the admitted pairing" >>"${OUT}"
  exit 1
fi
echo "== #30(b): status message across a simulated store change (status-overwrite facet only; the synthetic stopping state is NOT a real listener bind failure) ==" >>"${OUT}"
launch --fixture-stopping --fixture-store-change
BEFORE_SNAP=""
for _ in $(seq 1 30); do
  SNAP=$(bounded "${CALL_LIMIT}" "${OUTCOME_FILE}" native status 2>&1)
  snap_outcome=$(cat "${OUTCOME_FILE}" 2>/dev/null || true)
  case "${snap_outcome}" in
    ok) ;;
    failed:*) SNAP="" ;; # transient query failure; keep polling
    *)
      echo "HARNESS FAILURE: probe stage stopping-baseline ${snap_outcome:-no-outcome}" >>"${OUT}"
      exit 1 ;;
  esac
  if [[ "${SNAP}" == *"Access revoked. Waiting for the local listener to stop."* ]]; then
    BEFORE_SNAP="${SNAP}"
    break
  fi
  if [[ "${SNAP}" == *"Choose lists and actions"* ]]; then
    break
  fi
  sleep 1
done
if [[ -z "${BEFORE_SNAP}" ]]; then
  echo "HARNESS INCONCLUSIVE: the stopping-state baseline message was not observed before the simulated store change" >>"${OUT}"
  exit 1
fi
{
  echo "status BEFORE the simulated store change:"
  echo "${BEFORE_SNAP}"
} >>"${OUT}" 2>&1
sleep 12
{
  echo "status AFTER the simulated store change:"
  probe_call "${CALL_LIMIT}" status-after-store-change native status
} >>"${OUT}" 2>&1
echo "Probes complete; evidence recorded in ${OUT}."
