#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESOURCES_DIR="$PROJECT_DIR/Resources"
DIST_DIR="$PROJECT_DIR/dist"
APP_BUNDLE_NAME="IELTS-Vocab.app"
EXECUTABLE_NAME="IELTS-Vocab"
BUNDLE_ID="com.ielts.vocab"
VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$RESOURCES_DIR/Info.plist")}"
SIGNING_IDENTITY="${SIGNING_IDENTITY:--}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
OUTPUT_BASENAME="LorenVocabulary-${VERSION}-macOS-universal"
OUTPUT_DMG="$DIST_DIR/$OUTPUT_BASENAME.dmg"
CHECKSUM_FILE="$OUTPUT_DMG.sha256"

case "$VERSION" in
    ''|*[!0-9A-Za-z.-]*)
        echo "Invalid version: $VERSION" >&2
        exit 2
        ;;
esac

for tool in swift lipo codesign hdiutil; do
    command -v "$tool" >/dev/null || {
        echo "Missing required tool: $tool" >&2
        exit 1
    }
done

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/loren-vocabulary-release.XXXXXX")"
cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

APP_PATH="$TEMP_DIR/$APP_BUNDLE_NAME"
DMG_ROOT="$TEMP_DIR/dmg-root"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources" "$DMG_ROOT"
mkdir -p "$DIST_DIR"

echo "Building Apple Silicon release..."
swift build --package-path "$PROJECT_DIR" -c release --arch arm64
ARM_BIN_DIR="$(swift build --package-path "$PROJECT_DIR" -c release --arch arm64 --show-bin-path)"

echo "Building Intel release..."
swift build --package-path "$PROJECT_DIR" -c release --arch x86_64
X86_BIN_DIR="$(swift build --package-path "$PROJECT_DIR" -c release --arch x86_64 --show-bin-path)"

lipo -create \
    "$ARM_BIN_DIR/$EXECUTABLE_NAME" \
    "$X86_BIN_DIR/$EXECUTABLE_NAME" \
    -output "$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME"

cp "$RESOURCES_DIR/Info.plist" "$APP_PATH/Contents/Info.plist"
cp "$RESOURCES_DIR/AppIcon.icns" "$APP_PATH/Contents/Resources/AppIcon.icns"
chmod +x "$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME"

# Public releases must never contain local credentials or unverified private data.
test ! -e "$APP_PATH/Contents/Resources/Config.plist"
test ! -e "$APP_PATH/Contents/Resources/words.db"

codesign_args=(
    --force
    --deep
    --options runtime
    --identifier "$BUNDLE_ID"
    --sign "$SIGNING_IDENTITY"
)
if [ "$SIGNING_IDENTITY" = "-" ]; then
    codesign_args+=(--timestamp=none)
else
    codesign_args+=(--timestamp)
fi
codesign "${codesign_args[@]}" "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

ARCHS="$(lipo -archs "$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME")"
case " $ARCHS " in
    *' arm64 '*) ;;
    *) echo "Universal binary is missing arm64: $ARCHS" >&2; exit 1 ;;
esac
case " $ARCHS " in
    *' x86_64 '*) ;;
    *) echo "Universal binary is missing x86_64: $ARCHS" >&2; exit 1 ;;
esac

cp -R "$APP_PATH" "$DMG_ROOT/$APP_BUNDLE_NAME"
cp "$RESOURCES_DIR/INSTALL.txt" "$DMG_ROOT/安装说明.txt"
ln -s /Applications "$DMG_ROOT/Applications"

rm -f "$OUTPUT_DMG" "$CHECKSUM_FILE"
hdiutil create \
    -volname "LorenVocabulary $VERSION" \
    -srcfolder "$DMG_ROOT" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -ov \
    "$OUTPUT_DMG"

if [ -n "$NOTARY_PROFILE" ]; then
    if [ "$SIGNING_IDENTITY" = "-" ]; then
        echo "NOTARY_PROFILE requires a Developer ID signing identity." >&2
        exit 1
    fi
    xcrun notarytool submit "$OUTPUT_DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$OUTPUT_DMG"
    xcrun stapler validate "$OUTPUT_DMG"
fi

hdiutil verify "$OUTPUT_DMG"
(
    cd "$DIST_DIR"
    shasum -a 256 "$(basename "$OUTPUT_DMG")"
) > "$CHECKSUM_FILE"

echo "Created: $OUTPUT_DMG"
echo "Architectures: $ARCHS"
echo "Signing identity: $SIGNING_IDENTITY"
echo "Checksum: $CHECKSUM_FILE"
