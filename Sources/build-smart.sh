#!/bin/zsh
set -euo pipefail
umask 077

# Resolve beside this script so a staged build never consumes live source files.
BASE="${0:A:h}"
OUT_ROOT="${1:-$BASE/builds}"
VERSION="3.3"
BUILD="12"
APP="$OUT_ROOT/CodexPro Smart-$VERSION-$BUILD.app"
[[ ! -e "$APP" ]] || { print -u2 "Build output already exists; choose a new output directory."; exit 73; }
for required in CodexProSmart.swift ControlRunner.swift CodexProSmart-icon.icns; do
  [[ -f "$BASE/$required" && ! -L "$BASE/$required" ]] || { print -u2 "Missing or unexpected source: $required"; exit 66; }
done
TMP_ROOT="$(/usr/bin/mktemp -d /tmp/codexpro-smart-build.XXXXXX)"
trap '/bin/rm -rf "$TMP_ROOT"' EXIT
TMP="$TMP_ROOT/CodexPro Smart.app"
/bin/mkdir -p "$TMP/Contents/MacOS" "$TMP/Contents/Resources" "$OUT_ROOT"

/usr/bin/swiftc -parse-as-library -O -target arm64-apple-macos13.0 \
  "$BASE/ControlRunner.swift" "$BASE/CodexProSmart.swift" \
  -o "$TMP/Contents/MacOS/CodexProSmart"
/bin/chmod 755 "$TMP/Contents/MacOS/CodexProSmart"

PLIST="$TMP/Contents/Info.plist"
/usr/bin/plutil -create xml1 "$PLIST"
/usr/bin/plutil -insert CFBundleDisplayName -string "CodexPro Smart" "$PLIST"
/usr/bin/plutil -insert CFBundleExecutable -string "CodexProSmart" "$PLIST"
/usr/bin/plutil -insert CFBundleIconFile -string "CodexProSmart" "$PLIST"
/usr/bin/plutil -insert CFBundleIconName -string "CodexProSmart" "$PLIST"
/usr/bin/plutil -insert CFBundleIdentifier -string "com.leo.codexpro.smart-app" "$PLIST"
/usr/bin/plutil -insert CFBundleName -string "CodexPro Smart" "$PLIST"
/usr/bin/plutil -insert CFBundlePackageType -string APPL "$PLIST"
/usr/bin/plutil -insert CFBundleShortVersionString -string "$VERSION" "$PLIST"
/usr/bin/plutil -insert CFBundleVersion -string "$BUILD" "$PLIST"
/usr/bin/plutil -insert LSMinimumSystemVersion -string "13.0" "$PLIST"
/usr/bin/plutil -insert NSHighResolutionCapable -bool true "$PLIST"
/bin/cp "$BASE/CodexProSmart-icon.icns" "$TMP/Contents/Resources/CodexProSmart.icns"

# Bundle resources are signed. The post-signature binary hash is kept outside
# the bundle to avoid a circular dependency between the manifest and signature.
MANIFEST="$TMP/Contents/Resources/build-manifest.txt"
{
  print "product=CodexPro Smart"
  print "version=$VERSION"
  print "build=$BUILD"
  print "architecture=arm64"
  print "minimum_macos=13.0"
  print "signing=adhoc"
  print "built_at=$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')"
  for source in CodexProSmart.swift ControlRunner.swift CodexProSmart-icon.icns; do
    digest="$(/usr/bin/shasum -a 256 "$BASE/$source" | /usr/bin/awk '{print $1}')"
    print -r -- "sha256:$source=$digest"
  done
} > "$MANIFEST"
/bin/chmod 644 "$PLIST" "$MANIFEST" "$TMP/Contents/Resources/CodexProSmart.icns"
/usr/bin/codesign --force --options runtime --sign - "$TMP"
/usr/bin/codesign --verify --deep --strict "$TMP"
/bin/mv "$TMP" "$APP"
{
  print "version=$VERSION"
  print "build=$BUILD"
  print "signed_binary_sha256=$(/usr/bin/shasum -a 256 "$APP/Contents/MacOS/CodexProSmart" | /usr/bin/awk '{print $1}')"
  print "manifest_sha256=$(/usr/bin/shasum -a 256 "$APP/Contents/Resources/build-manifest.txt" | /usr/bin/awk '{print $1}')"
  print "signature_verified=true"
} > "$OUT_ROOT/build-receipt.txt"
print -r -- "Built: $APP"
print "Version: $VERSION (build $BUILD); signature verified"
