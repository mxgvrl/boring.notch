#!/usr/bin/env bash
# Build Boring Notch from source and (re)install it into /Applications.
#
#   scripts/dev-install.sh            # Release build (default)
#   CONFIGURATION=Debug scripts/dev-install.sh
#
# Signs ad-hoc ("-"), so no Apple Developer account is needed. Hardened runtime is
# turned off: with it, dyld's library validation refuses to load the embedded
# ad-hoc-signed frameworks (MediaRemoteAdapter etc.) and the app dies at launch.
# It only matters for notarized distribution builds.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

CONFIGURATION="${CONFIGURATION:-Release}"
DERIVED_DATA="$REPO_ROOT/build"
APP_NAME="Boring Notch"
BUNDLE_ID="theboringteam.boringnotch"
BUILT_APP="$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME.app"
INSTALLED_APP="/Applications/$APP_NAME.app"
LOG="$DERIVED_DATA/dev-install.log"

mkdir -p "$DERIVED_DATA"

echo "==> Building $CONFIGURATION (log: $LOG)"
if ! xcodebuild \
    -project boringNotch.xcodeproj \
    -scheme boringNotch \
    -configuration "$CONFIGURATION" \
    -destination "generic/platform=macOS" \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGN_IDENTITY="-" \
    CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM="" \
    ENABLE_HARDENED_RUNTIME=NO \
    build >"$LOG" 2>&1; then
  echo "!! Build failed. Errors:" >&2
  grep -E "error:" "$LOG" | sort -u >&2 || tail -40 "$LOG" >&2
  exit 1
fi
echo "    Build succeeded: $BUILT_APP"

echo "==> Stopping running instance"
if pgrep -x "$APP_NAME" >/dev/null; then
  osascript -e "quit app id \"$BUNDLE_ID\"" >/dev/null 2>&1 || true
  for _ in {1..20}; do
    pgrep -x "$APP_NAME" >/dev/null || break
    sleep 0.5
  done
  if pgrep -x "$APP_NAME" >/dev/null; then
    echo "    Did not quit gracefully, killing"
    pkill -9 -x "$APP_NAME" || true
    sleep 0.5
  fi
else
  echo "    Not running"
fi

echo "==> Installing to $INSTALLED_APP"
rm -rf "$INSTALLED_APP"
ditto "$BUILT_APP" "$INSTALLED_APP"

echo "==> Launching"
open "$INSTALLED_APP"

# Give it a few seconds: a dyld/launch crash shows up as the process vanishing.
sleep 3
if pgrep -x "$APP_NAME" >/dev/null; then
  echo "    Running (pid $(pgrep -x "$APP_NAME"), commit $(git rev-parse --short HEAD))"
else
  echo "!! $APP_NAME is not running after launch; check ~/Library/Logs/DiagnosticReports/" >&2
  exit 1
fi
