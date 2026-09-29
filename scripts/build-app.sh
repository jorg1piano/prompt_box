#!/bin/sh
# Builds build/PromptBox.app and registers it with Launch Services so promptbox:// URLs open it.
# Signs with the first Apple Development identity; override with SIGN_IDENTITY=<hash or name>.
set -eu
cd "$(dirname "$0")/.."

IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk '/Apple Development/ { print $2; exit }')}"
if [ -z "$IDENTITY" ]; then
  echo "No Apple Development signing identity found; signing ad hoc." >&2
  IDENTITY="-"
fi

swift build -c release --product PromptBox
APP=build/PromptBox.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/PromptBox" "$APP/Contents/MacOS/PromptBox"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --options runtime --sign "$IDENTITY" "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
echo "Built $APP"
