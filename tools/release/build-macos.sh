#!/bin/bash
set -euo pipefail

usage() {
  cat <<'HELP'
Usage: tools/release/build-macos.sh [--local | --developer-id] [--notarize PROFILE]

  --local          Default: universal local preview app, ad-hoc signed; not for public distribution.
  --developer-id   Archive and export using Developer ID. Requires APPLE_TEAM_ID and a signing certificate.
  --notarize NAME  Submit Developer ID ZIP to Apple using an existing notarytool keychain profile,
                   wait for acceptance, staple the ticket, then recreate the distribution ZIP.

Environment:
  APPLE_TEAM_ID                 Required for --developer-id.
  FANCAM_DUCK_RELEASE_ROOT       Output parent (default: build/macos).
  FANCAM_DUCK_MAC_DERIVED_DATA   Build cache (default: build/macos/DerivedData).

Each run creates a new output directory; existing packages are never overwritten.
HELP
}
fail() { echo "Error: $*" >&2; exit 1; }
mode=local
notary_profile=''
while [[ $# -gt 0 ]]; do
  case "$1" in
    --local) mode=local; shift ;;
    --developer-id) mode=developer-id; shift ;;
    --notarize)
      [[ $# -ge 2 && -n "$2" ]] || fail '--notarize requires a keychain profile name'
      notary_profile="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) fail "Unknown argument: $1" ;;
  esac
done
[[ -z "$notary_profile" || "$mode" == developer-id ]] || fail '--notarize requires --developer-id'
if [[ "$mode" == developer-id ]]; then
  [[ "${APPLE_TEAM_ID:-}" =~ ^[A-Z0-9]{10}$ ]] || fail 'Set APPLE_TEAM_ID to your 10-character Apple Developer team ID'
fi
cd "$(dirname "$0")/../.."
release_root="${FANCAM_DUCK_RELEASE_ROOT:-$PWD/build/macos}"
mkdir -p "$release_root"
release_root="$(cd "$release_root" && pwd)"
cache="${FANCAM_DUCK_MAC_DERIVED_DATA:-$release_root/DerivedData}"
run_dir="$(mktemp -d "$release_root/$(date +%Y%m%d-%H%M%S)-$mode.XXXXXX")"
trap 'echo "Build failed. Logs and intermediate artifacts: $run_dir" >&2' ERR
common=(-project 'Fancam Duck.xcodeproj' -scheme 'Fancam Duck'
  -configuration Release -destination 'generic/platform=macOS,variant=Mac Catalyst'
  -derivedDataPath "$cache" 'ARCHS=arm64 x86_64' ONLY_ACTIVE_ARCH=NO)
run_xcode() {
  local log="$1"; shift
  if ! xcodebuild "$@" > "$log" 2>&1; then
    tail -80 "$log" >&2
    return 1
  fi
}
echo "Building Mac Catalyst universal app ($mode)…"
if [[ "$mode" == local ]]; then
  run_xcode "$run_dir/build.log" "${common[@]}" CODE_SIGNING_ALLOWED=NO build
  app="$run_dir/Fancam Duck.app"
  ditto "$cache/Build/Products/Release-maccatalyst/Fancam Duck.app" "$app"
  # Local-only ad-hoc signing enables launch on Apple Silicon without a distribution identity.
  codesign --force --deep --sign - "$app" > "$run_dir/sign.log" 2>&1
else
  archive="$run_dir/Fancam Duck.xcarchive"
  run_xcode "$run_dir/archive.log" "${common[@]}" \
    "DEVELOPMENT_TEAM=$APPLE_TEAM_ID" CODE_SIGN_STYLE=Automatic \
    ENABLE_HARDENED_RUNTIME=YES -archivePath "$archive" archive
  options="$run_dir/ExportOptions.plist"
  cat > "$options" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>developer-id</string>
<key>teamID</key><string>$APPLE_TEAM_ID</string>
<key>signingStyle</key><string>automatic</string>
<key>signingCertificate</key><string>Developer ID Application</string>
</dict></plist>
PLIST
  run_xcode "$run_dir/export.log" -exportArchive -archivePath "$archive" \
    -exportOptionsPlist "$options" -exportPath "$run_dir/export"
  app="$run_dir/export/Fancam Duck.app"
fi
[[ -d "$app" ]] || fail "Missing app: $app"
plist="$app/Contents/Info.plist"
executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist")"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")"
build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")"
architectures="$(xcrun lipo -archs "$app/Contents/MacOS/$executable")"
for architecture in arm64 x86_64; do
  [[ " $architectures " == *" $architecture "* ]] || fail "Missing architecture: $architecture"
done
[[ -s "$app/Contents/Resources/AppIcon.icns" ]] || fail 'Missing AppIcon.icns'
for model in YOLO26sPose OSNetX025; do
  [[ -d "$app/Contents/Resources/$model.mlmodelc" ]] || fail "Missing model: $model"
done
codesign --verify --deep --strict --verbose=2 "$app" > "$run_dir/verify-signature.log" 2>&1
if [[ "$mode" == developer-id ]]; then
  codesign -dv --verbose=4 "$app" > "$run_dir/signing-details.log" 2>&1
  grep -q '^Authority=Developer ID Application:' "$run_dir/signing-details.log" || fail 'Export is not Developer ID signed'
  grep -q 'flags=.*runtime' "$run_dir/signing-details.log" || fail 'Hardened runtime missing'
fi
zip_path="$run_dir/Fancam-Duck-$version-$build_number-macos-$mode.zip"
ditto -c -k --sequesterRsrc --keepParent "$app" "$zip_path"
status='local-preview (ad-hoc signed)'
if [[ "$mode" == developer-id ]]; then status='developer-id-signed (not notarized)'; fi
if [[ -n "$notary_profile" ]]; then
  xcrun notarytool submit "$zip_path" --keychain-profile "$notary_profile" --wait \
    --output-format plist > "$run_dir/notarization.plist"
  result="$(/usr/libexec/PlistBuddy -c 'Print :status' "$run_dir/notarization.plist")"
  [[ "$result" == Accepted ]] || fail "Notarization status: $result (see notarization.plist)"
  xcrun stapler staple "$app" > "$run_dir/staple.log" 2>&1
  xcrun stapler validate "$app" >> "$run_dir/staple.log" 2>&1
  spctl --assess --type execute --verbose=2 "$app" > "$run_dir/gatekeeper.log" 2>&1
  rm "$zip_path"
  ditto -c -k --sequesterRsrc --keepParent "$app" "$zip_path"
  status='developer-id-signed and notarized'
fi
shasum -a 256 "$zip_path" > "$zip_path.sha256"
{
  echo "Status: $status"
  echo "Version: $version ($build_number)"
  echo 'Architectures: arm64 x86_64'
  echo "Source commit: $(git rev-parse HEAD)"
  if [[ -n "$(git status --porcelain)" ]]; then echo 'Source workspace: modified'; else echo 'Source workspace: clean'; fi
  xcodebuild -version
} > "$run_dir/BUILD-INFO.txt"
echo "App: $app"
echo "ZIP: $zip_path"
echo "Status: $status"
