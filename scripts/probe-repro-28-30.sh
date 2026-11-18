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
cleanup() {
  if [[ -n "${PID}" ]] && kill -0 "${PID}" 2>/dev/null; then
    kill "${PID}" 2>/dev/null || true
  fi
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
  repeat with nodeRef in nodes
    set node to contents of nodeRef
    if my optionalAttribute(node, "AXRole") is "AXCheckBox" then
      set identifier to my optionalAttribute(node, "AXIdentifier") as text
      if wanted contains identifier then
        log ("CHECKBOX|" & identifier)
        repeat with attributeRef in {"AXTitle", "AXDescription", "AXLabel", "AXHelp"}
          set attributeName to contents of attributeRef
          log ("  " & attributeName & "=" & (my optionalAttribute(node, attributeName) as text))
        end repeat
      end if
    end if
  end repeat
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
launch() {
  if [[ -n "${PID}" ]] && kill -0 "${PID}" 2>/dev/null; then
    kill "${PID}" 2>/dev/null || true
    wait "${PID}" 2>/dev/null || true
  fi
  "${APP}/Contents/MacOS/Arx" --bridge-fixtures "$@" >fixture-probe.log 2>&1 &
  PID=$!
  local bounds _
  for _ in $(seq 1 30); do
    bounds=$(osascript -e 'tell application "System Events" to tell process "Arx" to get (position of window 1) & (size of window 1)' 2>/dev/null || true)
    [[ -n "${bounds}" ]] && return 0
    sleep 1
  done
  echo "No app window" >&2
  exit 1
}
STATUS_FOUND=0
wait_status() {
  local pattern="$1" _ snapshot
  STATUS_FOUND=0
  for _ in $(seq 1 60); do
    snapshot=$(native status 2>&1)
    if [[ "${snapshot}" == *"${pattern}"* ]]; then
      STATUS_FOUND=1
      return 0
    fi
    sleep 1
  done
  return 0
}
echo "== #28: exposed label and help attributes of the list toggles ==" >>"${OUT}"
launch
native labels >>"${OUT}" 2>&1
echo "== #30(c): overlong pairing label while the service runs ==" >>"${OUT}"
native setfield 1 1 "https://bridge.example.test"
native pressid bridge-start
wait_status "Listening on 127.0.0.1:8765"
if [[ "${STATUS_FOUND}" -ne 1 ]]; then
  echo "HARNESS FAILURE: bridge did not start; status lines follow" >>"${OUT}"
  native status >>"${OUT}" 2>&1
  exit 1
fi
printf -v LONG_LABEL '%081d' 0
native setfield 2 1 "${LONG_LABEL}"
native press 2 1
sleep 1
{
  echo "status after an 81-character label and Pair:"
  native status
} >>"${OUT}" 2>&1
echo "== #30(a): client status before and after manual refresh ==" >>"${OUT}"
native setfield 2 1 "Browser client"
native press 2 1
sleep 1
native press 2 2
SECRET=$(pbpaste)
if [[ -z "${SECRET}" ]]; then
  echo "HARNESS FAILURE: no pairing secret on the pasteboard" >>"${OUT}"
  exit 1
fi
if ! EXCHANGE=$(curl -sS --max-time 15 \
  -H "Host: bridge.example.test" \
  -H "X-Forwarded-Proto: https" \
  -H "Origin: https://bridge.example.test" \
  -H "Content-Type: application/json" \
  -d "{\"secret\":\"${SECRET}\"}" \
  http://127.0.0.1:8765/api/pair); then
  echo "HARNESS FAILURE: pair exchange request failed" >>"${OUT}"
  exit 1
fi
{
  echo "pair exchange response: ${EXCHANGE}"
  echo "client rows BEFORE manual refresh (pairing already exchanged):"
  native clients
} >>"${OUT}" 2>&1
native press 3 1
sleep 1
{
  echo "client rows AFTER manual refresh:"
  native clients
} >>"${OUT}" 2>&1
echo "== #30(b): unrelated store change versus the failure message ==" >>"${OUT}"
launch --fixture-stopping --fixture-store-change
{
  echo "status BEFORE the simulated store change:"
  native status
} >>"${OUT}" 2>&1
sleep 12
{
  echo "status AFTER the simulated store change:"
  native status
} >>"${OUT}" 2>&1
echo "Probes complete; evidence recorded in ${OUT}."
