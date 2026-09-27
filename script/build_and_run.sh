#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
MODE="${1:---app-build}"
case "$MODE" in
  --app-build|--app) ;;
  *) echo "Usage: $0 [--app-build|--app]" >&2; exit 2 ;;
esac
APP_NAME="MenubarOrganizer"
BUNDLE_ID="local.menubarorganizer.app"
APP_BUNDLE="$ROOT_DIR/dist/$APP_NAME.app"
mkdir -p "$ROOT_DIR/.build/cache"
CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/cache" swift build --disable-sandbox --product "$APP_NAME"
BIN_DIR="$(swift build --disable-sandbox --show-bin-path)"
/bin/rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
ditto "$BIN_DIR/MenubarOrganizer_MenubarOrganizer.bundle" "$APP_BUNDLE/Contents/Resources/MenubarOrganizer_MenubarOrganizer.bundle"
cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>$APP_NAME</string>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleName</key><string>$APP_NAME</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>ru</string></array>
<key>LSMinimumSystemVersion</key><string>27.0</string>
<key>LSUIElement</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
# A stable signing identity can preserve Accessibility permission across builds.
codesign --force --sign "${SIGN_IDENTITY:--}" "$APP_BUNDLE"
if [[ "$MODE" == "--app-build" ]]; then exit 0; fi
INSTALLED_APP="/Applications/$APP_NAME.app"
if [[ -e "$INSTALLED_APP" ]]; then
  EXISTING_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$INSTALLED_APP/Contents/Info.plist")"
  if [[ "$EXISTING_ID" != "$BUNDLE_ID" ]]; then
    echo "Refusing to replace an application with a different bundle ID: $INSTALLED_APP" >&2
    exit 1
  fi
fi
# Build before stopping an existing app so compiler errors leave it running.
pkill -TERM -x "$APP_NAME" >/dev/null 2>&1 || true
for _ in {1..50}; do
  if ! pgrep -u "$(id -u)" -x "$APP_NAME" >/dev/null 2>&1; then break; fi
  sleep 0.1
done
if pgrep -u "$(id -u)" -x "$APP_NAME" >/dev/null 2>&1; then
  echo "$APP_NAME did not quit; installation cancelled." >&2
  exit 1
fi
INSTALL_STAGE="$(mktemp -d /Applications/.MenubarOrganizer-install.XXXXXX)"
cleanup_install_stage() {
  if [[ -d "$INSTALL_STAGE" && ! -e "$INSTALL_STAGE/previous.app" ]]; then
    /bin/rm -rf "$INSTALL_STAGE"
  fi
}
trap cleanup_install_stage EXIT
/usr/bin/ditto "$APP_BUNDLE" "$INSTALL_STAGE/MenubarOrganizer.app"
codesign --verify --deep --strict "$INSTALL_STAGE/MenubarOrganizer.app"
if [[ -e "$INSTALLED_APP" ]]; then
  /bin/mv "$INSTALLED_APP" "$INSTALL_STAGE/previous.app"
fi
if ! /bin/mv "$INSTALL_STAGE/MenubarOrganizer.app" "$INSTALLED_APP"; then
  if [[ -e "$INSTALL_STAGE/previous.app" ]]; then
    /bin/mv "$INSTALL_STAGE/previous.app" "$INSTALLED_APP" || true
  fi
  echo "Installation failed; previous app kept at $INSTALL_STAGE/previous.app if restoration also failed." >&2
  exit 1
fi
/bin/rm -rf "$INSTALL_STAGE"
trap - EXIT
/usr/bin/open -n "$INSTALLED_APP"
