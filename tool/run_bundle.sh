#!/usr/bin/env bash
# Launch an already-built Linux bundle directly.
#
# Default is the release bundle produced by `tool/package_linux.sh`.
# Usage:
#   tool/run_bundle.sh                  # latest release bundle
#   tool/run_bundle.sh --debug [args]   # debug bundle
#   tool/run_bundle.sh --profile [args] # profile bundle
set -euo pipefail
cd "$(dirname "$0")/.."
source tool/bundle_libs.sh

PROFILE="release"
if [[ "${1:-}" == "--debug" ]]; then
  PROFILE="debug"
  shift
elif [[ "${1:-}" == "--profile" ]]; then
  PROFILE="profile"
  shift
elif [[ "${1:-}" == "--release" ]]; then
  shift
fi

BUNDLE="build/linux/x64/${PROFILE}/bundle"
APP="${BUNDLE}/dart_control_panel"
if [[ ! -x "${APP}" ]]; then
  echo "bundle not found: ${APP}" >&2
  echo "build it with: tool/build_linux.sh --${PROFILE}" >&2
  exit 1
fi

restore_bundle_libs "${BUNDLE}/lib"
# bundle_libs.sh adds the sibling debug bundle to LD_LIBRARY_PATH for linking.
# That is correct while building, but fatal for a release launch: the release
# runner would load the sibling *debug* Flutter engine and then reject libapp.so
# with "Not running in AOT mode". Always prefer this bundle's own engine and
# native dependencies at runtime.
export LD_LIBRARY_PATH="${BUNDLE}/lib"
exec "${APP}" "$@"
