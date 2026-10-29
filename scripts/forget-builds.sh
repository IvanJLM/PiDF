#!/bin/zsh
# Takes PiDF's build copies out of Finder's "Open With" menu. Xcode registers
# every app it builds with Launch Services, so each build folder showed up
# there as another PiDF, with its version. The files stay; only the copy in
# /Applications is offered for PDFs. The other scripts run this when done.
# Usage: ./scripts/forget-builds.sh
cd "$(dirname "$0")/.."
for app in build/*/Build/Products/*/PiDF.app(N); do
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$app" 2>/dev/null
done
exit 0  # an app that was not registered is fine
