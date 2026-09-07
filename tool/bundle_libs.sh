#!/usr/bin/env bash
# Shared env + bundle repair helpers for the media_kit Linux build.
# Sourced by build_linux.sh / run_bundle.sh.

LOCAL_DEPS="${LOCAL_DEPS:-/home/litwei/projects/DartVisionReceiver/.local-deps}"
SIBLING_LIB="${SIBLING_LIB:-/home/litwei/projects/DartVisionReceiver/build/linux/x64/debug/bundle/lib}"

# libmpv is not system-wide: compiling needs pkg-config + link-time search.
export PKG_CONFIG_PATH="${LOCAL_DEPS}/pkgconfig${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}"
export LD_LIBRARY_PATH="${SIBLING_LIB}${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"

# Restores the pre-patched (RUNPATH=$ORIGIN) plugin + libmpv/mujs/sixel into
# a bundle. Required whenever something regenerated the bundle (bare
# `flutter build`/`flutter run`): the freshly built media_kit_video plugin
# carries a build-time RUNPATH pointing at ephemeral/.local-deps dirs whose
# libmpv cannot resolve libmujs at launch.
restore_bundle_libs() {
  local bundle_lib="$1"
  mkdir -p "${bundle_lib}"
  # media_kit's NativeLibrary tries 'libmpv.so' first: drop unpatched copies.
  rm -f "${bundle_lib}/libmpv.so" "${bundle_lib}/libmpv.so.2"
  for f in \
    libmpv.so.1 libmpv.so.1.109.0 \
    libmujs.so.1 libsixel.so.1 libsixel.so.1.0.0 \
    libmedia_kit_video_plugin.so; do
    [ -f "${SIBLING_LIB}/${f}" ] && cp -f "${SIBLING_LIB}/${f}" "${bundle_lib}/${f}"
  done
}