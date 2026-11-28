#!/bin/bash
# Build Arx with Sections attribution: the supported way to get section names.
# Run from the repository root on a clean tracked tree. Any change, including an
# untracked file, makes the build unattributed and every section reads Unknown.
set -euo pipefail
cd "$(dirname "$0")/.."
DERIVED="${1:-.build/attributed}"
# Also sees untracked files, mode changes, submodules and assume-unchanged or skip-worktree files.
tree_state() {
  git -c core.fileMode=true status --porcelain=v1 --untracked-files=all --ignore-submodules=none
  git ls-files -v | grep -E '^([a-z]|S) ' || true
}
DIRTY=$(tree_state)
if [[ -n "${DIRTY}" ]]; then
  echo "The working tree is not clean. Commit or stash changes first; an unclean tree builds without attribution." >&2
  exit 1
fi
python3 -I -B scripts/sections-source-stamp.py --replace-generated-metadata-inputs
xcodebuild -resolvePackageDependencies -project Arx.xcodeproj -scheme Arx -onlyUsePackageVersionsFromResolvedFile
xcodebuild build -project Arx.xcodeproj -scheme Arx -configuration Debug \
  -xcconfig scripts/sections-attribution.xcconfig \
  -derivedDataPath "${DERIVED}"
python3 -I -B scripts/sections-verify-build-stamps.py attributed "${DERIVED}"
DIRTY=$(tree_state)
if [[ -n "${DIRTY}" ]]; then
  echo "The build changed the working tree; the result is not attributed." >&2
  exit 1
fi
echo "Attributed build verified: ${DERIVED}/Build/Products/Debug/Arx.app"
