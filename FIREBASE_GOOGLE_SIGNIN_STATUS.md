# Firebase / Google Sign-In status

**Status as of 2026-10-04: implementation and automated checks are complete, but
production configuration, deployment, and real browser/device acceptance are NOT
complete. Google Sign-In and real email delivery are NOT fully verified — no
claim that Google Web sign-in is fixed may be made until the deployed site runs
the acceptance flows in `FIREBASE_GOOGLE_SIGNIN_SETUP.md`.**

## Implemented in this checkout

- Flutter Web uses Firebase Auth's own Google popup (`signInWithPopup`, with a
  `signInWithRedirect` fallback and a resume path for redirect returns and
  browser refreshes); Android uses Google Sign-In and exchanges the Google
  credential with Firebase Auth. The Web path does **not** use
  `google_sign_in`, whose web `signIn()` is an OAuth2 token-client flow that
  "can't reliably provide an `idToken`".
- The backend verifies Firebase ID tokens, resolves known Firebase UIDs, links a
  matching verified Google email to an existing active ERAS user without
  changing that user's role/password, or creates a new Google user. It issues
  the existing ERAS JWT; the current REST/Socket.IO bearer-token architecture
  remains in place.
- New password accounts start unverified and use a hashed, expiring,
  single-use six-digit code. Confirmation, code consumption, verification, and
  the persistent one-time welcome-email claim are transactionally coordinated;
  the welcome request is attempted only after the verification commit.
- New Google identities are marked verified and persist the same welcome-send
  claim at account creation. Existing Google logins and Google links to an
  existing ERAS user do not send a first-signup welcome message.
- Resend is attempted first and configured SMTP is the fallback. Sender checks,
  safe diagnostics, provider error redaction, and explicit accepted/failed /
  unconfigured states are implemented. Provider acceptance is not treated as
  inbox delivery (`*Delivered` remains unknown unless confirmed).
- Flutter auth parsing supports nested and flat response shapes, masks the
  verification destination, presents OTP/error/loading and first-time Google
  welcome states, and routes new users into the authenticated role flow.
- Existing Firebase Web/Android configuration validation, Render env
  declarations, deployment/build helpers, release-signing checks, and setup /
  deployment runbooks remain in place.

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

## Tests and live verification

- Backend JavaScript syntax checks (`node --check` across `src` and `tests`):
  **passed**.
- Targeted backend Jest suites on this branch: **91 passed across 11 suites**
  using a dummy `DATABASE_URL` only to load configuration; Prisma was mocked,
  so no database-backed behavior or migration was exercised. Coverage includes
  code hashing/expiry/attempt limits, registration/verification API flow,
  transactional/concurrent welcome claims, Resend acceptance/rejection, SMTP
  fallback, Google new/existing/linked-user paths, redaction, `/health`, and
  auth/security unit checks.
- `npm audit --omit=dev`: **0 production dependency vulnerabilities**. Full
  `npm audit` reports **3 high-severity development-only findings** in the
  existing `nodemon` → `chokidar` → `braces` chain; they are not in the Render
  production dependency tree.
- Prisma schema validation/generation and the regular `npm test` pretest hook
  were attempted, but Prisma could not download its engine because the sandbox
  TLS connection to `binaries.prisma.sh` was unavailable. Migration deployment
  and schema verification therefore did not start; there is also no reachable
  test PostgreSQL/`DATABASE_URL` in this workspace.
- Flutter/Dart executables are absent locally, so the fixes were validated in
  GitHub Actions instead of on this machine. The CI run for the fix branch
  (`arena/01a10788-emergency-resource-system`) passed `dart format`
  (0 changes), `flutter analyze` (no issues) and the complete Flutter test
  suite — **404 tests passed**, including the new Web Google strategy,
  cancellation/redirect, safe-error, registration-persistence, native-regression
  and PWA-metadata tests. The backend CI job passed too, including Prisma
  generation, migration/schema checks, the production dependency audit, and
  Jest. A release `flutter build web --release` compile check runs in the same
  pipeline. These CI results validate the checked-in implementation but do not
  replace production-provider or real-browser/device acceptance.
- No current Render deployment, Resend request, verified-sender/domain check,
  real email receipt, Google browser sign-in, physical Android sign-in, or
  production migration was performed. No production credentials/configuration
  were supplied to this workspace.

Use `FIREBASE_GOOGLE_SIGNIN_SETUP.md` for the deploy and real acceptance steps.
Update this report only after provider-console checks, deployment, and all
required real acceptance flows succeed. Until then, do not describe Google
Sign-In or email delivery as fully verified.
