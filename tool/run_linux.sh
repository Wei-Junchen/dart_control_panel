#!/usr/bin/env bash
# P5 — dev-run wrapper (flutter run) for this machine.
#
# `flutter run -d linux` rebuilds the bundle, which regenerates
# libmedia_kit_video_plugin.so with a build-time RUNPATH that cannot resolve
# libmpv/libmujs at launch on this machine (no system-wide libmpv). The
# pre-patched library set lives in the sibling project's bundle; pointing
# LD_LIBRARY_PATH at it (searched before RUNPATH) makes every rebuild
# launchable without extra steps.
set -euo pipefail
cd "$(dirname "$0")/.."
source tool/bundle_libs.sh

flutter run -d linux "$@"