# Firebase / Google Sign-In production checklist

**Current state: implementation and deployment helpers are prepared, but no
production Firebase/Render configuration, deployment, release APK, or real
browser/device acceptance has been completed. Google Sign-In is not yet fully
verified.**

This work preserves ERAS's existing auth architecture: Firebase Auth supplies a
Google identity proof, the backend verifies the ID token and resolves a
PostgreSQL user, then issues the existing ERAS JWT used by REST and Socket.IO.
The ERAS database remains authoritative for account status and role. Existing
email/password authentication stays in place. Account resolution first
checks for a known Firebase UID; otherwise, when a verified Google email
matches an active ERAS account, it attaches that Firebase UID to the existing
user without changing the existing role or password. This avoids duplicate
ERAS users while keeping all later authorization and sessions in the existing
ERAS backend.

The backend validates ID tokens against Google's published certificates, so
Firebase Admin service-account credentials are **not** required for Google
authentication. Optional Firebase service-account credentials used by FCM push
notifications are a separate feature. Never commit service-account keys,
OAuth secrets, email-provider credentials, database URLs, or release-keystore
passwords.

The Android application/package ID in the repository is
`io.github.sanjayravi7.eras`.

## 1. Firebase project and apps

1. Select the actual production Firebase project and record its exact Project
   ID. Do not guess or substitute a personal/preview project.
2. In **Authentication → Sign-in method**, enable **Google** and configure the
   support email and consent screen for the intended audience.
3. In **Authentication → Settings → Authorized domains**, add the exact
   Firebase Hosting/custom domains that will serve ERAS.
4. Register a Firebase **Web app** and record its `apiKey`, `appId`,
   `messagingSenderId`, `projectId`, and `authDomain` values. These are public
   browser configuration, supplied at build time; they are not backend
   service-account secrets.
5. Register the Android app with package ID
   `io.github.sanjayravi7.eras`. Download its `google-services.json` to
   `frontend/emergency_app/android/app/google-services.json`. That file is
   intentionally git-ignored.

## 2. Google OAuth Web client and browser origins

In Google Cloud Console, select the same project and inspect the OAuth 2.0 Web
client used by Firebase:

- Add each exact production JavaScript origin, for example
  `https://<project-id>.web.app`, `https://<project-id>.firebaseapp.com`, and
  any actually used custom domain. Only add local origins to a development
  client when needed.
- Confirm the authorized redirect URI matches the Firebase `authDomain` handler:
  `https://<authDomain>/__/auth/handler` (commonly
  `https://<project-id>.firebaseapp.com/__/auth/handler`). Verify the value in
  the actual Firebase/Google consoles; do not infer it from a Hosting URL.
- Record the complete Web client ID ending in
  `.apps.googleusercontent.com`. It is still passed to the **Web** build as
  `ERAS_GOOGLE_WEB_CLIENT_ID`, but the current web build authenticates through
  Firebase Auth's own Google popup/redirect flow and does not hand a client id
  to any Dart-side SDK, so the authoritative setting for the deployed site is
  the Firebase Authentication **authorized domains** list. Android does **not**
  take this value from the build: it
  reads the same client from the `default_web_client_id` string resource that
  the google-services Gradle plugin generates from `google-services.json`, so
  the ID-token audience can never drift from the registered Android OAuth
  client. See `GOOGLE_SIGNIN_ANDROID_DEVELOPER_ERROR_REPORT.md`.
- Verify all origins and clients belong to the selected production project.

## 3. Android signing fingerprints

1. Obtain SHA-1 and SHA-256 from the actual debug and production release
   signing certificates. Register the fingerprints on the Firebase Android app
   and confirm the matching Google Cloud Android OAuth client has package
   `io.github.sanjayravi7.eras` and the correct SHA-1.
2. Download a fresh `google-services.json` after updating Firebase. The helper
   verifies project/package/client IDs and the registered release SHA-1:

   ```bash
   cd frontend/emergency_app
   python3 tool/verify_firebase_android_config.py \
     --file android/app/google-services.json \
     --project-id "$ERAS_FIREBASE_PROJECT_ID" \
     --web-client-id "$ERAS_GOOGLE_WEB_CLIENT_ID"
   ```

