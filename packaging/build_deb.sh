#!/usr/bin/env bash
# Builds dist/glim_<version>_amd64.deb and dist/glim-<version>-linux-x64.tar.gz
# from an existing `flutter build linux --release` output.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-$(grep '^version:' pubspec.yaml | sed 's/version: *//; s/+.*//')}"
VERSION="${VERSION#v}"
BUNDLE=build/linux/x64/release/bundle
[ -x "$BUNDLE/glim" ] || { echo "Run: flutter build linux --release" >&2; exit 1; }

mkdir -p dist
PKG="$(mktemp -d)/glim_${VERSION}_amd64"
mkdir -p "$PKG/DEBIAN" "$PKG/opt/glim" "$PKG/usr/bin" \
  "$PKG/usr/share/applications" "$PKG/usr/share/icons/hicolor/256x256/apps"

cp -r "$BUNDLE/." "$PKG/opt/glim/"
ln -s /opt/glim/glim "$PKG/usr/bin/glim"
cp packaging/glim.desktop "$PKG/usr/share/applications/glim.desktop"
cp packaging/glim.png "$PKG/usr/share/icons/hicolor/256x256/apps/glim.png"

SIZE=$(du -sk "$PKG" | cut -f1)
cat > "$PKG/DEBIAN/control" <<CTRL
Package: glim
Version: ${VERSION}
Section: video
Priority: optional
Architecture: amd64
Installed-Size: ${SIZE}
Depends: libgtk-3-0 | libgtk-3-0t64, ffmpeg, usbmuxd, libusbmuxd-tools | libusbmuxd-2.0-tools, libimobiledevice-utils
Recommends: v4l2loopback-dkms
Maintainer: Glim <noreply@users.noreply.github.com>
Homepage: https://github.com/z3wax/glim
Description: Reels / Shorts recorder using the iPhone camera as a USB webcam
 Glim receives the iPhone camera (and microphone) over a USB cable through
 usbmuxd and records vertical 9:16 videos ready for Instagram Reels,
 YouTube Shorts and TikTok. It can also expose the stream as a
 v4l2loopback virtual webcam for OBS, Zoom or the browser.
CTRL

cat > "$PKG/DEBIAN/postinst" <<'POST'
#!/bin/sh
set -e
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database -q || true
command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -q /usr/share/icons/hicolor || true
exit 0
POST
chmod 755 "$PKG/DEBIAN/postinst"

dpkg-deb --root-owner-group --build "$PKG" "dist/glim_${VERSION}_amd64.deb"
tar -C "$BUNDLE/.." -czf "dist/glim-${VERSION}-linux-x64.tar.gz" --transform "s/^bundle/glim-${VERSION}/" bundle
ls -lh dist
