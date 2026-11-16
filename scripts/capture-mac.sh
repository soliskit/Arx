#!/bin/bash
set -euo pipefail
APP="$PWD/.build/Build/Products/Debug/Arx.app"
[ -d "$APP" ] || { echo "Built app not found"; exit 1; }
"$APP/Contents/MacOS/Arx" --bridge-fixtures >fixture-app.log 2>&1 &
PID=$!
diagnostics() {
  osascript -e 'tell application "System Events" to tell process "Arx" to get entire contents of window 1' > navigation-accessibility.txt 2>&1 || true
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
  local actual aw ah
  osascript -e "tell application \"System Events\" to tell process \"Arx\" to set size of window 1 to {$1, $2}"
  sleep 1
  actual=$(osascript -e 'tell application "System Events" to tell process "Arx" to get size of window 1')
  IFS=', ' read -r aw ah <<< "${actual}"
  if [[ "$1" -lt 680 || "$2" -lt 420 ]]; then
    [[ "${aw}" -ge 680 && "${ah}" -ge 420 ]] || { echo "Minimum window too small: ${actual}"; exit 1; }
  else
    [[ "${aw}" -eq "$1" && "${ah}" -eq "$2" ]] || { echo "Resize mismatch: requested $1 x $2, actual ${actual}"; exit 1; }
  fi
}
check() {
  osascript - "$1" <<'APPLESCRIPT'
on run argv
  tell application "System Events" to tell process "Arx"
    set frontmost to true
    repeat with candidate in entire contents of window 1
      try
        set expectedID to "list-grant-" & (item 1 of argv)
        if value of attribute "AXIdentifier" of candidate is expectedID then
          if role of candidate is "AXCheckBox" then
            click candidate
          else
            click checkbox 1 of candidate
          end if
          delay 0.3
          return
        end if
      end try
    end repeat
    error "Fixture checkbox not found: " & item 1 of argv
  end tell
end run
APPLESCRIPT
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
