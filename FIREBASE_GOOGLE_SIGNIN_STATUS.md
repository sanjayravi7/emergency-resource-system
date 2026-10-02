# Firebase / Google Sign-In status

**Status as of 2026-10-02: implementation prepared; production configuration and real-device verification are NOT complete. Google Sign-In is NOT fully verified.**

## Implemented in this checkout

- Flutter Web uses Firebase Auth's Google popup; Android uses Google Sign-In and
  exchanges the Google credential with Firebase Auth.
- The backend verifies Firebase ID tokens, resolves known Firebase UIDs,
  links a matching verified Google email to an existing active ERAS user without
  changing that user's role, or creates a new Google user. It issues the
  existing ERAS JWT; the current REST/Socket.IO bearer-token architecture
  remains in place.
- New email/password accounts require a six-digit email verification code;
  password recovery requests and consumes a one-time six-digit code.
- Added a non-destructive Prisma migration, provider/API handlers, rate limits,
  build-time Firebase Web configuration, Android Google Services Gradle setup,
  release signing checks, deployment helpers, and the setup runbook.

## External production facts not verified

| Item | Current verification |
| --- | --- |
| Firebase project ID | **Unknown** — no project alias or production Firebase config is present in this checkout. |
| Web/Android OAuth client IDs | **Unknown** — no actual Firebase config or OAuth console access is available here. |
| Authorized JavaScript origins | **Not inspected** — requires the real Google Cloud OAuth client. |
| Authorized redirect URI | **Not inspected** — requires the actual Firebase `authDomain` and OAuth client. |
| Android package name | Repository declares `io.github.sanjayravi7.eras`; **not cross-checked against a real Firebase Android app**. |
| SHA-1/SHA-256 | **Not computed or compared** — no production keystore/JDK is present. |
| `google-services.json` | **Absent** — the expected file is intentionally git-ignored and must be downloaded from the actual Firebase app. |
| Production Render environment | **Not inspected or changed** — no production environment values/service access are available in this workspace. |
| Firebase/Render deployments | **Not performed** — Firebase CLI is absent; no Render deployment client/credentials or verified project/service is available. |

No service-account keys, OAuth secrets, OTPs, passwords, or API keys were
present in the checked-in repository or supplied to the workspace. Do not send
them in chat; configure them in the corresponding provider secret stores.

## Tests and device flows

- `npm ci --ignore-scripts`: passed; npm reported **0 vulnerabilities** for the
  restored main dependency lockfile.
- Targeted backend Jest suites: **105 passed across 12 suites**, including
  Firebase token verification, auth-code rules, the new Google account
  resolver tests (known UID login, verified-email link preserving role, new
  public-role account),
  security source audits, and unit tests. A synthetic fixture also passed the
  Android `google-services.json` verifier; it proves only the script's fixture
  checks, not any production Firebase value. Tests ran with a dummy database
  URL; no database-backed behavior was exercised.
- Full database-backed Jest suite: **not run**; this workspace has no local
  PostgreSQL/test database. Prisma Client generation is also unavailable here:
  downloading its engine from `binaries.prisma.sh` previously failed during TLS
  connection setup, and the ignored-scripts dependency install intentionally
  did not generate Prisma Client.
- `passwordResetApi`, Prisma-backed security API tests, and the full auth/API
  suites could not run without a generated client and test database.
- Flutter analyze/widget tests and release APK build: **not run**; Flutter/Dart,
  JDK, and Android SDK tooling are absent.
- Real browser Google registration/login: **not run**.
- Real Android Google login: **not run**; no Android device is attached.
- Real first-time email verification and six-digit password reset: **not run**;
  production Resend credentials and a verified sender are not configured.

Use `FIREBASE_GOOGLE_SIGNIN_SETUP.md` to supply the actual project configuration,
then update this report only after provider-console checks, deployment, and all
required real acceptance flows succeed. Until then, do not describe Google
Sign-In as fully verified.
