#!/usr/bin/env bash
set -euo pipefail

: "${ERAS_API_BASE_URL:?Set ERAS_API_BASE_URL to the public Render URL ending in /api}"
: "${ERAS_GOOGLE_MAPS_API_KEY:?Set ERAS_GOOGLE_MAPS_API_KEY to the referrer-restricted browser key}"

if [[ ! "$ERAS_API_BASE_URL" =~ ^https://[^/]+/api/?$ ]]; then
  echo "ERAS_API_BASE_URL must be an HTTPS origin followed by /api" >&2
  exit 1
fi
if [[ ! "$ERAS_GOOGLE_MAPS_API_KEY" =~ ^[A-Za-z0-9_-]+$ ]]; then
  echo "ERAS_GOOGLE_MAPS_API_KEY contains unexpected characters" >&2
  exit 1
fi

config_path="web/google_maps_config.js"
backup_path=""
cleanup() {
  rm -f "$config_path"
  if [[ -n "$backup_path" && -f "$backup_path" ]]; then
    mv "$backup_path" "$config_path"
  fi
}
trap cleanup EXIT

if [[ -f "$config_path" ]]; then
  backup_path="$(mktemp)"
  cp "$config_path" "$backup_path"
fi

# The browser key is necessarily present in the deployed JavaScript. Protect it
# with Google Cloud HTTP-referrer and API restrictions; never print it here.
printf "window.ERAS_GOOGLE_MAPS_API_KEY = '%s';\n" \
  "$ERAS_GOOGLE_MAPS_API_KEY" > "$config_path"

echo "Building Flutter Web for the configured Render API (Maps key not displayed)."
flutter build web --release \
  --dart-define="ERAS_API_BASE_URL=${ERAS_API_BASE_URL%/}"
