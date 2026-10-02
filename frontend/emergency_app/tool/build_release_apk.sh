#!/usr/bin/env bash
set -euo pipefail

: "${ERAS_API_BASE_URL:?Set ERAS_API_BASE_URL to the public HTTPS Render URL ending in /api}"
: "${ERAS_FIREBASE_PROJECT_ID:?Set the actual Firebase project ID}"
: "${ERAS_GOOGLE_WEB_CLIENT_ID:?Set the Firebase OAuth 2.0 Web client ID}"
: "${MAPS_API_KEY:?Set the Android-restricted Maps SDK key}"
: "${ERAS_ANDROID_KEYSTORE_PATH:?Set the production release keystore path}"
: "${ERAS_ANDROID_KEY_ALIAS:?Set the release key alias}"
: "${ERAS_ANDROID_STORE_PASSWORD:?Set the release keystore password}"
: "${ERAS_ANDROID_KEY_PASSWORD:?Set the release key password}"

if [[ ! "$ERAS_API_BASE_URL" =~ ^https://[^/]+/api/?$ ]]; then
  echo "ERAS_API_BASE_URL must be an HTTPS origin followed by /api" >&2
  exit 1
fi
ERAS_ANDROID_KEYSTORE_PATH="$(python3 -c 'from pathlib import Path; import sys; print(Path(sys.argv[1]).expanduser().resolve())' "$ERAS_ANDROID_KEYSTORE_PATH")"
export ERAS_ANDROID_KEYSTORE_PATH
if [[ ! -f "$ERAS_ANDROID_KEYSTORE_PATH" ]]; then
  echo "Release keystore file does not exist" >&2
  exit 1
fi
command -v keytool >/dev/null 2>&1 || {
  echo "keytool is required to verify the release certificate fingerprint." >&2
  exit 1
}

key_info="$(keytool -list -v \
  -keystore "$ERAS_ANDROID_KEYSTORE_PATH" \
  -alias "$ERAS_ANDROID_KEY_ALIAS" \
  -storepass:env ERAS_ANDROID_STORE_PASSWORD 2>/dev/null)" || {
  echo "Could not read the configured release certificate/alias." >&2
  exit 1
}
release_sha1="$(printf '%s\n' "$key_info" | sed -n 's/^[[:space:]]*SHA1: *//p' | head -n 1 | tr -d '[:space:]:' | tr '[:lower:]' '[:upper:]')"
release_sha256="$(printf '%s\n' "$key_info" | sed -n 's/^[[:space:]]*SHA256: *//p' | head -n 1 | tr -d '[:space:]:' | tr '[:lower:]' '[:upper:]')"
if [[ ${#release_sha1} -ne 40 || ${#release_sha256} -ne 64 ]]; then
  echo "Could not extract the release SHA-1 and SHA-256 fingerprints." >&2
  exit 1
fi
printf 'Release signing SHA-1: %s\n' "$release_sha1"
printf 'Release signing SHA-256: %s\n' "$release_sha256"

config_path="android/secrets.properties"
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
printf 'MAPS_API_KEY=%s\n' "$MAPS_API_KEY" > "$config_path"

python3 tool/verify_firebase_android_config.py \
  --file android/app/google-services.json \
  --project-id "$ERAS_FIREBASE_PROJECT_ID" \
  --web-client-id "$ERAS_GOOGLE_WEB_CLIENT_ID" \
  --release-sha1 "$release_sha1"

echo "Building production-signed Android APK (secrets are not printed)."
flutter build apk --release \
  --dart-define="ERAS_API_BASE_URL=${ERAS_API_BASE_URL%/}" \
  --dart-define="ERAS_GOOGLE_WEB_CLIENT_ID=${ERAS_GOOGLE_WEB_CLIENT_ID}"

echo "Release APK: build/app/outputs/flutter-apk/app-release.apk"
