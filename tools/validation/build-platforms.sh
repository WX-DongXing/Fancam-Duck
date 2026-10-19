#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
build_root="${FANCAM_DUCK_BUILD_ROOT:-/tmp/fancamduck-platform-builds}"
for platform in ios-device ios-simulator mac-catalyst; do
  case "$platform" in
    ios-device) destination='generic/platform=iOS' ;;
    ios-simulator) destination='generic/platform=iOS Simulator' ;;
    mac-catalyst) destination='generic/platform=macOS,variant=Mac Catalyst' ;;
  esac
  mkdir -p "$build_root/$platform"
  echo "Building $platform (Release)"
  if xcodebuild -project 'Fancam Duck.xcodeproj' -scheme 'Fancam Duck' \
    -configuration Release -destination "$destination" \
    -derivedDataPath "$build_root/$platform" CODE_SIGNING_ALLOWED=NO build \
    > "$build_root/$platform/build.log" 2>&1; then
    echo "PASS: $platform"
  else
    tail -80 "$build_root/$platform/build.log"
    exit 1
  fi
done
