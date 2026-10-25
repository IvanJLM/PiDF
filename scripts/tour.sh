#!/bin/zsh
# Takes screenshots of PiDF's main states (title bar, tabs, find, two pages,
# Go to Page, password), for checking the look by eye.
# Usage: ./scripts/tour.sh [folder]   (default: build/Tour)
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="${1:-build/Tour}"
OUT="${OUT:A}"
rm -rf "$OUT"; mkdir -p "$OUT"
xcodegen generate --quiet
(
  set +e  # a failed capture must not stop the loop
  # The test writes a request file; capture that window, then remove it.
  for _ in {1..600}; do
    if [[ -f "$OUT/request" ]]; then
      read -r window name < "$OUT/request"
      screencapture -x -o -l "$window" "$OUT/$name.png" || true
      rm -f "$OUT/request"
    fi
    sleep 0.1
    if [[ -f "$OUT/done" ]]; then break; fi
  done
) &
TEST_RUNNER_PIDF_TOUR="$OUT" xcodebuild -project PiDF.xcodeproj -scheme PiDF -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath build/Test -quiet test -only-testing:PiDFTests/TourTests
touch "$OUT/done"; wait
ls "$OUT"/*.png
