#!/bin/zsh
# Bumps PiDF's version in project.yml and opens a CHANGELOG entry.
# Usage: ./scripts/bump-version.sh minor   (new features or improvements: 1.0.0 -> 1.1.0)
#        ./scripts/bump-version.sh patch   (fixes only:                    1.0.0 -> 1.0.1)
#        ./scripts/bump-version.sh major   (big changes:                   1.0.0 -> 2.0.0)
set -euo pipefail
cd "$(dirname "$0")/.."

part="${1:-}"
[[ "$part" == (major|minor|patch) ]] || { echo "Usage: $0 major|minor|patch"; exit 1; }

current=$(sed -nE 's/^ *MARKETING_VERSION: "([0-9]+\.[0-9]+\.[0-9]+)"/\1/p' project.yml)
build=$(sed -nE 's/^ *CURRENT_PROJECT_VERSION: "([0-9]+)"/\1/p' project.yml)
[[ -n "$current" && -n "$build" ]] || { echo "Version not found in project.yml"; exit 1; }

IFS=. read -r major minor patch <<< "$current"
case "$part" in
  major) major=$((major + 1)); minor=0; patch=0 ;;
  minor) minor=$((minor + 1)); patch=0 ;;
  patch) patch=$((patch + 1)) ;;
esac
next="$major.$minor.$patch"
nextBuild=$((build + 1))

sed -i '' -E "s/^( *MARKETING_VERSION: )\"$current\"/\1\"$next\"/" project.yml
sed -i '' -E "s/^( *CURRENT_PROJECT_VERSION: )\"$build\"/\1\"$nextBuild\"/" project.yml

entry="## $next — $(date +%Y-%m-%d)\n\n- \n\n"
awk -v entry="$entry" '!done && /^## / { printf entry; done = 1 } { print }' CHANGELOG.md > CHANGELOG.md.tmp
mv CHANGELOG.md.tmp CHANGELOG.md

echo "PiDF $current ($build) -> $next ($nextBuild). Describe the changes in CHANGELOG.md."
