#!/usr/bin/env bash
# P5 — Linux desktop build for this machine.
#
# media_kit's libmpv is NOT installed system-wide here. This build reuses the
# developer's local libmpv build tree (same one used by DartVisionReceiver),
# then ships the pre-patched (RUNPATH=$ORIGIN) runtime set from that
# project's bundle so the app launches without LD_LIBRARY_PATH tricks.
#
# Usage: tool/build_linux.sh [--debug|--release|--profile] [flutter args]
set -euo pipefail
cd "$(dirname "$0")/.."
source tool/bundle_libs.sh

PROFILE="debug"
for arg in "$@"; do
  case "${arg}" in
    --release) PROFILE="release" ;;
    --profile) PROFILE="profile" ;;
    --debug) PROFILE="debug" ;;
  esac
done

flutter build linux "$@"
restore_bundle_libs "build/linux/x64/${PROFILE}/bundle/lib"
echo "bundle lib/: $(ls build/linux/x64/${PROFILE}/bundle/lib)"