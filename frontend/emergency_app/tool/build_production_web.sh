#!/usr/bin/env bash
set -euo pipefail

: "${ERAS_API_BASE_URL:?Set ERAS_API_BASE_URL to the public Render URL ending in /api}"
: "${ERAS_GOOGLE_MAPS_API_KEY:?Set ERAS_GOOGLE_MAPS_API_KEY to the referrer-restricted browser key}"
: "${ERAS_FIREBASE_API_KEY:?Set the Firebase Web app API key}"
: "${ERAS_FIREBASE_APP_ID:?Set the Firebase Web app ID}"
: "${ERAS_FIREBASE_MESSAGING_SENDER_ID:?Set the Firebase project number/sender ID}"
: "${ERAS_FIREBASE_PROJECT_ID:?Set the actual Firebase project ID}"
: "${ERAS_FIREBASE_AUTH_DOMAIN:?Set the Firebase Auth domain, usually <project-id>.firebaseapp.com}"
: "${ERAS_GOOGLE_WEB_CLIENT_ID:?Set the OAuth 2.0 Web client ID for Android ID-token exchange}"

if [[ ! "$ERAS_API_BASE_URL" =~ ^https://[^/]+/api/?$ ]]; then
  echo "ERAS_API_BASE_URL must be an HTTPS origin followed by /api" >&2
  exit 1
fi
if [[ ! "$ERAS_GOOGLE_MAPS_API_KEY" =~ ^[A-Za-z0-9_-]+$ ]]; then
  echo "ERAS_GOOGLE_MAPS_API_KEY contains unexpected characters" >&2
  exit 1
fi
if [[ ! "$ERAS_FIREBASE_AUTH_DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]]; then
  echo "ERAS_FIREBASE_AUTH_DOMAIN contains unexpected characters" >&2
  exit 1
fi
if [[ ! "$ERAS_GOOGLE_WEB_CLIENT_ID" =~ ^[A-Za-z0-9._-]+\.apps\.googleusercontent\.com$ ]]; then
  echo "ERAS_GOOGLE_WEB_CLIENT_ID is not a Google OAuth Web client ID" >&2
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

vapid_arg=()
if [[ -n "${ERAS_FCM_VAPID_KEY:-}" ]]; then
  if [[ ! "$ERAS_FCM_VAPID_KEY" =~ ^[A-Za-z0-9_-]+$ ]]; then
    echo "ERAS_FCM_VAPID_KEY contains unexpected characters" >&2
    exit 1
  fi
  # Web Push requires a VAPID key at token-request time. Without it the
  # Flutter client skips FCM registration on web entirely (Socket.IO and
  # GET /api/requests/compatible still cover foreground responders).
  vapid_arg=(--dart-define="ERAS_FCM_VAPID_KEY=${ERAS_FCM_VAPID_KEY}")
  echo "FCM web push enabled (VAPID key not displayed)."
else
  echo "ERAS_FCM_VAPID_KEY not set: web builds skip FCM push registration."
fi

firebase_args=(
  --dart-define="ERAS_FIREBASE_API_KEY=${ERAS_FIREBASE_API_KEY}"
  --dart-define="ERAS_FIREBASE_APP_ID=${ERAS_FIREBASE_APP_ID}"
  --dart-define="ERAS_FIREBASE_MESSAGING_SENDER_ID=${ERAS_FIREBASE_MESSAGING_SENDER_ID}"
  --dart-define="ERAS_FIREBASE_PROJECT_ID=${ERAS_FIREBASE_PROJECT_ID}"
  --dart-define="ERAS_FIREBASE_AUTH_DOMAIN=${ERAS_FIREBASE_AUTH_DOMAIN}"
  --dart-define="ERAS_GOOGLE_WEB_CLIENT_ID=${ERAS_GOOGLE_WEB_CLIENT_ID}"
)
if [[ -n "${ERAS_FIREBASE_STORAGE_BUCKET:-}" ]]; then
  firebase_args+=(--dart-define="ERAS_FIREBASE_STORAGE_BUCKET=${ERAS_FIREBASE_STORAGE_BUCKET}")
fi
if [[ -n "${ERAS_FIREBASE_MEASUREMENT_ID:-}" ]]; then
  firebase_args+=(--dart-define="ERAS_FIREBASE_MEASUREMENT_ID=${ERAS_FIREBASE_MEASUREMENT_ID}")
fi

echo "Building Flutter Web for the configured Render/Firebase project (config keys not displayed)."
flutter build web --release \
  --dart-define="ERAS_API_BASE_URL=${ERAS_API_BASE_URL%/}" \
  "${vapid_arg[@]}" \
  "${firebase_args[@]}"
