# ERAS — Google Sign-In Production Readiness / Acceptance Report

Date: 2026-10-02 · Branch: `arena/01a0fc79-emergency-resource-system` (HEAD `da656b5`, "Prepare Firebase Google Sign-In production release (#69)")
Scope: verification only. **No repository file was modified in this audit** (working tree clean before and after).
No production value (project ID, OAuth client ID, SHA fingerprint, `google-services.json`, keystore, Resend key, Render secret, API key) was invented, and none was found committed.

## Legend

- **VERIFIED** — actually executed here against the real production configuration.
- **BLOCKED** — cannot proceed until a real production value/access exists (credential, console, keystore, device).
- **NOT TESTED** — could be executed once unblocked; not executed in this workspace.
- **Code-level: PASS** — static inspection or repository test suites executed (local or hosted CI); this is NOT production verification and never satisfies a checklist box alone.

## 1. Documents and expected configuration — inspected

- `FIREBASE_GOOGLE_SIGNIN_SETUP.md` (root production checklist) and `frontend/emergency_app/FIREBASE_GOOGLE_SIGNIN_SETUP.md` (app-level setup) are separate, consistent documents. Both, plus `PRODUCTION_DEPLOYMENT.md`, expect exactly `FIREBASE_PROJECT_ID` and `GOOGLE_CLIENT_ID` (comma-separated) on Render.
- Code confirms the expectation: `backend/src/config/env.js` reads `FIREBASE_PROJECT_ID` and splits `GOOGLE_CLIENT_ID` into `GOOGLE_CLIENT_IDS`; when neither is set, `isGoogleAuthConfigured()` is false and `POST /api/auth/google` answers 503 while email/password keeps working.
- `render.yaml` declares `FIREBASE_PROJECT_ID`, `GOOGLE_CLIENT_ID`, `CORS_ORIGINS`, `RESEND_API_KEY`, `ERAS_MAIL_FROM`, `DATABASE_URL` as `sync: false` (operator-supplied, never committed), plus `JWT_SECRET: generateValue`, `NODE_ENV=production`, `TRUST_PROXY=1`, `RATE_LIMIT_ENABLED=true`, health check `/health`. `backend/.env.example` documents the same names. **Code-level: PASS.**
- Android package `io.github.sanjayravi7.eras` is declared in `android/app/build.gradle.kts` (`namespace` + `applicationId`), `MainActivity.kt` package, and is the default in `tool/verify_firebase_android_config.py`. `google-services.json` is absent and git-ignored at three levels (root, app, android). **Code-level: PASS.** Cross-check against a real Firebase Android app: **BLOCKED**.

## 2. Secrets audit — VERIFIED (clean)

Executed against every tracked file (history is one squashed commit, so tree == full history):

- `git ls-files` shows no `.env`, no `google-services.json`, no `GoogleService-Info.plist`, no `secrets.properties`/`key.properties`, no `*.keystore`/`*.jks`, no `service-account*.json`, no `google_maps_config.js` (only the placeholder template is tracked).
- `git grep -I`/`-a` for PEM private keys, AWS `AKIA…`, GCP `AIza…`, GitHub tokens, Stripe/OpenAI keys, Resend `re_live/re_test`, Slack tokens, JWT-like `Bearer eyJ…`: **zero hits** (only documented placeholder forms such as `# RESEND_API_KEY=re_...` and `<project-id>.firebaseapp.com`).
- Binary-safe scan of the 11 tracked `frontend/emergency_app/build/**` leftovers (gradle stamps, asset manifests, font, NOTICES, shaders): clean. Suggest untracking them in a future housekeeping change (not done here — acceptance-only task).
- No credential assignments in source beyond test placeholders; git remote is plain HTTPS with no embedded token; working tree has no untracked non-ignored files.

## 3. Config scripts — VERIFIED against SYNTHETIC FIXTURES ONLY (explicitly non-production)

`tool/verify_firebase_android_config.py` (5 fixture cases + real-path check): valid fixture passes; wrong project ID, wrong package, unregistered release SHA-1, and missing Web client ID each fail with the correct specific message; against the real (absent) `android/app/google-services.json` it fails "missing" — the expected BLOCKED state.

`tool/build_production_web.sh`: refuses to start with any of the 8 required `ERAS_*` vars missing; rejects `ERAS_API_BASE_URL` not matching `^https://<host>/api/?$` (so `https://eras-api-sdjo.onrender.com` **without** `/api` is rejected; `https://eras-api-sdjo.onrender.com/api` is the required form); rejects a malformed OAuth Web client ID; with synthetic values all guards pass, exactly the 7 Firebase dart-defines + API base + Maps key are injected (confirmed via a shimmed `flutter` log), the temporary `web/google_maps_config.js` is written for the build and the pre-existing file is restored on exit.

