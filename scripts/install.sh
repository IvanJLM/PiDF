#!/bin/zsh
# Builds PiDF in Release mode, installs it in /Applications and makes it the
# default app for PDF documents.
# Usage: ./scripts/install.sh
set -euo pipefail
cd "$(dirname "$0")/.."

command -v xcodegen >/dev/null || { echo "Install XcodeGen first: brew install xcodegen"; exit 1; }

# A stable signature keeps macOS from treating every update as a new app.
IDENTITY="${PIDF_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/"/ { print $2; exit }')
fi

xcodegen generate --quiet
xcodebuild -project PiDF.xcodeproj -scheme PiDF -configuration Release \
  -derivedDataPath build/DD -quiet build

APP="build/DD/Build/Products/Release/PiDF.app"
if [[ -n "$IDENTITY" ]]; then
  echo "Signing with: $IDENTITY"
  codesign --force --options runtime --sign "$IDENTITY" "$APP"
fi
osascript -e 'quit app "PiDF"' 2>/dev/null || true
while pgrep -xq PiDF; do sleep 0.2; done
rm -rf /Applications/PiDF.app
cp -R "$APP" /Applications/
echo "Installed /Applications/PiDF.app"

# Register the copy in /Applications so Finder offers it for PDFs.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/PiDF.app

# Becoming the default app needs your confirmation in macOS's own dialogs.
# PiDF asks for as few as it can and quits when done. Skip with --no-default.
if [[ "${1:-}" != "--no-default" ]]; then
  open -a /Applications/PiDF.app --args --make-default
fi
