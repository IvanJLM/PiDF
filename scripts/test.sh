#!/bin/zsh
# Runs PiDF's tests on a Debug build.
# Usage: ./scripts/test.sh
set -euo pipefail
cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null || { echo "Install XcodeGen first: brew install xcodegen"; exit 1; }
xcodegen generate --quiet
xcodebuild -project PiDF.xcodeproj -scheme PiDF -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath build/Test -quiet test
