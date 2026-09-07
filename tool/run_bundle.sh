#!/usr/bin/env bash
# P5 — launch the built Linux bundle directly.
#
# Restores the patched media_kit runtime first, in case a bare `flutter run`
# or `flutter build` regenerated the bundle with the un-launchable plugin.
#
# Usage: tool/run_bundle.sh
set -euo pipefail
cd "$(dirname "$0")/.."
source tool/bundle_libs.sh

restore_bundle_libs "build/linux/x64/debug/bundle/lib"
exec build/linux/x64/debug/bundle/dart_control_panel "$@"