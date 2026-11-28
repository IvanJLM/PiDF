#!/bin/zsh
# Runs a command and lists what it left outside the project: new entries in
# ~/Library (preferences, caches, application support, saved state, logs)
# and in the user's temporary and cache folders. Fails when one of them is
# PiDF's; what other apps created meanwhile is listed apart.
# Usage: ./scripts/leftovers.sh ./scripts/test.sh
#        LEFTOVERS_WAIT=30 ./scripts/leftovers.sh ./scripts/tour.sh
set -uo pipefail
(( $# )) || { echo "Usage: ./scripts/leftovers.sh command [arguments]"; exit 1; }
TEMP="$(getconf DARWIN_USER_TEMP_DIR)"; TEMP="${TEMP%/}"
CACHE="$(getconf DARWIN_USER_CACHE_DIR)"; CACHE="${CACHE%/}"
PLACES=(
  ~/Library/Preferences ~/Library/Preferences/ByHost ~/Library/Caches
  ~/Library/"Application Support" ~/Library/"Saved Application State"
  ~/Library/HTTPStorages ~/Library/WebKit ~/Library/Logs ~/Library/Logs/DiagnosticReports
  "$TEMP" "$TEMP/TemporaryItems" "$CACHE"
)
entries() {
  for place in $PLACES; do
    [[ -d "$place" ]] && ls -A1 "$place" | sed "s|^|$place/|"
  done | sort
}

before="$(entries)"
"$@"; result=$?
sleep "${LEFTOVERS_WAIT:-15}"  # preferences reach the disk a few seconds late
new="$(comm -13 <(echo "$before") <(entries))"
ours="$(echo "$new" | grep -i 'pidf' || true)"
others="$(echo "$new" | grep -vi 'pidf' || true)"

echo
if [[ -n "$others" ]]; then
  echo "New meanwhile, not PiDF's ($(echo "$others" | wc -l | tr -d ' ')):"
  echo "$others" | sed 's/^/  /'
fi
if [[ -n "$ours" ]]; then
  echo "LEFT BEHIND by PiDF ($(echo "$ours" | wc -l | tr -d ' ')):"
  echo "$ours" | sed 's/^/  /'
  exit 1
fi
echo "Nothing of PiDF's left outside the project."
exit $result
