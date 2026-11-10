#!/usr/bin/env bash
# Builds an UNSIGNED dist/Glim-<version>.ipa (macOS + Xcode required).
# Sign/install it with Sideloadly, AltStore, SideStore or TrollStore.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-$(grep '^version:' pubspec.yaml | sed 's/version: *//; s/+.*//')}"
VERSION="${VERSION#v}"

flutter build ios --release --no-codesign --build-name="$VERSION"
rm -rf build/ipa_payload && mkdir -p build/ipa_payload/Payload dist
cp -R build/ios/iphoneos/Runner.app build/ipa_payload/Payload/
(cd build/ipa_payload && zip -qry "../../dist/Glim-${VERSION}.ipa" Payload)
ls -lh dist
