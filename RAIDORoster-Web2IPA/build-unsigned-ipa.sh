#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/Products/Release-iphoneos/RAIDORoster.app"
IPA="$ROOT/RAIDORoster-unsigned.ipa"

rm -rf "$BUILD" "$ROOT/Payload" "$IPA"
mkdir -p "$BUILD/Products" "$BUILD/Intermediates"

python3 "$ROOT/v25_patch.py"

xcodebuild \
  -project "$ROOT/RAIDORoster.xcodeproj" \
  -target RAIDORoster \
  -configuration Release \
  -sdk iphoneos \
  SYMROOT="$BUILD/Products" \
  OBJROOT="$BUILD/Intermediates" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build

if [[ ! -d "$APP" ]]; then
  echo "Build completed but app bundle was not found at: $APP" >&2
  exit 1
fi

mkdir -p "$ROOT/Payload"
cp -R "$APP" "$ROOT/Payload/"
(
  cd "$ROOT"
  /usr/bin/zip -qry "$IPA" Payload
)
rm -rf "$ROOT/Payload"

echo "Unsigned IPA created: $IPA"
echo "Sign/install it with SideStore, AltStore, Sideloadly, or your Apple certificate workflow."
