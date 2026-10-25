#!/bin/zsh
# Measures what PiDF costs with a document open: memory (as Activity Monitor
# shows it), CPU and wake-ups per second while idle, threads and app size.
# With --compare it also measures Preview and PDF Expert (if installed) on the
# same file. An app that is already running is skipped, so your own open
# documents are never closed.
# Usage: ./scripts/benchmark.sh [document.pdf] [--compare]
#        (without a document, a 300-page test document is generated)
set -euo pipefail
cd "$(dirname "$0")/.."
DOC=""; COMPARE=0
for arg in "$@"; do
  if [[ "$arg" == "--compare" ]]; then COMPARE=1; else DOC="${arg:A}"; fi
done
WARMUP=8
SAMPLES=10

xcodegen generate --quiet
xcodebuild -project PiDF.xcodeproj -scheme PiDF -configuration Release \
  -derivedDataPath build/Bench -quiet build
PIDF="$PWD/build/Bench/Build/Products/Release/PiDF.app"
if [[ -z "$DOC" ]]; then
  DOC="$PWD/build/Bench/benchmark.pdf"
  [[ -f "$DOC" ]] || swift scripts/make-test-pdf.swift "$DOC" 300 >/dev/null
fi
[[ -f "$DOC" ]] || { echo "No such document: $DOC"; exit 1; }

measure() {  # name, app path, process name, extra launch arguments
  local name="$1" app="$2" process="$3"
  shift 3
  if pgrep -xq "$process"; then
    printf "| %-10s | %s |\n" "$name" "skipped: already running"
    return
  fi
  open -a "$app" "$DOC" --args "$@"
  sleep $WARMUP
  local pid=$(pgrep -xn "$process")
  local stats=$(top -l $((SAMPLES + 1)) -s 1 -pid $pid -stats cpu,idlew,th | tr -d '+-' \
    | awk 'NR>1 && $1 ~ /^[0-9.]+$/' | tail -n $SAMPLES)
  local cpu=$(echo "$stats" | awk '{ s += $1 } END { printf "%.1f", s / NR }')
  local wakeups=$(echo "$stats" | awk 'NR == 1 { a = $2 } { b = $2 } END { printf "%.1f", (b - a) / (NR - 1) }')
  local threads=$(echo "$stats" | tail -1 | awk '{ print $3 }' | cut -d/ -f1)
  local memory=$(footprint -p $pid 2>/dev/null | sed -nE 's/.*Footprint: ([0-9.]+ [KMG]?B).*/\1/p' | head -1)
  local size=$(du -sh "$app" | cut -f1)
  printf "| %-10s | %8s | %6s %% | %8s | %7s | %5s |\n" "$name" "$memory" "$cpu" "$wakeups" "$threads" "$size"
  kill $pid 2>/dev/null || true
  while pgrep -xq "$process"; do sleep 0.2; done
}

echo "$(basename "$DOC") open and idle, averaged over $SAMPLES s after $WARMUP s:"
echo "| App        |   Memory |    CPU | Wake-ups | Threads |  Size |"
echo "|------------|----------|--------|----------|---------|-------|"
# Launch arguments hold for this run only and are never saved: the benchmark
# copy doesn't offer to become the default viewer, and no app reopens the
# document next time.
measure "PiDF" "$PIDF" PiDF -AskedToBecomeDefault YES
if (( COMPARE )); then
  measure "Preview" /System/Applications/Preview.app Preview -ApplePersistenceIgnoreState YES -NSQuitAlwaysKeepsWindows NO
  [[ -d "/Applications/PDF Expert.app" ]] && measure "PDF Expert" "/Applications/PDF Expert.app" "PDF Expert" -ApplePersistenceIgnoreState YES -NSQuitAlwaysKeepsWindows NO
fi
