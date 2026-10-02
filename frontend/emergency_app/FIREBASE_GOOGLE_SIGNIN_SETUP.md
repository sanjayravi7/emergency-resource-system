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
login, Socket.IO and every emergency workflow keep working.

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
4. Download `google-services.json` into `frontend/emergency_app/android/app/`.
   It is **git-ignored** on purpose; CI/other checkouts build without it
   (the Google Services Gradle plugin is applied only when the file exists).

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

Pass the Firebase web config at build time:

```bash
cd frontend/emergency_app
flutter build web --release \
  --dart-define=ERAS_API_BASE_URL=https://eras-api-sdjo.onrender.com \
  --dart-define=ERAS_FIREBASE_API_KEY=... \
  --dart-define=ERAS_FIREBASE_APP_ID=... \
  --dart-define=ERAS_FIREBASE_MESSAGING_SENDER_ID=... \
  --dart-define=ERAS_FIREBASE_PROJECT_ID=... \
  --dart-define=ERAS_FIREBASE_AUTH_DOMAIN=<project>.firebaseapp.com \
  --dart-define=ERAS_GOOGLE_WEB_CLIENT_ID=<...>.apps.googleusercontent.com
```

`--dart-define=ERAS_FCM_VAPID_KEY=...` stays optional (web push only).

## 5. Android release APK

```bash
cd frontend/emergency_app
flutter build apk --release \
  --dart-define=ERAS_API_BASE_URL=https://eras-api-sdjo.onrender.com \
  --dart-define=ERAS_GOOGLE_WEB_CLIENT_ID=<...>.apps.googleusercontent.com
```

* `google-services.json` must be present in `android/app/` for Firebase to
  initialise; the build works without it and simply reports Google sign-in as
  unavailable.
* `ERAS_GOOGLE_WEB_CLIENT_ID` is the **web** client id: Firebase uses it as the
  ID-token audience on Android (`serverClientId`), which is why the backend
  accepts it in `GOOGLE_CLIENT_ID`.
* Split APK behaviour of the existing Gradle setup is unchanged.

## 6. What the client does and does not do

| Step | Client | Server |
| --- | --- | --- |
| Google account picker | Google/Firebase SDK | — |
| ID token | obtained, sent once to `/api/auth/google` | signature, issuer, audience, expiry, `email_verified` all re-checked |
| Account resolution | none | uid → login, verified email → link (role untouched), otherwise create with `REQUESTER`/`RESPONDER` only |
| Session | stores the returned ERAS JWT | issues it; role/`isActive` always read from PostgreSQL |
| Email verification | skipped for Google | Google already verified the address |

The client never sends a password for Google sign-in and never asks the server
for a role. A `role` is only ever sent as a *registration intent* for a brand-new
account, is validated against the public allow-list, and is ignored for an
existing account.
