#!/bin/sh
set -eu

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen is missing. Install it with: brew install xcodegen"
  exit 1
fi

python3 Scripts/make_icons.py
xcodegen generate
rm -rf build/DerivedData
xcodebuild \
  -project GPTNative.xcodeproj \
  -scheme GPTNative \
  -configuration Release \
  -sdk iphoneos \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO \
  build

chmod +x Scripts/package_ipa.sh
Scripts/package_ipa.sh
