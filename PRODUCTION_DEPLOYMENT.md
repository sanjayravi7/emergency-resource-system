# ERAS production deployment runbook

This runbook prepares, but does not itself create, the Neon, Render, Firebase,
or Google Cloud resources. Replace every angle-bracket placeholder locally;
never commit the resulting values. The production topology is:

- Neon PostgreSQL is the only database.
- Render serves Express REST at `/api` and Socket.IO at `/socket.io`.
- Firebase Hosting serves the Flutter Web static bundle.
- Flutter Web and Android use the same absolute HTTPS Render API URL.

Using an absolute Render URL is deliberate. Firebase Hosting does not provide a
generic external-origin reverse proxy that can safely proxy both ERAS REST and
the Socket.IO upgrade. The Dart default remains `/api` for local/same-origin
setups, while production builds supply `ERAS_API_BASE_URL` at build time.

## 1. Neon PostgreSQL

1. Create a production project/database and copy its PostgreSQL connection
   string into Render's secret `DATABASE_URL`. Use SSL as required by Neon.
2. Do not put the URL in `.env`, a command committed to source, CI output, or a
   screenshot. Do not run `prisma migrate dev`, `prisma db push`, or a reset.
3. The Render build executes `npx prisma migrate deploy` against the checked-in
   `backend/prisma/migrations` history. Review the first deployment log without
   publishing its environment values.
4. After deployment, inspect the Neon console or run `npx prisma migrate status`
   from a trusted environment to confirm all migrations are applied and the
   expected tables exist. Never point automated application tests at production.

The deployment does **not** run `npm run seed`. In addition, the development
seed now refuses to run with `NODE_ENV=production`.

## 2. Render backend

Create a Render Blueprint from the repository's `render.yaml`. It pins the
backend root directory, so commands operate on `backend/package.json`:

- build: `npm ci && npx prisma generate && npx prisma migrate deploy`
- start: `npm start`
- health check: `/health`

Configure the prompted values in the Render dashboard:

| Variable | Value |
| --- | --- |
| `NODE_ENV` | `production` (set by Blueprint) |
| `DATABASE_URL` | Neon production connection string (secret) |
| `JWT_SECRET` | Blueprint-generated random value, or a random value of at least 32 characters |
| `JWT_EXPIRES_IN` | `7d` |
| `CORS_ORIGINS` | comma-separated exact Firebase origins |
| `FIREBASE_PROJECT_ID` | exact Firebase project shared by Web and Android |
| `GOOGLE_CLIENT_ID` | comma-separated Google OAuth client IDs; include the production Web client ID |
| `RESEND_API_KEY` | Resend key for verification, welcome, and reset email requests |
| `ERAS_MAIL_FROM` | the actual bare sender address verified with the configured provider; do not use a placeholder or invented domain |
| `SMTP_URL` | optional SMTP fallback (or sole transport) supplied by your provider; keep its credentials secret |
| `TRUST_PROXY` | `1` |
| `RATE_LIMIT_ENABLED` | `true` |

Configure `FIREBASE_PROJECT_ID` for Firebase ID tokens and `GOOGLE_CLIENT_ID`
for Google OAuth ID tokens. Use the same project/client configuration as the
Firebase Web and Android apps. The values are public identifiers, not secrets;
the backend verifies token signatures using Google's published certificates
and does not need a Firebase Admin service-account key for Google sign-in. The
Flutter Google client also needs the Web OAuth client ID at build time. See
`frontend/emergency_app/FIREBASE_GOOGLE_SIGNIN_SETUP.md`.

Configure Resend and the actual verified `ERAS_MAIL_FROM` before relying on
email verification or password reset. SMTP is supported as a fallback (or sole
transport), and Nodemailer is included in the backend dependencies. Without a
configured transport and valid sender, code delivery is not complete.

