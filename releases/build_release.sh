#!/bin/bash
set -e

# RightLayout Release Builder
# Creates a signed .app bundle and a notarized .dmg for distribution.
#
# Signing: SIGNING_IDENTITY, or the first "Developer ID Application" identity in
# the keychain; without one the app is signed ad hoc (local test builds only).
# Notarization (skipped when none is set):
#   NOTARY_KEY_PATH + NOTARY_KEY_ID [+ NOTARY_ISSUER_ID]  App Store Connect API key (.p8);
#                                                       the issuer only for team keys
#   NOTARY_KEYCHAIN_PROFILE                             profile from `xcrun notarytool store-credentials`

# This is a fork of RightLayout; it ships under its own name and bundle identifier
# (see TRADEMARKS.md). The executable keeps the upstream name so scripts still find it.
APP_NAME="RightLayout SergeyZh"
EXECUTABLE_NAME="RightLayout"
BUNDLE_ID="com.sergeyzh.rightlayout"
DMG_BASENAME="RightLayout-SergeyZh"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Use the version from the argument, or the build time (YYYYMMDD.HHMMSS, UTC)
if [ -n "$1" ]; then
    VERSION="$1"
else
    VERSION=$("$PROJECT_DIR/scripts/build_version.sh")
fi

BUILD_DIR="$SCRIPT_DIR/build"
APP_PATH="$BUILD_DIR/$APP_NAME.app"
DMG_PATH="$SCRIPT_DIR/$DMG_BASENAME-$VERSION.dmg"

echo "🚀 Building $APP_NAME v$VERSION"
echo "================================"

# Sync repo-level version metadata used by local runs and bundled builds.
"$PROJECT_DIR/scripts/sync_version.sh" "$VERSION"

# Clean
rm -rf "$BUILD_DIR"
rm -rf "$PROJECT_DIR/.build"
mkdir -p "$BUILD_DIR"

# Build release binary
echo "📦 Building release binary..."
cd "$PROJECT_DIR"
swift build -c release

BINARY_PATH=""
for candidate in \
    "$PROJECT_DIR/.build/release/RightLayoutApp" \
    "$PROJECT_DIR/.build/arm64-apple-macosx/release/RightLayoutApp" \
    "$PROJECT_DIR/.build/release/RightLayout" \
    "$PROJECT_DIR/.build/arm64-apple-macosx/release/RightLayout"
do
    if [ -f "$candidate" ]; then
        BINARY_PATH="$candidate"
        break
    fi
done

if [ -z "$BINARY_PATH" ]; then
    echo "❌ Release binary not found in .build output"
    exit 1
fi

# Create .app bundle structure
echo "📁 Creating app bundle..."
mkdir -p "$APP_PATH/Contents/MacOS"
mkdir -p "$APP_PATH/Contents/Resources"

# Copy binary
cp "$BINARY_PATH" "$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME"

# Apache-2.0 §4: ship the license and attribution notices with the app
cp "$PROJECT_DIR/LICENSE" "$PROJECT_DIR/NOTICE" "$APP_PATH/Contents/Resources/"

# Copy resource bundle (required by Swift Package Manager). It goes to Contents/Resources,
# not the bundle root: codesign rejects unsealed files there. Bundle.rightLayoutResources
# looks it up here.
BUNDLE_PATH="$PROJECT_DIR/.build/release/RightLayout_RightLayout.bundle"
if [ ! -d "$BUNDLE_PATH" ]; then
    echo "❌ Resource bundle not found: $BUNDLE_PATH"
    exit 1
fi
cp -R "$BUNDLE_PATH" "$APP_PATH/Contents/Resources/"

# Copy icon
ICON_SRC="$PROJECT_DIR/RightLayout/Assets.xcassets/AppIcon.appiconset/icon_512.png"
if [ -f "$ICON_SRC" ]; then
    mkdir -p "$BUILD_DIR/icon.iconset"
    sips -z 16 16 "$ICON_SRC" --out "$BUILD_DIR/icon.iconset/icon_16x16.png" >/dev/null
    sips -z 32 32 "$ICON_SRC" --out "$BUILD_DIR/icon.iconset/icon_16x16@2x.png" >/dev/null
    sips -z 32 32 "$ICON_SRC" --out "$BUILD_DIR/icon.iconset/icon_32x32.png" >/dev/null
    sips -z 64 64 "$ICON_SRC" --out "$BUILD_DIR/icon.iconset/icon_32x32@2x.png" >/dev/null
    sips -z 128 128 "$ICON_SRC" --out "$BUILD_DIR/icon.iconset/icon_128x128.png" >/dev/null
    sips -z 256 256 "$ICON_SRC" --out "$BUILD_DIR/icon.iconset/icon_128x128@2x.png" >/dev/null
    sips -z 256 256 "$ICON_SRC" --out "$BUILD_DIR/icon.iconset/icon_256x256.png" >/dev/null
    sips -z 512 512 "$ICON_SRC" --out "$BUILD_DIR/icon.iconset/icon_256x256@2x.png" >/dev/null
    sips -z 512 512 "$ICON_SRC" --out "$BUILD_DIR/icon.iconset/icon_512x512.png" >/dev/null
    cp "$PROJECT_DIR/RightLayout/Assets.xcassets/AppIcon.appiconset/icon_1024.png" "$BUILD_DIR/icon.iconset/icon_512x512@2x.png"
    iconutil -c icns "$BUILD_DIR/icon.iconset" -o "$APP_PATH/Contents/Resources/AppIcon.icns"
    rm -rf "$BUILD_DIR/icon.iconset"