3. The release helper prints the keystore's SHA-1/SHA-256 and requires the
   release SHA-1 to appear in the downloaded file. Compare SHA-256 separately
   in Firebase Console; the JSON does not attest it, nor does it validate Web
   origins/redirect URIs.
4. Google Play Services must be available on the physical test phone. A
   successful Gradle build alone is not proof that native sign-in works.

## 4. Backend and email configuration (Render)

Use the existing Render service and Neon database. Configure these values in
Render's environment/secret settings; do not put them in Git or chat.

| Variable | Production configuration |
| --- | --- |
| `FIREBASE_PROJECT_ID` | Exact Firebase Project ID used by the Web and Android apps. Required to verify Firebase ID tokens. |
| `GOOGLE_CLIENT_ID` | Comma-separated Google OAuth client ID(s), at minimum the Web client ID when Google OAuth ID tokens for that audience are accepted. |
| `CORS_ORIGINS` | Exact comma-separated Firebase Hosting/custom origins; never `*` in production. |
| `RESEND_API_KEY` | Resend credential for verification, post-verification welcome, and password-reset email requests. |
| `ERAS_MAIL_FROM` | The actual bare sender address verified with the configured provider; ERAS adds its display name. Do not enter a placeholder or invented domain. |
| `SMTP_URL` | Optional SMTP URL from your provider. When both transports are configured, ERAS tries Resend first and falls back to SMTP after a Resend failure. Keep SMTP credentials secret. |
| `DATABASE_URL` | Existing production Neon PostgreSQL connection string. |
| `JWT_SECRET` | Existing strong production ERAS JWT secret. |
| `NODE_ENV` | `production`. |
| `TRUST_PROXY` | `1` for Render. |
| `RATE_LIMIT_ENABLED` | `true`. |

`FIREBASE_PROJECT_ID` and `GOOGLE_CLIENT_ID` are identifiers, not secrets. The
Google token verifier fetches and caches Google's public signing certificates;
no private Firebase key is needed. Configure Resend and the actual verified
`ERAS_MAIL_FROM` before accepting real verification, welcome, or password-reset
email flows. SMTP is supported as a fallback (and as a sole transport); the
backend lockfile already includes Nodemailer. Code expiry, attempt limits, and
resend limits have defaults documented in `backend/.env.example`; change them
only after operational review.

Provider acceptance is reported separately from confirmed inbox delivery:
`emailRequestAccepted` / `welcomeEmailRequestAccepted` and
`emailDeliveryResult` (`accepted`, `failed`, `unconfigured`, or
`not_attempted`) describe the synchronous send request. `emailDelivered` /
`welcomeEmailDelivered` remains `null` until an actual provider delivery
confirmation is available. A success response or message ID alone is not proof
that the message reached the recipient's inbox. `GET /health/email` reports
only safe configuration state and never returns credentials or sender data.

## 5. Deploy backend and Web

### Backend

Use the existing Render Blueprint/deployment process. It installs the checked-in
lockfile, generates Prisma Client, and deploys migrations. Review
[`PRODUCTION_DEPLOYMENT.md`](PRODUCTION_DEPLOYMENT.md) before applying schema
changes. Use `prisma migrate deploy`, never `migrate reset` or `db push` against
production. Confirm the backend `/health` check succeeds and that the Firebase
project/client IDs, `CORS_ORIGINS`, email transport, and sender are configured.

### Firebase Web

From `frontend/emergency_app`, configure the production Web values locally and
build with the helper. It validates required inputs, supplies Firebase values
as Dart defines, temporarily writes the ignored Maps config, and restores it on
exit. The API URL must be HTTPS and end in `/api`:

```bash
cd frontend/emergency_app
./tool/build_production_web.sh
firebase projects:list
firebase deploy --only hosting --project "$ERAS_FIREBASE_PROJECT_ID"
```

`./tool/deploy_firebase_web.sh` is an optional shortcut that runs the build and
then deploys non-interactively to that explicit project ID. Required local build
values are `ERAS_API_BASE_URL`,
`ERAS_GOOGLE_MAPS_API_KEY`, `ERAS_FIREBASE_API_KEY`, `ERAS_FIREBASE_APP_ID`,
`ERAS_FIREBASE_MESSAGING_SENDER_ID`, `ERAS_FIREBASE_PROJECT_ID`,
`ERAS_FIREBASE_AUTH_DOMAIN`, and `ERAS_GOOGLE_WEB_CLIENT_ID`. Optional values
are `ERAS_FIREBASE_STORAGE_BUCKET`, `ERAS_FIREBASE_MEASUREMENT_ID`, and
`ERAS_FCM_VAPID_KEY` (Web push only). Restrict the Maps browser key by exact
HTTP referrers and required APIs. After deployment, add the Firebase origin to
Render's `CORS_ORIGINS` and restart/redeploy the API if it changed.

