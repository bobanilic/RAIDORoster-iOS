#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/Products/Release-iphoneos/RAIDORoster.app"
IPA="$ROOT/RAIDORoster-unsigned.ipa"
# Xcode builds the committed source directly. This script never edits it.
rm -rf "$BUILD/Products" "$BUILD/Intermediates"
rm -f "$IPA"
xcodebuild -project "$ROOT/RAIDORoster.xcodeproj" -target RAIDORoster \
  -configuration Release -sdk iphoneos \
  SYMROOT="$BUILD/Products" OBJROOT="$BUILD/Intermediates" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
[[ -d "$APP" ]] || { echo "App bundle missing: $APP" >&2; exit 1; }
STAGING="$(mktemp -d "$BUILD/package.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
mkdir "$STAGING/Payload"
cp -R "$APP" "$STAGING/Payload/"
(cd "$STAGING" && /usr/bin/zip -qry "$IPA" Payload)
echo "Unsigned IPA: $IPA"
