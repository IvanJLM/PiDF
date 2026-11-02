#!/bin/zsh
# Runs PiDF's tests on a Debug build. Prints only the failures and the
# totals, so a failing assertion shows its message (here and on CI).
# Usage: ./scripts/test.sh
set -euo pipefail
cd "$(dirname "$0")/.."
trap ./scripts/forget-builds.sh EXIT  # keep build copies out of "Open With"
command -v xcodegen >/dev/null || { echo "Install XcodeGen first: brew install xcodegen"; exit 1; }
xcodegen generate --quiet
# On CI also each test as it starts, so a hang shows where it stopped.
shown='(error|failed|skipped):|^\*\* TEST|Executed [0-9]+ tests'
[[ -n "${CI:-}" ]] && shown="$shown|Test Case .* started"
xcodebuild -project PiDF.xcodeproj -scheme PiDF -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/Test test 2>&1 | grep --line-buffered -v 'com.apple.linkd' | grep --line-buffered -E "$shown" | uniq
