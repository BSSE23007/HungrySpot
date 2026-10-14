#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Build requires macOS." >&2
  exit 1
fi

echo "=== Toolchain ==="
xcodebuild -version
swift --version

echo
echo "=== Running tests ==="
swift test --jobs 1

echo
echo "=== Building release executable ==="
swift build \
  --configuration release \
  --jobs 1

BUILD_DIR="$(swift build --configuration release --show-bin-path)"
EXECUTABLE="$BUILD_DIR/HungrySpot"

if [[ ! -f "$EXECUTABLE" ]]; then
  echo "Release executable was not produced at:"
  echo "$EXECUTABLE"
  exit 1
fi

APP_DIR="$PWD/build/The Hungry Spot.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

echo
echo "=== Creating macOS application bundle ==="

rm -rf "$APP_DIR"

mkdir -p "$MACOS"
mkdir -p "$RESOURCES"

cp "$EXECUTABLE" "$MACOS/The Hungry Spot"
chmod +x "$MACOS/The Hungry Spot"

# Start with the project's Info.plist if available.
if [[ -f "Configuration/Info.plist" ]]; then
  cp "Configuration/Info.plist" "$CONTENTS/Info.plist"
else
  cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
</dict>
</plist>
PLIST
fi

PLIST="$CONTENTS/Info.plist"

/usr/libexec/PlistBuddy -c "Delete :CFBundleExecutable" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string The Hungry Spot" "$PLIST"

/usr/libexec/PlistBuddy -c "Delete :CFBundleIdentifier" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string com.thehungryspot.pos" "$PLIST"

/usr/libexec/PlistBuddy -c "Delete :CFBundleName" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleName string The Hungry Spot" "$PLIST"

/usr/libexec/PlistBuddy -c "Delete :CFBundleDisplayName" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string The Hungry Spot" "$PLIST"

/usr/libexec/PlistBuddy -c "Delete :CFBundlePackageType" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "$PLIST"

/usr/libexec/PlistBuddy -c "Delete :LSMinimumSystemVersion" "$PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Add :LSMinimumSystemVersion string 12.0" "$PLIST"

# SwiftPM generates one or more resource bundles for targets using resources.
# Keep the normal resource location and satisfy Swift 5.7's generated
# Bundle.module accessor, which searches directly inside Bundle.main.bundleURL.
# Relative links remain valid when the application moves away from .build.
find "$BUILD_DIR" -maxdepth 1 -type d -name "*.bundle" -print0 |
while IFS= read -r -d '' bundle; do
  echo "Copying resource bundle: $(basename "$bundle")"
  cp -R "$bundle" "$RESOURCES/"
  bundle_name="$(basename "$bundle")"
  ln -s "Contents/Resources/$bundle_name" "$APP_DIR/$bundle_name"
done

for bundle_name in HungrySpot_HungrySpot.bundle HungrySpot_HungrySpotCore.bundle; do
  if [[ ! -d "$APP_DIR/$bundle_name" ]]; then
    echo "Required SwiftPM resource bundle is missing: $bundle_name" >&2
    exit 1
  fi
done

# Also copy the branding asset directly as a fallback.
if [[ -f "Sources/HungrySpot/Resources/Branding.jpg" ]]; then
  cp "Sources/HungrySpot/Resources/Branding.jpg" "$RESOURCES/Branding.jpg"
fi

echo
# Install the application icon.
if [[ ! -f "assets/AppIcon.icns" ]]; then
  echo "ERROR: assets/AppIcon.icns is missing." >&2
  exit 1
fi

cp "assets/AppIcon.icns" "$RESOURCES/AppIcon.icns"

/usr/libexec/PlistBuddy \
  -c "Delete :CFBundleIconFile" "$PLIST" 2>/dev/null || true

/usr/libexec/PlistBuddy \
  -c "Add :CFBundleIconFile string AppIcon" "$PLIST"

echo "=== Validating application bundle ==="

plutil -lint "$CONTENTS/Info.plist"

if [[ ! -x "$MACOS/The Hungry Spot" ]]; then
  echo "Application executable is missing."
  exit 1
fi

echo
echo "=========================================="
echo "BUILD SUCCESSFUL"
echo "=========================================="
echo
echo "Test suite completed successfully."
echo "Application:"
echo "$APP_DIR"
echo
echo "Launch with:"
echo "open \"$APP_DIR\""
echo
echo "This build is unsigned and intended for local testing on this Mac."
