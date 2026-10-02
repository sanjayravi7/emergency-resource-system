# Firebase / Google Sign-In status

**Status as of 2026-10-02: implementation and hosted CI checks pass, but production configuration, deployment, release APK, and real-device acceptance are NOT complete. Google Sign-In is NOT fully verified.**

## Implemented in this checkout

- Flutter Web uses Firebase Auth's Google popup; Android uses Google Sign-In and
  exchanges the Google credential with Firebase Auth.
- The backend verifies Firebase ID tokens, resolves known Firebase UIDs, links a
  matching verified Google email to an existing active ERAS user without
  changing that user's role/password, or creates a new Google user. It issues
  the existing ERAS JWT; the current REST/Socket.IO bearer-token architecture
  remains in place.
- New email/password accounts require a six-digit email verification code;
  password recovery requests and consumes a one-time six-digit code.
- The PR preserves the implementation already merged in PR #68 and adds
  production Firebase Web/Android configuration validation, Render env
  declarations, deployment/build helpers, release-signing checks, and setup /
  deployment runbooks. It does not add a second auth system or duplicate
  migrations.

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

- GitHub Actions on merge commit `743f4088a9927a0f4408965140eafeea14215935`:
  - [Backend workflow](https://github.com/sanjayravi7/emergency-resource-system/actions/runs/36995703861)
    **passed**, including Prisma Client generation, migrations/schema checks,
    the production dependency audit, and the full Jest suite against its
    PostgreSQL 16 service.
  - [Flutter workflow](https://github.com/sanjayravi7/emergency-resource-system/actions/runs/36995703877)
    **passed**: dependency install, `dart format`, `flutter analyze`, and
    `flutter test`. This workflow does not build a release APK.
- Local `npm ci --ignore-scripts`: passed; npm reported **0 vulnerabilities**
  for the restored main dependency lockfile.
- Local targeted backend Jest suites: **105 passed across 12 suites**, including
  Firebase token verification, auth-code rules, Google resolver tests (known
  UID login, verified-email link preserving role/password, new public-role
  account), security source audits, and unit tests. These tests used a dummy
  database URL; no database-backed behavior was exercised locally.
- A synthetic fixture passed the Android `google-services.json` verifier. This
  validates only the script's fixture checks, not any production Firebase
  value.
- The full database-backed Jest suite and Prisma-backed API suites were not run
  **locally** because this workspace has no test PostgreSQL and local Prisma
  engine download previously failed during TLS setup. The hosted Backend job
  above did run and pass those checks.
- Flutter tooling is absent locally. Hosted Flutter analysis/tests passed, but
  **no production release APK was built**. JDK/Android SDK, Firebase CLI,
  production configuration, and release signing key are not available here.
- Real browser Google registration/login: **not run**.
- Real Android Google login: **not run**; no Android device is attached.
- Real first-time email verification and six-digit password reset: **not run**;
  production Resend credentials and a verified sender are not configured.

Use `FIREBASE_GOOGLE_SIGNIN_SETUP.md` to supply the actual project configuration,
then update this report only after provider-console checks, deployment, and all
required real acceptance flows succeed. Until then, do not describe Google
Sign-In as fully verified.
