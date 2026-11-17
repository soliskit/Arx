#!/bin/bash
set -euo pipefail
if [[ "${CI:-}" == true && "${ARX_FIXTURE_DISPLAY_READY:-}" != 1 ]]; then
  exec swift scripts/fixture-display.swift "$0"
fi
RUNNER_TEMP="${RUNNER_TEMP:-/tmp}"
APP="${PWD}/.build/Build/Products/Debug/Arx.app/Contents/MacOS/Arx"
[[ -x "${APP}" ]]
PID=""
cleanup() {
  if [[ -n "${PID}" ]]; then kill "${PID}" 2>/dev/null || true; wait "${PID}" 2>/dev/null || true; fi
}
trap cleanup EXIT
for STAGE in selection result; do
  ARGS=(--sections-local-fixtures)
  if [[ "${STAGE}" == result ]]; then ARGS+=(--sections-local-fixture-result); fi
  "${APP}" "${ARGS[@]}" > "${RUNNER_TEMP}/sections-fixture-${STAGE}.log" 2>&1 &
  PID=$!
  READY=""
  for _ in $(seq 1 30); do
    READY=$(osascript -e 'tell application "System Events" to tell process "Arx" to get name of window 1' 2>/dev/null || true)
    [[ -n "${READY}" ]] && break
    sleep 0.2
  done
  [[ -n "${READY}" ]] || { echo "Missing fixture window"; exit 1; }
  osascript <<'APPLESCRIPT'
  tell application "System Events" to tell process "Arx"
    set frontmost to true
    set position of window 1 to {0, 25}
    set size of window 1 to {780, 820}
  end tell
APPLESCRIPT
  sleep 0.5
  BOUNDS=$(osascript -e 'tell application "System Events" to tell process "Arx" to get (position of window 1) & (size of window 1)')
  IFS=', ' read -r X Y W H <<< "${BOUNDS}"
  [[ "${W}" -ge 680 && "${H}" -ge 420 ]]
  screencapture -x -R"${X},${Y},${W},${H}" "arx-mac-sections-${STAGE}.png"
  cleanup
  PID=""
  sleep 0.3
done