The backend distinguishes provider acceptance from confirmed inbox delivery:
`emailRequestAccepted` / `welcomeEmailRequestAccepted` and
`emailDeliveryResult` report the send request state; `emailDelivered` /
`welcomeEmailDelivered` remain `null` until a provider delivery confirmation
exists. An accepted provider response is not proof the message reached an inbox.
`GET /health/email` exposes only safe transport configuration status.

For example, after the Firebase project is known, `CORS_ORIGINS` may contain
both of its real origins:

```text
https://<project-id>.web.app,https://<project-id>.firebaseapp.com
```

Do not use `*` in production. Android does not rely on browser CORS and will
continue to call the HTTPS endpoint. The remaining body-limit, rate-limit,
Socket.IO location, session-revalidation, and Photon variables have safe code
defaults documented in `backend/.env.example`; override them only after an
operational review. Keep rate limiting and Socket.IO controls enabled.

Render assigns the public hostname. Record, but do not hardcode, these values:

```text
API base:   https://<render-service>.onrender.com/api
Socket.IO:  https://<render-service>.onrender.com/socket.io
Health:     https://<render-service>.onrender.com/health
```

`SocketService` removes the trailing `/api` path from an absolute Dart define,
so it connects to the Render origin. The existing Socket.IO event protocol and
location stream are unchanged.

## 3. Safe production accounts

Create REQUESTER and RESPONDER test accounts through `POST /api/auth/register`
or the Flutter registration UI. Email/password accounts must complete the
six-digit email verification before login. Public registration allows only
those roles. A new responder starts `OFFLINE` and receives no fabricated capabilities.

Never run the development seed on Neon. If the first production ADMIN is
needed, run the explicit one-time script from a trusted workstation with an
approved direct Neon connection. Use hidden shell input rather than putting
secrets in shell history:

```bash
cd backend
export NODE_ENV=production
read -r -s -p 'Neon DATABASE_URL: ' DATABASE_URL; echo; export DATABASE_URL
read -r -p 'Admin name: ' ERAS_ADMIN_NAME; export ERAS_ADMIN_NAME
read -r -p 'Admin email: ' ERAS_ADMIN_EMAIL; export ERAS_ADMIN_EMAIL
read -r -s -p 'Admin password (12+ chars): ' ERAS_ADMIN_PASSWORD; echo; export ERAS_ADMIN_PASSWORD
export ERAS_CONFIRM_ADMIN_PROVISION=PROVISION_ONE_ADMIN
npm ci
npx prisma generate
npm run provision:admin
unset DATABASE_URL ERAS_ADMIN_NAME ERAS_ADMIN_EMAIL ERAS_ADMIN_PASSWORD ERAS_CONFIRM_ADMIN_PROVISION NODE_ENV
```

The script creates exactly one new ADMIN, refuses to overwrite any existing
user, hashes the password, and does not print the password or database URL.
After bootstrap, use the existing authenticated administrator role-management
workflow. Never expose an ADMIN registration route.

## 4. Firebase Hosting, Firebase Auth, and Google Maps Web

`frontend/emergency_app/firebase.json` serves `build/web` and uses an SPA
fallback. No Firebase project ID is committed. Select the verified project
explicitly at deploy time rather than committing a personal `.firebaserc`:

```bash
cd frontend/emergency_app
firebase login
firebase projects:list
```

Firebase Auth Google provider, OAuth Web client IDs, exact authorized
JavaScript origins/redirect URIs, Android package/SHA fingerprints,
`google-services.json`, backend secrets, build and real-device acceptance
steps are detailed in [`FIREBASE_GOOGLE_SIGNIN_SETUP.md`](FIREBASE_GOOGLE_SIGNIN_SETUP.md).
The Flutter Web build now requires same-project Firebase Web config values and
the Google OAuth Web client ID as Dart defines.

Create a separate Google Maps browser key with **HTTP referrer** restrictions
for the actual deployed origins. Add both `https://eras.website/*` and
`https://eras-production-f3ce6.web.app/*`. Restrict it to Maps JavaScript API
and Places API (New); never use a server/IP-restricted key for browser Maps.
Browser keys are visible to browser users by design; referrer/API restrictions
are the security boundary.

