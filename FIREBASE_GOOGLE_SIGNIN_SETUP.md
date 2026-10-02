# Firebase / Google Sign-In release configuration

This repository keeps ERAS's existing authentication authority: PostgreSQL users,
ERAS-issued JWTs, and the existing `/api/auth/*` routes. Firebase Auth is used
only to obtain a Google identity proof. The backend verifies the Firebase ID
token, resolves a Google-created PostgreSQL user or creates one during Google
registration, and returns the normal ERAS JWT consumed by REST and Socket.IO.
It does not silently attach a Google identity to an existing password account
with the same email. Local email/password passwords remain ERAS-managed. New local registrations must verify a six-digit email code before
login; password recovery uses a one-time six-digit code.

No production Firebase project or OAuth values are committed. The project ID,
OAuth clients, domains, Android signing fingerprints, Firebase service account,
Resend sender, and Render secrets must be supplied from the real owner consoles.
The checked-in package name is `io.github.sanjayravi7.eras`.

## 1. Firebase project and Google provider

1. Select the production project in Firebase Console and record its exact
   **Project ID**. Use the same project for the Firebase Web app, Android app,
   Firebase Admin service account, and production backend `FIREBASE_PROJECT_ID`.
2. In **Authentication → Sign-in method**, enable **Google** and select the
   intended support email. Confirm the OAuth consent screen is configured and
   published for the intended audience; add test users if the consent screen
   is still in testing.
3. In **Authentication → Settings → Authorized domains**, add every deployed
   Firebase Hosting/custom domain used by the app. Do not add broad wildcard
   domains.
4. Create/register one Firebase Web app. Record its Web config values:
   `apiKey`, `appId`, `messagingSenderId`, `projectId`, `authDomain`, and, if
   supplied, `storageBucket` and `measurementId`. These Firebase Web values
   are public client configuration, not backend service-account secrets.

## 2. Google OAuth Web client, origins, and redirect URI

In Google Cloud Console, select the same project and open **APIs & Services →
Credentials**. Verify the Web OAuth 2.0 client that Firebase uses. Do not guess
these values from a different project.

- The exact deployed JavaScript origins must be present, for example
  `https://<project-id>.web.app` and `https://<project-id>.firebaseapp.com`,
  plus each actually used custom domain. Add `http://localhost:<port>` only to
  a development client if local testing needs it.
- The authorized redirect URI must match the Firebase `authDomain` handler:
  `https://<authDomain>/__/auth/handler` (commonly
  `https://<project-id>.firebaseapp.com/__/auth/handler`). Confirm the exact URI
  shown by the actual OAuth client/Firebase console. Do not substitute the
  Hosting `web.app` URL unless that is explicitly the configured auth domain.
- Record the complete Web client ID ending in
  `.apps.googleusercontent.com`. `google-services.json` must contain the same
  ID as an OAuth `client_type: 3` entry. Supply it to Flutter builds as
  `ERAS_GOOGLE_WEB_CLIENT_ID`.
- Confirm the Firebase `authDomain` and origins above are from the production
  project, not a preview project.

The Web app uses Firebase Auth's Google popup flow. The browser never sends a
Google OAuth access token directly to ERAS; it sends a Firebase-signed ID token
that the backend verifies.

## 3. Android app, OAuth client, and fingerprints

1. Register an Android app in the selected Firebase project with the exact
   package/application ID `io.github.sanjayravi7.eras`.
2. Obtain SHA-1 and SHA-256 from the actual certificate that will sign each
   installed build. For the release key, use `keytool` on the release keystore
   or the Gradle signing report. Keep passwords out of shell arguments/history.
   The current production APK build uses the release keystore supplied through
   `ERAS_ANDROID_KEYSTORE_PATH`, `ERAS_ANDROID_KEY_ALIAS`,
   `ERAS_ANDROID_STORE_PASSWORD`, and `ERAS_ANDROID_KEY_PASSWORD`.
3. Add the SHA-1 and SHA-256 fingerprints to the Android app in Firebase
   **Project settings → Your apps**. Make sure the Google Cloud Android OAuth
   client has the matching package name and SHA-1. Register both debug and
   release certificates only if both build types are actually used.
4. Download the refreshed `google-services.json` for that app to
   `frontend/emergency_app/android/app/google-services.json`. This file is
   git-ignored. Check the project/app/client IDs and Android OAuth certificate
   hashes with:

   ```bash
   cd frontend/emergency_app
   python3 tool/verify_firebase_android_config.py \
     --file android/app/google-services.json \
     --project-id "$ERAS_FIREBASE_PROJECT_ID" \
     --web-client-id "$ERAS_GOOGLE_WEB_CLIENT_ID"
   ```

   The verifier checks the project ID, package name, Android OAuth client,
   matching Web client ID, and (when supplied) release SHA-1. The release APK
   script reads and prints the actual keystore SHA-1/SHA-256, then requires that
   the release SHA-1 be present in `google-services.json`. Compare SHA-256 in
   Firebase Console yourself; the JSON does not prove SHA-256, authorized
   JavaScript origins, or redirect URIs. Inspect those separately in Firebase
   and Google Cloud Console.
5. Keep Google Play Services available on the real test phone. A successful
   Gradle build alone does not prove native Google Sign-In works.

