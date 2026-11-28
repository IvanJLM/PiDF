#!/bin/zsh
# Runs PiDF's tests on a Debug build. Prints only the failures and the
# totals, so a failing assertion shows its message (here and on CI).
# Usage: ./scripts/test.sh
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/tidy.sh  # nothing stays outside the project when done
generate
# On CI also each test as it starts, so a hang shows where it stopped.
shown='(error|failed|skipped):|^\*\* TEST|Executed [0-9]+ tests'
[[ -n "${CI:-}" ]] && shown="$shown|Test Case .* started"
xcbuild -project PiDF.xcodeproj -scheme PiDF -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/Test test 2>&1 | grep --line-buffered -v 'com.apple.linkd' | grep --line-buffered -E "$shown" | awk '$0 != last { print; fflush(); last = $0 }'
