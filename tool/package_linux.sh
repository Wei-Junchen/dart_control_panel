#!/usr/bin/env bash
# P6 — Linux release package: builds the standalone bundle with the patched
# media_kit runtime and archives it under dist/.
#
# Usage: tool/package_linux.sh
#   → dist/dart_control_panel-<version>-linux-x64.tar.gz (run the app from
#     the extracted bundle; no Python/Tk/Pillow anywhere in the package).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(grep -m1 '^version:' pubspec.yaml | awk '{print $2}' | cut -d+ -f1)"

./tool/build_linux.sh --release

DIST="dist/dart_control_panel-${VERSION}-linux-x64"
rm -rf "${DIST}"
mkdir -p "${DIST}"
cp -r build/linux/x64/release/bundle/. "${DIST}/"

tar -czf "${DIST}.tar.gz" -C dist "dart_control_panel-${VERSION}-linux-x64"
echo "packaged: ${DIST}.tar.gz"
du -sh "${DIST}.tar.gz"