`tool/build_release_apk.sh`: requires keystore vars and a present keystore file; requires `keytool`; extracts release SHA-1/SHA-256 from the keystore certificate; runs the Firebase Android verifier with `--release-sha1`; writes `android/secrets.properties` for the Maps key (restored on exit); invokes `flutter build apk --release --dart-define=ERAS_API_BASE_URL=… --dart-define=ERAS_GOOGLE_WEB_CLIENT_ID=…`; output path `build/app/outputs/flutter-apk/app-release.apk`. `android/app/build.gradle.kts` additionally throws if a release task is requested without production signing (debug signing cannot pass silently).

`tool/deploy_firebase_web.sh`: refuses without an explicit `ERAS_FIREBASE_PROJECT_ID`; runs the build first, then `firebase deploy --only hosting --project "$ERAS_FIREBASE_PROJECT_ID" --non-interactive`. Firebase CLI is absent in this workspace — deploy itself **BLOCKED**.

All of the above exercises script logic only; none of it touches (or could satisfy) real production values.

## 4. Release APK source + API URL

- The helper builds `frontend/emergency_app` from the current working-tree Flutter source (it is the only Flutter app in the repo; no cached bundle path is used by the script).
- Required URL per repo enforcement: `ERAS_API_BASE_URL=https://eras-api-sdjo.onrender.com/api`. The host matches the required Render service; the `/api` suffix is mandatory because the Dart client composes `$baseUrl/auth/...` and the Express app mounts routes under `/api` (verified in `api_service.dart` and `app.js`).
- Observation (no change made): doc comments (`firebase_bootstrap.dart` header, `SECURITY_HARDENING_REPORT.md` §build table) show the bare `https://eras-api-sdjo.onrender.com` form with a raw `flutter build` command; that form fails the production helper's guard and would misroute endpoints. Operators must use the helper or add `/api`.
- Actual release APK built here: **NOT TESTED** — this workspace has no Flutter SDK, Android SDK, JDK/`keytool`, keystore, or production `google-services.json` (and the old APK recorded in `SECURITY_HARDENING_REPORT.md` was built without `google-services.json`, so it is not a production-signing candidate).

## 5. Auth invariants — Code-level: PASS (tests executed; production flow NOT TESTED)

Executed locally in this workspace (backend suite, Jest, DB-free suites; Prisma engines cannot download here — TLS-blocked, matching the status doc):
`tests/auth/googleAuthService.test.js` (linked-UID login; verified-email link **preserves role and password, never duplicates**; creation only for REQUESTER/RESPONDER with random unguessable password hash),
`tests/auth/googleIdentity.test.js` (RS256 against Google certs, kid rotation, `iss`/`aud`/`exp` checks, unverified-email refusal, fail-closed 503, cert caching),
`tests/auth/authCodeService.test.js` (6-digit CSPRNG codes, bcrypt-hashed at rest, single-use, expiry+burn, attempt limit, re-issue invalidation, cooldown, rolling budget, per-purpose scoping),
`tests/security/authMiddleware.test.js` (role always from DB, not token claims), `tests/security/massAssignmentAudit.test.js` (public-role allowlist and untouched-linking role asserted at source level), `tests/security/httpHardening.test.js`, `tests/security/rateLimit.test.js`, `tests/security/securityHeaders.test.js`, `tests/unit/*` (incl. production JWT-secret strength enforcement), `tests/validators/*` — **17 suites / 147 tests passed locally**.
7 DB-backed suites (incl. `auth.test.js`, `registrationRole.test.js` with its ADMIN-escalation and duplicate-email tests, `passwordResetApi.test.js`) could not run locally — the only failures are sandbox data-layer stubs (individually confirmed), and these suites do not replace real acceptance anyway.

Independently verified via GitHub (`gh api`, HEAD `da656b5`): **Flutter #269** (`flutter pub get`, `dart format`, `flutter analyze`, `flutter test`) and **Backend #129** (`npm ci`, `prisma generate`, `prisma migrate deploy` on PostgreSQL 16, `verify-schema`, `npm audit --omit=dev`, full `npm test`) both **success**.
Code review additionally confirms: `POST /api/auth/google` issues the existing ERAS JWT via the same `createTokenForUser` path as password login; the REST/Socket.IO bearer architecture is untouched; ADMIN is rejected at validator and service layers for both registration paths; deactivated accounts are refused through Google too.
Email/password flow untouched by the Google work: register/login/verify/resend/forgot/verify-code/reset routes and bcrypt checks verified present and exercised by the CI-passed suites; no behavioral edit was made in this audit (tree clean).

## 6. Production probes attempted

`eras-api-sdjo.onrender.com` resolves (Render Cloudflare edge) but outbound TLS to it is blocked from this sandbox (`SSL_ERROR_SYSCALL`; same restriction blocked `binaries.prisma.sh`), so `/health`, `/api/auth/me`, and the 503-vs-401 config probe were **not executed**. Render/Firebase dashboards and Google Cloud consoles are not accessible from this workspace. No claim about live production state is made here.

## FINAL ACCEPTANCE CHECKLIST

