#!/bin/bash
set -euo pipefail
APP="$PWD/.build/Build/Products/Debug/Arx.app"
[ -d "$APP" ] || { echo "Built app not found"; exit 1; }
"$APP/Contents/MacOS/Arx" --bridge-fixtures >fixture-app.log 2>&1 &
PID=$!
trap 'kill "$PID" 2>/dev/null || true' EXIT
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
resize() { osascript -e "tell application \"System Events\" to tell process \"Arx\" to set size of window 1 to {$1, $2}"; sleep 1; }
check() {
  osascript - "$1" <<'APPLESCRIPT'
on run argv
  tell application "System Events" to tell process "Arx"
    set frontmost to true
    repeat with candidate in entire contents of window 1
      try
        if role of candidate is "AXCheckBox" and name of candidate contains (item 1 of argv) then
          click candidate
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
check Inbox
capture wide-selected
check Weekend
capture wide-two-lists
check Later
capture wide-empty-list-selected
check Inbox
capture wide-list-deselected
resize 680 650
capture narrow
check Inbox
capture narrow-selected
check Weekend
capture narrow-deselected
check Weekend
capture narrow-restored
resize 400 200
capture minimum
sidebar
capture sidebar-hidden
sidebar
capture sidebar-restored
check Weekend
capture restored-weekend
check Inbox
capture restored-inbox
check Later
capture minimum-empty
check Later
capture minimum-selected
resize 1200 650
capture wide-return
osascript -e 'tell application "System Events" to tell process "Arx" to get entire contents of window 1' > navigation-accessibility.txt
capture diagnostic