### Android release APK

Provide the production `google-services.json`, Android-restricted Maps key,
Firebase project/Web client IDs, HTTPS Render API URL ending in `/api`, and
production keystore settings locally. Then run:

```bash
cd frontend/emergency_app
./tool/build_release_apk.sh
```

The helper validates Firebase project/package/OAuth/SHA-1 values and refuses a
release without production signing variables. The expected output is
`build/app/outputs/flutter-apk/app-release.apk`. Do not distribute an APK
signed with a debug key. Install this exact production-signed build on a real
Android device before recording Android acceptance as passed.

## 6. Required real acceptance flows

Use dedicated non-admin test accounts and real provider/email services. Widget
and backend tests do not replace these real flows.

1. **Health/configuration:** verify `GET /health` still returns HTTP 200. Check
   `GET /health/email` for `transportConfigured`, `provider`, `fromConfigured`,
   `senderValid`, and `configurationError`; confirm the JSON contains no sender
   address, API key, SMTP URL/credentials, or user data.
2. **Password registration and verification:** register a new password account
   from the deployed Web UI. Confirm the database account begins unverified
   (`emailVerified=false`, `emailVerifiedAt=null`) and receives an
   `EMAIL_VERIFICATION` code whose stored value is a hash. Check that API
   `emailRequestAccepted` and `emailDeliveryResult` report the provider's real
   response; do not treat `emailDelivered=null` as a confirmed inbox delivery.
   Receive the actual six-digit ERAS message, verify the code, and confirm the
   welcome message is attempted only after the DB verification commit. Submit an
   invalid, expired, and already-used code and confirm none sends another
   welcome message. Repeat verification, refresh `/api/auth/me`, open another
   tab/session, and restart/redeploy the service; confirm the persisted claim
   still prevents duplicate welcome mail.
3. **New Google Web registration:** on the deployed Firebase Hosting origin,
   use a Google identity not yet registered in ERAS. Choose REQUESTER or
   RESPONDER. Confirm `isNewUser=true`, `emailVerified=true`, no OTP step, one
   new PostgreSQL user, the selected role, an ERAS JWT, and the role-based
   authenticated route. Check `welcomeEmailRequestAccepted` and
   `welcomeEmailDeliveryResult`; `welcomeEmailDelivered=null` until a delivery
   confirmation is actually received.
4. **Existing Google login / account linking:** sign out and sign in again
   with that same identity. Confirm `isNewUser=false`, the same ERAS user and
   role are returned, and no welcome email is sent again. Separately link a
   verified Google identity to a pre-existing password account: confirm the row
   is not duplicated, its original role/password are unchanged, Google
   verification is reflected without an ERAS OTP, and the account does not get
   a new-user welcome email.
5. **Android Google login:** install the production-signed APK on a physical
   Android phone with Google Play Services, complete native sign-in, and verify
   the ERAS session and role-based route. Android sign-in is not accepted based
   only on a successful build.
6. **Existing password login and reset:** authenticate a verified existing
   account and confirm the ERAS JWT `/api/auth/me` flow still works. Request and
   receive the actual six-digit password-reset code, set a new password, then
   verify the old password is rejected and the new one works.
7. **Operational checks:** verify CORS from the real Hosting origin, use a
   controlled invalid sender/provider response to confirm the UI shows a failure
   instead of claiming delivery, and inspect redacted logs for absence of
   recipient addresses, codes, passwords, JWTs, API keys, and SMTP credentials.

Do not describe Google Sign-In or real email delivery as fully verified until
these production Web, provider, and physical-device checks pass. Keep a private
release record of project/package/build IDs, timestamps, response statuses,
and pass/fail outcomes; never record tokens, codes, passwords, service-account
contents, or personal data. See [`FIREBASE_GOOGLE_SIGNIN_STATUS.md`](FIREBASE_GOOGLE_SIGNIN_STATUS.md)
for the current workspace verification status.
