#!/usr/bin/env bash
set -euo pipefail

: "${ERAS_FIREBASE_PROJECT_ID:?Set the Firebase project ID explicitly}"
command -v firebase >/dev/null 2>&1 || {
  echo "Firebase CLI is required (npm install --global firebase-tools)." >&2
  exit 1
}

./tool/build_production_web.sh
firebase deploy --only hosting --project "$ERAS_FIREBASE_PROJECT_ID" --non-interactive
