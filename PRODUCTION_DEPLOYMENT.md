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
| `TRUST_PROXY` | `1` |
| `RATE_LIMIT_ENABLED` | `true` |
| `FIREBASE_PROJECT_ID` | Firebase project id (Google sign-in token verification) |
| `GOOGLE_CLIENT_ID` | Google OAuth client id(s), comma separated (web + Android) |

`FIREBASE_PROJECT_ID` and `GOOGLE_CLIENT_ID` are optional but required for
Google sign-in: without them `POST /api/auth/google` answers
`503 Google sign-in is not configured on this server` and the client reports
that honestly. Email/password login and every emergency workflow keep working.
Both values are public identifiers, not secrets; the Firebase **web** config is
supplied to Flutter at build time with `--dart-define`. See
`frontend/emergency_app/FIREBASE_GOOGLE_SIGNIN_SETUP.md`.

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
or the Flutter registration UI. Public registration allows only those roles.
A new responder starts `OFFLINE` and receives no fabricated capabilities.

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

## 4. Firebase Hosting and Google Maps Web

`frontend/emergency_app/firebase.json` serves `build/web` and uses an SPA
fallback. No Firebase project ID is committed. Select the project explicitly at
deploy time rather than committing a personal `.firebaserc`:

```bash
cd frontend/emergency_app
firebase login
firebase projects:list
```

Create a Google Maps browser key with **HTTP referrer** restrictions for the
actual `web.app` and, if used, `firebaseapp.com` origins. Restrict the key to
Maps JavaScript API and Places API (New). Browser keys are visible to browser
users by design; referrer/API restrictions are the security boundary.

Build without writing the key to source control or logs:

```bash
cd frontend/emergency_app
read -r -p 'Render API URL ending in /api: ' ERAS_API_BASE_URL; export ERAS_API_BASE_URL
read -r -s -p 'Restricted Google Maps browser key: ' ERAS_GOOGLE_MAPS_API_KEY; echo; export ERAS_GOOGLE_MAPS_API_KEY
./tool/build_production_web.sh
firebase deploy --only hosting --project <firebase-project-id>
unset ERAS_API_BASE_URL ERAS_GOOGLE_MAPS_API_KEY
```

The script temporarily creates the already-ignored
`web/google_maps_config.js`, builds it into `build/web`, and restores/removes
the source config on exit. Do not upload the template placeholder as the
production config. Add the deployed Firebase origins to Render's
`CORS_ORIGINS`, then redeploy/restart Render if that setting changed.

## 5. Android release

The release uses the same Render origin and does not hardcode it in Dart:

```bash
cd frontend/emergency_app
flutter build apk --release \
  --dart-define=ERAS_API_BASE_URL=https://<render-service>.onrender.com/api
```

The Android manifest already has Internet and location permissions. Android's
existing Maps key setup remains separate. Use only HTTPS; never use localhost,
`127.0.0.1`, or `10.0.2.2` in a release build. Install the APK on a real phone
and verify GPS permissions and realtime behavior before recording Android as
passed.

## 6. Ordered smoke test

Do these against dedicated production-style test accounts and real device
locations, without fake coordinates.

1. **Neon:** confirm the database exists, all checked-in migrations are
   applied, no reset occurred, and expected tables exist.
2. **Render:** confirm `GET /health` returns HTTP 200 and exactly
   `{"success":true,"status":"ok"}`. Then test register, login, and
   authenticated `GET /api/auth/me`.
3. **REQUESTER:** register with `role=REQUESTER`; verify the stored and returned
   role and login.
4. **RESPONDER:** register with `role=RESPONDER`; verify the stored role,
   initial `OFFLINE` status, zero fake capabilities, and login response.
5. **Flutter Web:** verify both registration choices, role-based login routing,
   REST, Maps/location selection, request/responder flows, and Socket.IO from
   browser developer tools. Confirm CORS allows only the deployed origins.
6. **Android:** install the release APK on a real phone. Verify registration,
   login, both dashboards, readiness, real GPS permissions, request creation,
   Socket.IO, live responder location, PostgreSQL updates, and the complete
   allocation lifecycle.

Before sign-off, also confirm the Render service uses HTTPS/WSS, production
JWT and database secrets are not exposed, rate controls remain enabled,
password hashes are absent from responses, the Maps key is restricted, public
ADMIN registration fails, and no development account exists in Neon.
