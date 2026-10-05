# Google sign-in (Firebase Auth) — ERAS setup

ERAS registers/logs in users with **Google through the existing Firebase
project**. The Flutter app never decides who it is: Firebase proves the identity,
then `POST /api/auth/google` verifies the ID token against Google's published
certificates and issues the normal **ERAS JWT**. Roles, `isActive` and RBAC keep
coming from PostgreSQL, so public signup can only ever create `REQUESTER` or
`RESPONDER`.

Nothing in this document is a secret that gets committed: project identifiers and
the Google *web* client id are public by design, and the Firebase **web** config
is passed at build time with `--dart-define`.

---

## 1. Backend (Render)

Add these environment variables to the `eras-api` service (values come from the
Firebase console → Project settings → General, and Google Cloud → Credentials):

| Variable | Purpose |
| --- | --- |
| `FIREBASE_PROJECT_ID` | Firebase project id. Firebase ID tokens are checked for `aud`/`iss` against it. |
| `GOOGLE_CLIENT_ID` | Google OAuth client id(s), comma separated: the **web** client id (and the Android client id if you want Android ID tokens accepted directly). |

Without them `POST /api/auth/google` answers `503 Google sign-in is not
configured on this server` and the button reports that honestly — email/password
login, Socket.IO and every emergency workflow keep working. The backend
verifies tokens against Google's published certificates; **Firebase Admin
service-account credentials are not required for Google authentication**.

Configure transactional mail on Render as well so real verification, welcome,
and reset messages can be requested. Set `RESEND_API_KEY` and the actual bare
sender address verified with that provider in `ERAS_MAIL_FROM`; ERAS adds its
sender display name automatically. Do not use a sample or invented sender.
SMTP can be configured as a fallback (or sole transport), and Nodemailer is
already included in backend dependencies. See the repo-root
`FIREBASE_GOOGLE_SIGNIN_SETUP.md` and `backend/.env.example` for details.
Without a configured transport and valid sender, email requests report
`unconfigured` or `failed` and users can request a new verification code.

ERAS distinguishes provider request acceptance from confirmed inbox delivery:
`emailRequestAccepted` / `welcomeEmailRequestAccepted` and
`emailDeliveryResult` describe the synchronous provider response. The
`*Delivered` field remains `null` unless a provider delivery confirmation is
available; an accepted response alone does not prove inbox delivery.

Verification notes:

* RS256 signature, `kid` lookup and a 1-hour cache of Google's certificate set.
* `iss` must be `https://securetoken.google.com/<project>` (Firebase) or
  `accounts.google.com` / `https://accounts.google.com` (Google).
* `aud` must match the project id or one of the configured client ids.
* `email_verified` must be true, otherwise the token is refused.
* Rate limited (`GOOGLE_AUTH_RATE_MAX`, default 30) and audited
  (`GOOGLE_LOGIN` / `GOOGLE_REGISTERED`).

## 2. Firebase console

1. **Authentication → Sign-in method**: enable **Google**.
2. **Authentication → Settings → Authorized domains**: add the production host
   and any preview host used for testing.
