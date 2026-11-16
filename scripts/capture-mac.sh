#!/bin/bash
set -euo pipefail
APP="$PWD/.build/Build/Products/Debug/Arx.app"
[ -d "$APP" ] || { echo "Built app not found"; exit 1; }
"$APP/Contents/MacOS/Arx" --bridge-fixtures >fixture-app.log 2>&1 &
PID=$!
diagnostics() {
  osascript -e 'tell application "System Events" to tell process "Arx" to get entire contents of window 1' > navigation-accessibility.txt 2>&1 || true
  (set +e; native dump >> navigation-accessibility.txt 2>&1; :)
  if [[ -n "${BOUNDS:-}" ]]; then
    local x y w h current
    current=$(osascript -e 'tell application "System Events" to tell process "Arx" to get (position of window 1) & (size of window 1)' 2>/dev/null || true)
    IFS=', ' read -r x y w h <<< "${current}"
    if [[ -n "${h:-}" ]]; then screencapture -x -R"${x},${y},${w},${h}" arx-mac-failure.png || true; fi
  fi
  kill "$PID" 2>/dev/null || true
}
trap diagnostics EXIT
for i in $(seq 1 30); do
  BOUNDS=$(osascript -e 'tell application "System Events" to tell process "Arx" to get (position of window 1) & (size of window 1)' 2>/dev/null || true)
  [ -n "$BOUNDS" ] && break
  sleep 1
done
[ -n "$BOUNDS" ] || { echo "No app window"; exit 1; }
capture() {
  local b x y w h
  b=$(osascript -e 'tell application "System Events" to tell process "Arx" to get (position of window 1) & (size of window 1)')
  IFS=', ' read -r x y w h <<< "$b"
  echo "$1: $w x $h"
  [ "$w" -ge 680 ] && [ "$h" -ge 420 ]
  screencapture -x -R"$x,$y,$w,$h" "arx-mac-$1.png"
}
resize() {
  local actual aw ah attempt
  for attempt in $(seq 1 20); do
    osascript - "$1" "$2" <<'APPLESCRIPT'
on run argv
  tell application "System Events" to tell process "Arx"
    set frontmost to true
    set position of window 1 to {0, 25}
    set size of window 1 to {(item 1 of argv as integer), (item 2 of argv as integer)}
  end tell
end run
APPLESCRIPT
    sleep 0.2
    actual=$(osascript -e 'tell application "System Events" to tell process "Arx" to get size of window 1')
    IFS=', ' read -r aw ah <<< "${actual}"
    if [[ "$1" -lt 680 || "$2" -lt 420 ]]; then
      [[ "${aw}" -ge 680 && "${ah}" -ge 420 ]] && { verify_all; return; }
    elif [[ "${aw}" -eq "$1" && "${ah}" -eq "$2" ]]; then
      verify_all
      return
    fi
  done
  echo "Resize mismatch after ${attempt} attempts: requested $1 x $2, actual ${actual}"
  exit 1
}
native() {
  osascript - "$@" <<'APPLESCRIPT'
on attributeValue(node, key)
  tell application "System Events" to return value of attribute key of node
end attributeValue
on optionalAttribute(node, key)
  try
    return my attributeValue(node, key)
  on error
    return missing value
  end try
end optionalAttribute
on describeNode(node)
  log node
  repeat with keyRef in {"AXRole", "AXIdentifier", "AXTitle", "AXDescription", "AXValue", "AXEnabled"}
    set key to contents of keyRef
    try
      set found to my attributeValue(node, key)
      log (key & "=" & (found as text))
    on error messageText number errorNumber
      log (key & " ERROR " & errorNumber & ": " & messageText)
    end try
  end repeat
  tell application "System Events"
    try
      log ("actions=" & ((name of every action of node) as text))
    on error messageText number errorNumber
      log ("actions ERROR " & errorNumber & ": " & messageText)
    end try
  end tell
end describeNode
on findCheckbox(expectedID)
  tell application "System Events" to tell process "Arx"
    set root to outline 1 of scroll area 1 of group 1 of splitter group 1 of group 1 of window 1
    set nodes to entire contents of root
  end tell
  set matches to {}
  repeat with nodeRef in nodes
    set node to contents of nodeRef
    if my optionalAttribute(node, "AXIdentifier") is expectedID then
      set descendants to {node}
      tell application "System Events"
        if my optionalAttribute(node, "AXRole") is not "AXCheckBox" then set descendants to descendants & (entire contents of node)
      end tell
      repeat with childRef in descendants
        set childNode to contents of childRef
        if my optionalAttribute(childNode, "AXRole") is "AXCheckBox" then
          if matches does not contain childNode then set end of matches to childNode
        end if
      end repeat
    end if
  end repeat
  if (count of matches) is not 1 then error "Expected one actual checkbox for " & expectedID & ", found " & (count of matches)
  return item 1 of matches
end findCheckbox
on run argv
  if item 1 of argv is "dump" then
    tell application "System Events" to tell process "Arx" to set nodes to entire contents of window 1
    repeat with nodeRef in nodes
      my describeNode(contents of nodeRef)
    end repeat
    return
  end if
  set expectedID to "list-grant-" & (item 2 of argv)
  set expectedValue to item 3 of argv as integer
  tell application "System Events" to tell process "Arx" to set frontmost to true
  set target to my findCheckbox(expectedID)
  my describeNode(target)
  set beforeValue to my attributeValue(target, "AXValue") as integer
  if beforeValue is not expectedValue then error "Wrong prior checkbox state for " & expectedID & ": " & beforeValue
  if item 1 of argv is "verify" then return
  if my attributeValue(target, "AXEnabled") is not true then error "Disabled fixture checkbox: " & expectedID
  tell application "System Events"
    if (name of every action of target) does not contain "AXPress" then error "Fixture checkbox has no AXPress: " & expectedID
    perform action "AXPress" of target
  end tell
  repeat 20 times
    delay 0.1
    set target to my findCheckbox(expectedID)
    set afterValue to my attributeValue(target, "AXValue") as integer
    if afterValue is (1 - beforeValue) then return
  end repeat
  error "Fixture checkbox did not change state: " & expectedID
end run
APPLESCRIPT
}
INBOX=0
WEEKEND=0
LATER=0
check() {
  local key before
  case "$1" in
    inbox) key=INBOX ;;
    weekend) key=WEEKEND ;;
    later) key=LATER ;;
    *) echo "Unknown fixture"; exit 1 ;;
  esac
  before=${!key}
  native click "$1" "$before"
  printf -v "$key" '%s' "$((1 - before))"
}
verify_all() {
  native verify inbox "$INBOX"
  native verify weekend "$WEEKEND"
  native verify later "$LATER"
}
sidebar() { osascript -e 'tell application "System Events" to tell process "Arx" to click button 1 of toolbar 1 of window 1'; sleep 1; }
resize 1200 650
capture wide
check inbox
capture wide-selected
check weekend
capture wide-two-lists
check later
capture wide-empty-list-selected
check inbox
capture wide-list-deselected
resize 680 650
capture narrow
check inbox
capture narrow-selected
check weekend
capture narrow-deselected
check weekend
capture narrow-restored
resize 400 200
capture minimum
sidebar
capture sidebar-hidden
sidebar
verify_all
capture sidebar-restored
check weekend
capture restored-weekend
check inbox
capture restored-inbox
check later
capture minimum-empty
check later
capture minimum-selected
resize 1200 650
capture wide-return
osascript -e 'tell application "System Events" to tell process "Arx" to get entire contents of window 1' > navigation-accessibility.txt
capture diagnostic
