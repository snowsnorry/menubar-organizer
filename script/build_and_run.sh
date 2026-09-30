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
ICON_SOURCE="$ROOT_DIR/Assets/AppIcon.png"
ICONSET_DIR="$ROOT_DIR/.build/AppIcon.iconset"
/bin/rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"
for SIZE in 16 32 128 256 512; do
  sips -z "$SIZE" "$SIZE" "$ICON_SOURCE" --out "$ICONSET_DIR/icon_${SIZE}x${SIZE}.png" >/dev/null
  DOUBLE_SIZE=$((SIZE * 2))
  sips -z "$DOUBLE_SIZE" "$DOUBLE_SIZE" "$ICON_SOURCE" --out "$ICONSET_DIR/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
python3 - "$ICONSET_DIR" "$APP_BUNDLE/Contents/Resources/AppIcon.icns" <<'PY'
from pathlib import Path
import struct
import sys

iconset, output = map(Path, sys.argv[1:])
representations = (
    (b"icp4", "icon_16x16.png"),
    (b"icp5", "icon_32x32.png"),
    (b"icp6", "icon_32x32@2x.png"),
    (b"ic07", "icon_128x128.png"),
    (b"ic08", "icon_256x256.png"),
    (b"ic09", "icon_512x512.png"),
    (b"ic10", "icon_512x512@2x.png"),
)
chunks = []
for kind, filename in representations:
    data = (iconset / filename).read_bytes()
    chunks.append(kind + struct.pack(">I", len(data) + 8) + data)
payload = b"".join(chunks)
output.write_bytes(b"icns" + struct.pack(">I", len(payload) + 8) + payload)
PY
cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>$APP_NAME</string>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleName</key><string>$APP_NAME</string>
<key>CFBundleIconFile</key><string>AppIcon.icns</string>
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
if pgrep -u "$(id -u)" -x "$APP_NAME" >/dev/null 2>&1; then
  # SIGTERM bypasses applicationShouldTerminate and strands removed menu extras.
  /usr/bin/osascript -e "tell application id \"$BUNDLE_ID\" to quit"
fi
for _ in {1..300}; do
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