Run `./tool/build_production_web.sh` with the production `ERAS_API_BASE_URL`,
`ERAS_GOOGLE_MAPS_API_KEY`, `ERAS_FIREBASE_API_KEY`,
`ERAS_FIREBASE_APP_ID`, `ERAS_FIREBASE_MESSAGING_SENDER_ID`,
`ERAS_FIREBASE_PROJECT_ID`, `ERAS_FIREBASE_AUTH_DOMAIN`, and
`ERAS_GOOGLE_WEB_CLIENT_ID` available in the local environment. Optional Web
config values are `ERAS_FIREBASE_STORAGE_BUCKET` and
`ERAS_FIREBASE_MEASUREMENT_ID`. Then deploy only to the project you verified:

```bash
firebase deploy --only hosting --project "$ERAS_FIREBASE_PROJECT_ID"
```

The web build script temporarily creates the already-ignored
`web/google_maps_config.js`, builds it into `build/web`, and restores/removes
the source config on exit. Do not upload the template placeholder as the
production config. Add the deployed Firebase origins to Render's
`CORS_ORIGINS`, then redeploy/restart Render if that setting changed.

## 5. Android release

Register the exact package `io.github.sanjayravi7.eras`, add the actual debug
and production release SHA-1/SHA-256 fingerprints to Firebase, download
`android/app/google-services.json`, and configure the Android Maps key and
production release keystore as described in
[`FIREBASE_GOOGLE_SIGNIN_SETUP.md`](FIREBASE_GOOGLE_SIGNIN_SETUP.md).

Run `./tool/build_release_apk.sh` with the production Render HTTPS URL,
`ERAS_FIREBASE_PROJECT_ID`, `ERAS_GOOGLE_WEB_CLIENT_ID`, Android `MAPS_API_KEY`,
and release keystore variables available locally. The helper validates the
Firebase project/package/OAuth client values and refuses debug signing. Use
only HTTPS; never use localhost, `127.0.0.1`, or `10.0.2.2` in a release
build. Install the resulting APK on a real phone and verify Google Sign-In,
GPS permissions, and realtime behavior before recording Android as passed.

## 6. Ordered smoke test

Do these against dedicated production-style test accounts and real device
locations, without fake coordinates.

1. **Neon:** confirm the database exists, all checked-in migrations are
   applied, no reset occurred, and expected tables exist.
2. **Render:** confirm `GET /health` returns HTTP 200 and exactly
   `{"success":true,"status":"ok"}`. Confirm Firebase project/client IDs
   match the Web and Android apps; test email delivery and authenticated
   `GET /api/auth/me`.
3. **Email/password:** register a new REQUESTER, receive and submit the actual
   six-digit verification email, then complete the existing email/password
   login. Verify a pre-existing verified account can still log in.
4. **Password reset:** request the actual six-digit code, set a new password,
   confirm the old password is rejected and the new password succeeds.
5. **Web Google:** on the production Firebase Hosting origin in a real browser,
   perform one Google registration and a separate Google login with the same
   verified account. Confirm selected role, returned ERAS JWT, route, and
   allowed CORS origin.
6. **Android Google:** install the production-signed release APK on a physical
   phone and complete native Google login. Confirm Firebase project, package,
   release SHA-1/SHA-256, and ERAS role/session match the console values.
7. **Operational app:** verify both registration roles, role-based routing,
   REST, Maps/location selection, request/responder flows, Socket.IO,
   PostgreSQL updates, GPS permissions, and the complete allocation lifecycle
   on deployed Web and Android clients.

Before sign-off, also confirm the Render service uses HTTPS/WSS, production
JWT and database secrets are not exposed, rate controls remain enabled,
password hashes are absent from responses, the Maps key is restricted, public
ADMIN registration fails, and no development account exists in Neon.