Statuses below are for execution against the REAL production configuration. "supported by tests/CI" never turns a box into VERIFIED.

Every box below stays UNCHECKED: a box is ticked only when the item was executed against the real production configuration, which did not happen in this workspace. The status line before each name is this audit's finding.

WEB
[ ] BLOCKED — Google registration (no Firebase project / Render env values exist here; deployed-origin flow not executable)
[ ] BLOCKED — Google login for existing Google-linked account (depends on the above; no production backend reachable)
[ ] NOT TESTED — Existing password account behavior (code-level PASS locally + hosted CI; production account not exercised)
[ ] BLOCKED — Email verification (code rules PASS via 12 unit tests; real code delivery needs `RESEND_API_KEY`/`ERAS_MAIL_FROM`, absent by design)
[ ] BLOCKED — Resend verification (same missing production email transport; endpoint + cooldown/limits logic code-level PASS)
[ ] BLOCKED — Forgot password (flow + validators code-level PASS; real delivery blocked on email config)
[ ] BLOCKED — 6-digit reset code (format/expiry/single-use code-level PASS; production delivery blocked)
[ ] NOT TESTED — Expired/used reset code rejection (covered by unit tests + CI; not exercised against production DB/API reachable from here)

ANDROID
[ ] BLOCKED — Signed release APK (no keystore/JDK/Android SDK/Flutter here; helper + signing guard logic verified synthetically)
[ ] BLOCKED — Firebase Android configuration (`google-services.json` absent by design; verifier verified against synthetic fixtures only)
[ ] BLOCKED — Google login (needs production-signed APK on a Play-Services device + deployed backend)
[ ] BLOCKED — Correct ERAS role (linking/role preservation code-level PASS: mock suites + source audit; device-level needs the APK above)
[ ] NOT TESTED — Location permission (manifest declares INTERNET + COARSE/FINE; per `MANUAL_ACCEPTANCE_CHECKLIST.md` A1–A6 this is device-only and not automated)
[ ] NOT TESTED — Authenticated dashboard (needs device + production backend session)

PRODUCTION
[ ] BLOCKED — Firebase deployed (Firebase CLI absent; no project ID/credentials to verify or deploy; must not be invented)
[ ] BLOCKED — Render deployed (no Render access here; production host TLS-unreachable from sandbox; deploy state unverified)
[ ] BLOCKED — Correct environment variables (repo expectations VERIFIED: `FIREBASE_PROJECT_ID`, `GOOGLE_CLIENT_ID`, `CORS_ORIGINS`, `RESEND_API_KEY`, `ERAS_MAIL_FROM` declared in `render.yaml`/docs/code; actual Render values not inspectable)
[ ] BLOCKED — Production web origin (JavaScript origins/authorized domains require the real Google Cloud/Firebase consoles)
[ ] BLOCKED — Android SHA-1 (real keystore fingerprint cannot be computed here; script's SHA-1 attestation flow verified with synthetic fixtures)
[ ] BLOCKED — Android SHA-256 (console-only check by design — `google-services.json` does not attest SHA-256; helper's SHA-256 extraction verified synthetically)
[ ] BLOCKED — Real email sender configured (Resend API key + verified sender are production secrets; absent by design and not to be invented)

## Overall roll-up

- VERIFIED: 0 of 21 production items. (Auxiliary, non-checklist verifications actually executed: no committed secrets; repository env-var expectations; Android package in repo; all four helper scripts' guard logic via synthetic fixtures; 17 Jest suites/147 auth & security tests locally; hosted CI green on HEAD #269 + #129.)
- BLOCKED: 15 items — all require real production values/access: Firebase project ID + Web config, OAuth client IDs, `google-services.json`, Render env values, real origins, release keystore + SHA fingerprints, Resend sender, and the deployments themselves. Supply them per `FIREBASE_GOOGLE_SIGNIN_SETUP.md` §1–4 (locally; never in Git or chat) to unblock.
- NOT TESTED: 6 items — executable in principle once deploy + accounts exist: password account behavior, expired/used reset-code rejection (against production), location permission, authenticated dashboard, and the two device/browser flows that need only an existing deployment.

Recommended unblocking order: 1) supply Render `FIREBASE_PROJECT_ID`/`GOOGLE_CLIENT_ID`/`CORS_ORIGINS`/`RESEND_API_KEY`/`ERAS_MAIL_FROM` and restart; 2) build+deploy Web via `./tool/build_production_web.sh` → `firebase deploy --only hosting --project …`; 3) run `./tool/build_release_apk.sh` with the real keystore + downloaded `google-services.json`; 4) execute the 7 real acceptance flows of `FIREBASE_GOOGLE_SIGNIN_SETUP.md` §6 and the `PRODUCTION_DEPLOYMENT.md` §6 smoke test; 5) update `FIREBASE_GOOGLE_SIGNIN_STATUS.md` only from private execution records (statuses/timestamps only — never tokens, codes, or personal data).
