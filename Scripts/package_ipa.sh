#!/bin/sh
set -eu

APP_PATH="$(find build -type d -path '*/Release-iphoneos/*.app' | head -n 1)"
IPA_PATH="build/GPTNative.ipa"

if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH" ]; then
  echo "Missing app bundle under build"
  exit 1
fi

if command -v ldid >/dev/null 2>&1; then
  find "$APP_PATH" -type f -perm -111 -exec ldid -S {} \; || true
fi

rm -rf build/Payload "$IPA_PATH"
mkdir -p build/Payload
cp -R "$APP_PATH" build/Payload/
(
  cd build
  /usr/bin/zip -qry "GPTNative.ipa" Payload
)

echo "Created $IPA_PATH"
