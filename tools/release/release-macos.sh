#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/../.." && pwd)"
usage() {
  cat <<'HELP'
Usage: tools/release/release-macos.sh [--local | --signed-only] [--check]

Loads repository .env.release, then builds and signs a macOS ZIP.
  --local        Override config: ad-hoc preview, no Apple upload.
  --signed-only  Override config: Developer ID signing without notarization.
  --check        Check configuration without building, signing or uploading.
  --help         Show help without loading configuration.

Default follows RELEASE_MODE and RELEASE_NOTARIZE in .env.release.
Notarization uploads the signed ZIP to Apple; no website/GitHub publishing occurs.
HELP
}
fail() { echo "Error: $*" >&2; exit 1; }
override=''
check=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --local) override=local; shift ;;
    --signed-only) override=signed-only; shift ;;
    --check) check=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) fail "Unknown argument: $1" ;;
  esac
done
[[ -f "$root/.env.release" ]] || fail 'Create .env.release from .env.release.example and configure it first'
# This is a trusted, user-maintained shell file. Never enable tracing or print its contents.
set -a
source "$root/.env.release"
set +a
mode="${RELEASE_MODE:-developer-id}"
notarize="${RELEASE_NOTARIZE:-true}"
case "$override" in
  local) mode=local; notarize=false ;;
  signed-only) mode=developer-id; notarize=false ;;
esac
[[ "$mode" == local || "$mode" == developer-id ]] || fail 'RELEASE_MODE must be local or developer-id'
[[ "$notarize" == true || "$notarize" == false ]] || fail 'RELEASE_NOTARIZE must be true or false'
args=()
if [[ "$mode" == local ]]; then
  args+=(--local)
else
  [[ "${APPLE_TEAM_ID:-}" =~ ^[A-Z0-9]{10}$ ]] || fail 'Configure the 10-character APPLE_TEAM_ID in .env.release'
  args+=(--developer-id)
  if [[ "$notarize" == true ]]; then
    [[ -n "${APPLE_NOTARY_PROFILE:-}" ]] || fail 'Configure APPLE_NOTARY_PROFILE in .env.release'
    args+=(--notarize "$APPLE_NOTARY_PROFILE")
  fi
fi
[[ -z "${FANCAM_DUCK_VERSION:-}" || "$FANCAM_DUCK_VERSION" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || fail 'FANCAM_DUCK_VERSION must contain 1–3 numeric components'
[[ -z "${FANCAM_DUCK_BUILD_NUMBER:-}" || "$FANCAM_DUCK_BUILD_NUMBER" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || fail 'FANCAM_DUCK_BUILD_NUMBER must contain 1–3 numeric components'
if [[ "$check" == true ]]; then
  echo "Configuration valid: mode=$mode; notarize=$([[ "$mode" == developer-id ]] && echo "$notarize" || echo false)"
  echo 'Signing identity, provisioning and Keychain credentials are checked during the actual build.'
  exit 0
fi
cd "$root"
exec "$root/tools/release/build-macos.sh" "${args[@]}"