fi

# Create Info.plist
cat > "$APP_PATH/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleExecutable</key>
    <string>$EXECUTABLE_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2024–2025 Alex Chernysh. Modifications copyright © 2026 SergeyZh. Licensed under the Apache License 2.0.</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
</dict>
</plist>
EOF

echo "✅ App bundle created: $APP_PATH"

# Sign the app with the hardened runtime and a secure timestamp (both required for
# notarization). No entitlements: RightLayout/OMFK.entitlements enables the App Sandbox,
# which rules out the keyboard event tap.
if [ -z "$SIGNING_IDENTITY" ]; then
    SIGNING_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)
fi

if [ -n "$SIGNING_IDENTITY" ]; then
    echo "🔏 Signing with: $SIGNING_IDENTITY"
    codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP_PATH"
else
    echo "⚠️  No Developer ID Application identity found, signing ad hoc (not for distribution)"
    codesign --force --sign - "$APP_PATH"
fi
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

# Build the DMG: the app and a link to /Applications to drag it onto.
echo "💿 Creating DMG..."
DMG_STAGING="$BUILD_DIR/dmg"
rm -rf "$DMG_STAGING" "$DMG_PATH"
mkdir -p "$DMG_STAGING"
cp -R "$APP_PATH" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_STAGING" -ov -format UDZO "$DMG_PATH"
rm -rf "$DMG_STAGING"

if [ -n "$SIGNING_IDENTITY" ]; then
    codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$DMG_PATH"
fi

# Notarize and staple. Notarizing the DMG covers the app inside it.
# Values pasted into secrets often carry a trailing newline, which notarytool rejects.
NOTARY_KEY_ID=$(printf '%s' "$NOTARY_KEY_ID" | tr -d '[:space:]')
NOTARY_ISSUER_ID=$(printf '%s' "$NOTARY_ISSUER_ID" | tr -d '[:space:]')
if [ -n "$NOTARY_KEY_PATH" ] && [ -n "$NOTARY_KEY_ID" ]; then
    NOTARY_AUTH=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID")
    # Team API keys need the issuer; individual keys must go without it.
    [ -n "$NOTARY_ISSUER_ID" ] && NOTARY_AUTH+=(--issuer "$NOTARY_ISSUER_ID")
elif [ -n "$NOTARY_KEYCHAIN_PROFILE" ]; then
    NOTARY_AUTH=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
else
    NOTARY_AUTH=()
fi

if [ ${#NOTARY_AUTH[@]} -gt 0 ]; then
    [ -n "$SIGNING_IDENTITY" ] || { echo "❌ Notarization needs a Developer ID signature"; exit 1; }
    echo "📨 Notarizing (this waits for Apple)..."
    if ! xcrun notarytool submit "$DMG_PATH" "${NOTARY_AUTH[@]}" --wait --output-format json \
        > "$BUILD_DIR/notary.json"; then
        cat "$BUILD_DIR/notary.json"
        exit 1
    fi
    cat "$BUILD_DIR/notary.json"
    STATUS=$(plutil -extract status raw "$BUILD_DIR/notary.json" 2>/dev/null || echo "unknown")
    if [ "$STATUS" != "Accepted" ]; then
        SUBMISSION_ID=$(plutil -extract id raw "$BUILD_DIR/notary.json" 2>/dev/null || true)
        [ -n "$SUBMISSION_ID" ] && xcrun notarytool log "$SUBMISSION_ID" "${NOTARY_AUTH[@]}" || true
        echo "❌ Notarization status: $STATUS"
        exit 1
    fi
    xcrun stapler staple "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"
    spctl --assess --type open --context context:primary-signature -vv "$DMG_PATH"
else
    echo "⚠️  Notarization skipped: no NOTARY_* credentials set"
fi

echo ""
echo "================================"
echo "📦 Release artifacts:"
echo "   App: $APP_PATH"
echo "   DMG: $DMG_PATH"
