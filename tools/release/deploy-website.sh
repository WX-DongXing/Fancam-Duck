#!/bin/bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
case "${1:-}" in
  --help|-h) echo 'Usage: tools/release/deploy-website.sh [--preview]'; exit 0 ;;
  --preview) deploy_mode=preview ;;
  '') deploy_mode=production ;;
  *) echo 'Unknown option; use --help.' >&2; exit 2 ;;
esac
[[ $# -le 1 ]] || { echo 'Too many arguments.' >&2; exit 2; }
command -v vercel >/dev/null 2>&1 || { echo 'Install the official Vercel CLI and sign in first: https://vercel.com/docs/cli' >&2; exit 1; }
for page in index privacy support; do
  [[ -s "$repo_root/website/public/$page.html" ]] || { echo "Missing page: $page" >&2; exit 1; }
done
cd "$repo_root"
if [[ "$deploy_mode" == production ]]; then exec vercel --prod; else exec vercel; fi
