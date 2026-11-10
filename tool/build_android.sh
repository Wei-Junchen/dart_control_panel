#!/usr/bin/env bash
# Build an arm64 APK for Android phones. Usage: tool/build_android.sh [release|debug]
set -euo pipefail
cd "$(dirname "$0")/.."

mode="${1:-release}"
if [[ $# -gt 1 || ( "$mode" != release && "$mode" != debug ) ]]; then
  echo "用法: $0 [release|debug]" >&2
  exit 2
fi

if [[ -n "${FLUTTER:-}" ]]; then
  flutter_bin="$FLUTTER"
elif command -v flutter >/dev/null 2>&1; then
  flutter_bin="$(command -v flutter)"
elif [[ -f android/local.properties ]]; then
  flutter_sdk="$(sed -n 's/^flutter\.sdk=//p' android/local.properties | tail -n 1)"
  flutter_bin="${flutter_sdk}/bin/flutter"
else
  flutter_bin="flutter"
fi
if ! command -v "$flutter_bin" >/dev/null 2>&1; then
  echo "找不到 Flutter；请加入 PATH，或设置 FLUTTER=/path/to/flutter。" >&2
  exit 1
fi

"$flutter_bin" pub get
"$flutter_bin" build apk "--$mode" --target-platform android-arm64 --no-pub
apk="build/app/outputs/flutter-apk/app-${mode}.apk"
[[ -f "$apk" ]] || { echo "未找到构建产物: $apk" >&2; exit 1; }
printf '\nAPK: %s/%s\n' "$PWD" "$apk"
if command -v sha256sum >/dev/null 2>&1; then sha256sum "$apk"; fi
if [[ "$mode" == release ]]; then
  echo '注意: 当前 Release 使用 debug 签名，仅供内部测试，不适合正式发布。'
fi
