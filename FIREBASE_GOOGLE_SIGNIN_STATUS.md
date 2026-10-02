# Firebase / Google Sign-In status

**Status as of 2026-10-02: implementation prepared; production configuration and real-device verification are NOT complete. Google Sign-In is NOT fully verified.**

## Implemented in this checkout

- Flutter Web uses Firebase Auth's Google popup; Android uses Google Sign-In and
  exchanges the Google credential with Firebase Auth.
- The backend verifies Firebase ID tokens, maps Google-created users to
  PostgreSQL, and issues the existing ERAS JWT. The current REST/Socket.IO
  bearer-token architecture remains in place.
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

- Backend JavaScript syntax checks: passed.
- Targeted backend unit tests (environment, error middleware, logger): **20
  passed**.
- Firebase token-verifier and Android JSON helper smoke checks: passed with
  synthetic test fixtures only; these do not verify production Firebase values.
- Full database-backed Jest suite: **not run**; this workspace has no configured
  database/credentials, and Prisma engine download failed because its binary
  endpoint was unreachable.
- Flutter analyze/widget tests and release APK build: **not run**; Flutter/Dart,
  JDK, and Android SDK tooling are absent.
- Real browser Google registration/login: **not run**.
- Real Android Google login: **not run**; no Android device is attached.
- Real first-time email verification and six-digit password reset: **not run**;
  production Resend sender credentials are not configured.

Use `FIREBASE_GOOGLE_SIGNIN_SETUP.md` to supply the actual project configuration,
then update this report only after provider-console checks, deployment, and all
six real acceptance flows succeed. Until then, do not describe Google
Sign-In as fully verified.
