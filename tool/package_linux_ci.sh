#!/usr/bin/env bash
# Builds the portable Linux release archive after `flutter build linux --release`.
#
# The CI runner gets libmpv from apt instead of the developer's local mpv tree.
# Bundle libmpv and its non-desktop helper libraries (mujs/sixel), then make the
# bundled shared libraries resolve their siblings from their own directory.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-$(grep -m1 '^version:' pubspec.yaml | awk '{print $2}' | cut -d+ -f1)}"
BUNDLE="${BUNDLE:-build/linux/x64/release/bundle}"
LIB="${BUNDLE}/lib"

[ -x "${BUNDLE}/dart_control_panel" ] || {
  echo "missing ${BUNDLE}/dart_control_panel; run flutter build linux --release first" >&2
  exit 1
}
[ -d "${LIB}" ] || {
  echo "missing ${LIB}" >&2
  exit 1
}

find_lib() {
  ldconfig -p | awk -v p="$1" '$1 ~ p {print $NF; exit}'
}

MPV_LIB="${MPV_LIB:-$(find_lib '^libmpv[.]so')}"
[ -n "${MPV_LIB}" ] && [ -e "${MPV_LIB}" ] || {
  echo "libmpv not found; install libmpv-dev or set MPV_LIB" >&2
  exit 1
}

for pattern in '^libmpv[.]so' '^libmujs[.]so' '^libsixel[.]so'; do
  src="${MPV_LIB}"
  [ "${pattern}" = '^libmpv[.]so' ] || src="$(find_lib "${pattern}" || true)"
  [ -n "${src}" ] && [ -e "${src}" ] || continue
  cp -L "${src}" "${LIB}/$(basename "${src}")"
done

[ -e "${LIB}/libmpv.so.1" ] || ln -sf "$(basename "${MPV_LIB}")" "${LIB}/libmpv.so.1"

# Flutter installs plugins with $ORIGIN/lib, but the plugins live in lib/ and
# must find libmpv next to themselves.
find "${LIB}" -maxdepth 1 -type f \( -name '*.so' -o -name '*.so.*' \) \
  -exec patchelf --set-rpath '$ORIGIN' {} +

DIST="dist/dart_control_panel-${VERSION}-linux-x64"
rm -rf "${DIST}"
mkdir -p "${DIST}"
cp -a "${BUNDLE}/." "${DIST}/"

(
  cd dist
  tar -czf "$(basename "${DIST}").tar.gz" "$(basename "${DIST}")"
  sha256sum "$(basename "${DIST}").tar.gz" > "$(basename "${DIST}").tar.gz.sha256"
)

echo "packaged: ${DIST}.tar.gz"
du -sh "${DIST}.tar.gz"