## 4. Backend and email environment

Set these in the production Render service's secret/environment settings. Never
paste a service-account key, API credential, email-provider key, or signing
password into Git, an issue, or chat.

| Variable | Required production value |
| --- | --- |
| `FIREBASE_PROJECT_ID` | Exact Firebase Project ID used by the web and Android clients |
| `FIREBASE_SERVICE_ACCOUNT` | Firebase Admin service-account JSON as a Render secret, or set `FIREBASE_SERVICE_ACCOUNT_FILE` to a protected secret-file path |
| `AUTH_OTP_SECRET` | Independent random secret, at least 32 characters; fallback is the already-strong `JWT_SECRET` |
| `RESEND_API_KEY` | Resend API key from the approved production email account |
| `EMAIL_FROM` | Verified sender, e.g. `ERAS <auth@your-verified-domain.example>` |
| `CORS_ORIGINS` | Exact comma-separated production Firebase Hosting/custom origins |
| `DATABASE_URL` | Existing production Neon PostgreSQL URL |
| `JWT_SECRET` | Existing strong production ERAS JWT secret |
| `NODE_ENV` | `production` |
| `TRUST_PROXY` | `1` on Render |
| `RATE_LIMIT_ENABLED` | `true` |

`FIREBASE_SERVICE_ACCOUNT` may reuse the existing `FCM_SERVICE_ACCOUNT` secret;
the backend accepts either name. The Firebase service account's project ID
must match `FIREBASE_PROJECT_ID`. Do not grant project Owner merely to verify
ID tokens. Use the narrowest Firebase Authentication permission approved for
this service. Deploy a secret only after reviewing the account's scope.

Email code delivery requires the sender domain to be verified with Resend. The
backend stores an HMAC digest of each code, limits attempts and sends, expires
codes, and does not return or log a live code. Email verification is required
for new email/password accounts. Existing migrated accounts keep their current
login behavior; Google identities are accepted only when Firebase marks the
Google provider email verified.

## 5. Build and deploy

### Web build

Run from `frontend/emergency_app` with the real Firebase Web config, OAuth Web
client ID, restricted Maps browser key, and Render API URL available as local
environment variables. The build helper passes Firebase config through Dart
defines and restores/removes the temporary Maps config on exit:

```bash
./tool/build_production_web.sh
```

The `ERAS_FIREBASE_*` values must all come from the same selected Firebase Web
app. Set `ERAS_FIREBASE_STORAGE_BUCKET` and `ERAS_FIREBASE_MEASUREMENT_ID` only
when those values are present in that app's config. Deploy explicitly to the
project you verified:

```bash
firebase projects:list
firebase deploy --only hosting --project "$ERAS_FIREBASE_PROJECT_ID"
```

Or use `./tool/deploy_firebase_web.sh`, which builds and deploys to the
explicit project ID. Do not commit a personal `.firebaserc` or deploy with an
implicit Firebase CLI default project.

### Backend

Apply the checked-in Prisma migration with the existing production deployment
procedure (`prisma migrate deploy`, never `migrate reset` or `db push`). Add the
variables above to Render before exposing the new Google/OTP endpoints. The
Render Blueprint contains `sync: false` declarations for values that must be
provided securely. Verify `/health`, Firebase token verification, email code
delivery, CORS, and rate limiting after deployment.

### Android release APK

Build only after `google-services.json`, Maps Android key, production signing
keystore, Firebase project, Google Web client ID, and HTTPS API URL have been
verified. The helper refuses a debug-signed release and validates Android
package/OAuth client IDs before invoking Flutter:

```bash
./tool/build_release_apk.sh
```

The output is `build/app/outputs/flutter-apk/app-release.apk`. Install that exact
APK on a real Android device; verify its signing certificate with Android
build tools and confirm its SHA-1/SHA-256 are the values registered in Firebase
and Google Cloud. Do not distribute an APK built with a debug key.

## 6. Required real acceptance flows

Use a dedicated non-admin test account and a real browser/Android device. The
following are separate acceptance cases; unit/widget tests do not count as
real provider verification.

1. **Web Google registration:** on the deployed Firebase Hosting origin, choose
   a Google account not yet registered in ERAS, choose REQUESTER or RESPONDER,
   complete the popup, and confirm exactly one PostgreSQL user is created with
   the verified Google email and selected role and that an ERAS JWT session is
   issued.
2. **Web Google login:** sign out and sign back in with that same Google
   account; verify the API session and role-based destination.
3. **Android Google login:** install the production-signed release APK on a
   physical Android device with Google Play Services; complete the native
   account chooser and verify the returned ERAS session and role-based route.
4. **Existing email/password login:** log in with a verified existing ERAS
   account and confirm the existing ERAS JWT `/api/auth/me` flow still works.
5. **First-time email verification:** register a new email/password account,
   receive the actual email, enter its six-digit code, and then log in.
6. **Forgot password:** request a real six-digit email code, set a new password,
   verify the old password is rejected and the new one succeeds.

Do not mark Google Sign-In fully verified until cases 1–3 pass on the real
production browser and physical Android device. Capture timestamps, app/build
version, project ID, package ID, test roles, response status, and pass/fail in a
private release record. Never include tokens, OTPs, service-account contents,
passwords, API keys, or personal details in the record.
