#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This build needs macOS with Xcode. Use the included GitHub Actions workflow from Windows."
  exit 1
fi
xcodebuild -version
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cadence-build.XXXXXX")"
# This unique scratch directory was created above and never accepts user input.
trap 'rm -rf "$BUILD_DIR"' EXIT
mkdir -p "$ROOT/artifacts" "$BUILD_DIR/Payload"
swiftc "$ROOT/Cadence/DriveModels.swift" "$ROOT/tests/main.swift" -o "$BUILD_DIR/drive-model-tests"
"$BUILD_DIR/drive-model-tests"
xcodebuild -project "$ROOT/Cadence.xcodeproj" -scheme Cadence \
  -configuration Release -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath "$BUILD_DIR/DerivedData" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build
APP="$BUILD_DIR/DerivedData/Build/Products/Release-iphoneos/Cadence.app"
test -f "$APP/Cadence"
plutil -lint "$APP/Info.plist"
xcrun lipo -archs "$APP/Cadence" | grep -qw arm64
ditto "$APP" "$BUILD_DIR/Payload/Cadence.app"
ditto -c -k --keepParent "$BUILD_DIR/Payload" "$ROOT/artifacts/Cadence-unsigned.ipa"
unzip -t "$ROOT/artifacts/Cadence-unsigned.ipa"
echo "Ready to sign: $ROOT/artifacts/Cadence-unsigned.ipa"
