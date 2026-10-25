#!/bin/zsh
# Runs PiDF's tests on a Debug build. Prints only the failures and the
# totals, so a failing assertion shows its message (here and on CI).
# Usage: ./scripts/test.sh
set -euo pipefail
cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null || { echo "Install XcodeGen first: brew install xcodegen"; exit 1; }
xcodegen generate --quiet
xcodebuild -project PiDF.xcodeproj -scheme PiDF -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/Test test 2>&1 | grep -v 'com.apple.linkd' | grep -E '(error|failed|skipped):|^\*\* TEST|Executed [0-9]+ tests' | uniq