3. **Project settings → General → Your apps**:
   * register a **Web** app (gives apiKey/appId/…) — used by `--dart-define`,
   * register an **Android** app with the release keystore's SHA-1/SHA-256
     (gives `android/app/google-services.json` and the Android client id).
     Also add the debug keystore SHA-1 for local testing.

   **The release SHA-1 is the step that decides whether Google sign-in works
   in a release APK.** Google identifies an Android app by *package name plus
   the SHA-1 of the certificate that actually signed the APK*, so a release APK
   signed with a certificate that the Android OAuth client does not list is
   rejected before the account picker appears
   (`CommonStatusCodes.DEVELOPER_ERROR`, status 10 → the plugin's
   `sign_in_failed`). Add:

   * the upload/release keystore SHA-1 (for APKs you sign yourself):
     `183A5CC4DD91C8AE1525486434FF0831CAA35C27`,
   * the **Play App Signing** certificate SHA-1 as well if the app is
     distributed through Google Play (Play re-signs the APK, so the signing
     certificate at runtime is Google's, not yours):
     Play Console → Setup → App integrity → App signing key certificate,
   * the debug keystore SHA-1 for local testing.

   After adding a fingerprint, **download a fresh `google-services.json`** and
   rebuild: the fingerprint lives in the Android OAuth client entry of that
   file, and the APK is checked against what is compiled in.
4. Download `google-services.json` into `frontend/emergency_app/android/app/`.
   It is **git-ignored** on purpose; CI/other checkouts build without it
   (the Google Services Gradle plugin is applied only when the file exists).
   `tool/build_release_apk.sh` verifies the package name, the project number,
   the web OAuth client and **both release fingerprints** before it builds:

   ```bash
   python3 tool/verify_firebase_android_config.py \
     --file android/app/google-services.json \
     --project-id "$ERAS_FIREBASE_PROJECT_ID" \
     --web-client-id "$ERAS_GOOGLE_WEB_CLIENT_ID" \
     --release-sha1  "$RELEASE_SHA1" \
     --release-sha256 "$RELEASE_SHA256"
   ```

## 3. Google Cloud console

* The **Web** OAuth client must list the site origins under
  *Authorized JavaScript origins* (e.g. `https://<project>.web.app`,
  `http://localhost:8080`).
* The **Android** OAuth client needs the app's `applicationId`
  (`io.github.sanjayravi7.eras`) and the signing certificate SHA-1.
* No Maps key is involved here; Google Maps keeps its own referrer-restricted
  browser key (see `GOOGLE_MAPS_SETUP.md`).

## 4. Web build

`web/index.html` already loads:

* the **Firebase JS SDK compat build** (`firebase-app-compat.js`,
  `firebase-auth-compat.js`, `firebase-messaging-compat.js`) — this is the API
  FlutterFire's web plugins are built on,
* the **Google Identity Services** client library
  (`https://accounts.google.com/gsi/client`).

Both are best-effort: if they cannot be loaded, Google sign-in reports
"not configured" instead of breaking the app.

Build with the production helper so it validates the required values and
passes the complete Firebase config through Dart defines. `ERAS_API_BASE_URL`
must be the HTTPS Render URL **ending in `/api`**:

```bash
cd frontend/emergency_app
./tool/build_production_web.sh
```

Set `ERAS_API_BASE_URL`, `ERAS_GOOGLE_MAPS_API_KEY`,
`ERAS_FIREBASE_API_KEY`, `ERAS_FIREBASE_APP_ID`,
`ERAS_FIREBASE_MESSAGING_SENDER_ID`, `ERAS_FIREBASE_PROJECT_ID`,
`ERAS_FIREBASE_AUTH_DOMAIN`, and `ERAS_GOOGLE_WEB_CLIENT_ID` in the local
build environment. Optional `ERAS_FIREBASE_STORAGE_BUCKET`,
`ERAS_FIREBASE_MEASUREMENT_ID`, and `ERAS_FCM_VAPID_KEY` are described in the
root release checklist; FCM VAPID is only for web push.

## 5. Android release APK

```bash
cd frontend/emergency_app
./tool/build_release_apk.sh
```

The helper requires the HTTPS Render API base ending in `/api`, the verified
Firebase project and Web OAuth client, `google-services.json`, an Android
Maps key, and the production release keystore variables documented in the
root release checklist. It validates the Firebase package/client/fingerprint
configuration and refuses to produce a release without the configured key.


* `google-services.json` must be present in `android/app/` for Firebase to
  initialise. A plain checkout/build without it degrades gracefully and reports
  Google sign-in unavailable; the production release helper requires the real
  file and validates it before building.
* Flutter **Web** authenticates through Firebase Auth's own Google flow
  (`signInWithPopup`, with a `signInWithRedirect` fallback), so it needs no Dart
  client id and never calls `google_sign_in` on the web. What it does need is
  the Firebase **web app configuration** (`ERAS_FIREBASE_*`) plus the deployed
  origin being an authorized domain in Firebase Authentication.
* Reading a failed Android attempt: every native failure is logged with its
  Google status code (`adb logcat -s flutter` / `flutter: [eras-auth] google
  sign-in cancelled/failed code=… statusCode=…`). `statusCode=10` means the
  build is not registered with Google — see step 3 above; the in-app message
  says so instead of asking the user to retry. Any other status is an
  environment/account problem (network, Play services, account state).
* `ERAS_GOOGLE_WEB_CLIENT_ID` is therefore only kept for compatibility with
  older web builds. Android does **not** use it at all: the
  Google Sign-In SDK identifies the app by package name plus signing SHA-1 and
  takes the ID-token audience from the `default_web_client_id` resource that
  the google-services Gradle plugin generates from `google-services.json`.
  Passing the value in from Dart overrides that resource and is what produced
  `sign_in_failed` / `h2: 10` (`CommonStatusCodes.DEVELOPER_ERROR`) in release
  APKs. The backend still lists it in `GOOGLE_CLIENT_ID` because it is an
  accepted audience for raw Google Identity Services ID tokens.
* Split APK behaviour of the existing Gradle setup is unchanged.

## 6. What the client does and does not do

| Step | Client | Server |
| --- | --- | --- |
| Google account picker | Google/Firebase SDK | — |
| ID token | obtained, sent once to `/api/auth/google` | signature, issuer, audience, expiry, `email_verified` all re-checked |
| Account resolution | none | known Firebase UID → login; a matching verified email on an existing active ERAS account → link its Firebase UID while preserving its role; otherwise create with `REQUESTER`/`RESPONDER` only |
| Session | stores the returned ERAS JWT | issues it; role/`isActive` always read from PostgreSQL |
| Email verification | skipped for Google | Google already verified the address |

The client never sends an ERAS password for Google sign-in. It may send a
`role` only as registration intent; the backend validates it against the public
allow-list and uses it only when creating a brand-new account. The requested
role is ignored for an already-known Firebase UID or a matching verified-email
account. For the latter, the backend links the verified Firebase UID to that
existing ERAS user and preserves its stored role and password. Existing
email/password login remains available.
