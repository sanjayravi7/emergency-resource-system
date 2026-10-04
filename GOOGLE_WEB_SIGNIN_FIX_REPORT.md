# Google sign-in on Flutter Web — fix report

Branch: `arena/01a10788-emergency-resource-system` · PR:
<https://github.com/sanjayravi7/emergency-resource-system/pull/83>

> **Verification status.** The code change and its automated checks are
> complete and green in CI (see item 10). The **live** Google flow on the
> deployed site has **not** been reproduced, debugged or accepted yet: this
> workspace has no browser, no Flutter/Dart SDK, and its network cannot reach
> Google, Firebase or the deployed hosts (TLS egress filtered). Nothing below
> claims that Google Web sign-in is fixed in production; item 2 states exactly
> what is still missing and how to capture it.

---

## 1. Root cause

**Not established by a live debug reproduction — and deliberately not guessed.**
What the code and the exact plugin sources in the deployed dependency set
(`google_sign_in 6.3.0` / `google_sign_in_web 0.12.4+4`, `firebase_auth 5.7.0` /
`firebase_auth_web 5.15.3`, per `pubspec.lock`) do prove is that the previous Web
mechanism was unsafe by construction:

1. On Flutter Web, ERAS obtained its Google identity through
   `google_sign_in`'s Web `signIn()`. That implementation is an **OAuth2
   *token* client** flow (`google.accounts.oauth2`, `requestAccessToken`) that
   the plugin itself documents as unable to "reliably provide an `idToken`".
   When no GIS credential response exists it synthesizes the user through the
   **People API**, so `idToken` can legitimately be `null` and only an
   `access_token` survives.
2. ERAS then had to build `GoogleAuthProvider.credential(idToken:?, accessToken:?)`
   and hand it to Firebase Auth. With a null ID token this depends on Firebase's
   Google provider accepting an access token minted for the token client's
   OAuth client — a fragile, environment-dependent exchange that fails with
   runtime errors rather than a typed, actionable failure.
3. The same path had three further, independent ways to break on the deployed
   site: a popup that the browser blocks (no fallback existed), Firebase Auth
   not yet initialized on the first click (initialization was not awaited), and
   a Web build without a usable Google Web client id — `google_sign_in_web`'s
   `initWithParams` only **asserts** on that in debug and then constructs
   `GisSdkClient(clientId: appClientId!)`, a real null-check throw in release
   builds.
4. Any error raised inside those plugin/SDK callbacks escaped to the browser as
   a minified `Uncaught Error` against `main.dart.js`, because the app installed
   no global Flutter/async error handler. That matches the reported production
   symptom exactly; it does **not** yet prove which of the four paths fired
   first.

The fix therefore removes the whole class of failure: the Web path no longer
touches `google_sign_in`, uses Firebase Auth's own supported Google popup (with
a redirect fallback and a resume path), validates every API response, maps every
failure to one safe sentence, and installs a last-resort client error guard.

## 2. Exact exception found in debug

**Not captured: a debug reproduction was impossible in this environment.**
There is no `flutter`/`dart` binary, no Chrome/Chromium, and every Google,
Firebase, Resend and production host is unreachable (`curl` → `000`, or
`OpenSSL SSL_connect: SSL_ERROR_SYSCALL`); only the GitHub API is reachable.
Running `flutter run -d chrome` here would be a fabricated claim, so it was not
made.

To capture it on a machine that can reach Google:

```bash
cd frontend/emergency_app
flutter run -d chrome \
  --dart-define=ERAS_API_BASE_URL=https://eras-api-sdjo.onrender.com/api \
  --dart-define=ERAS_FIREBASE_API_KEY=<web api key> \
  --dart-define=ERAS_FIREBASE_APP_ID=<web app id> \
  --dart-define=ERAS_FIREBASE_MESSAGING_SENDER_ID=<sender id> \
  --dart-define=ERAS_FIREBASE_PROJECT_ID=<project id> \
  --dart-define=ERAS_FIREBASE_AUTH_DOMAIN=<project>.firebaseapp.com \
  --dart-define=ERAS_GOOGLE_WEB_CLIENT_ID=<web client id>
```

The new diagnostics identify any residual failure without exposing secrets:
`[eras-auth] google web sign-in failed code=<firebase code>` (code only, never
the payload), `[eras-client] unhandled-async-error type=… message=<sanitized>`
from the global guard, and the sanitizer that redacts tokens/keys/passwords
before anything is printed (`sanitizeGoogleAuthDiagnosticMessage`). If the
failure still occurs, the browser console and the Flutter terminal will now name
the exact code and Dart exception type instead of `Uncaught Error`.

## 3. Files changed

| File | Change |
| --- | --- |
| `frontend/emergency_app/lib/services/google_auth_service.dart` | Web/native strategy split; Firebase Auth Web popup + redirect fallback + resume; safe Firebase error mapping; native picker path unchanged; secure diagnostics; registration hand-off for redirects. |
| `frontend/emergency_app/lib/services/client_error_reporting.dart` | **New.** Global `FlutterError.onError` + `PlatformDispatcher.onError` guard that logs one sanitized line and keeps the UI usable instead of surfacing `Uncaught Error`. |
| `frontend/emergency_app/lib/main.dart` | Installs the error guard and warms Firebase before `runApp` so the first Google click runs inside the user gesture. |
| `frontend/emergency_app/lib/services/api_service.dart` | `authResponseToken` (nested/flat, type-checked), type-checked `applySession`, and `googleSignIn` now rejects `success:false` or a missing token/user instead of building a half session. |
| `frontend/emergency_app/lib/screens/login_screen.dart` | Google sign-in through the new outcome API; resume on page load; "Continuing with Google in this tab…" on redirect; signs Firebase out when the ERAS exchange fails; safe error mapping. |
| `frontend/emergency_app/lib/screens/register_screen.dart` | Same for registration, with the selected public role persisted across a redirect and consumed exactly once. |
| `frontend/emergency_app/web/manifest.json` | `name`/`short_name` = **ERAS Console**, ERAS description. |
| `frontend/emergency_app/web/index.html` | Browser title, Apple app title, meta description, `theme-color`, accurate GIS/Firebase loader comment. |
| `frontend/emergency_app/test/google_web_signin_test.dart` | **New.** Web strategy, popup dismissed/blocked, redirect, resume, registration persistence, error mapping, native regression, sign-out. |
| `frontend/emergency_app/test/pwa_metadata_test.dart` | **New.** Locks the ERAS Console install name, title, metadata and manifest icons. |
| `frontend/emergency_app/test/google_signin_flow_test.dart` | Route-transition pump fix in the Google welcome flow (taken from PR #82) so the widget test passes deterministically. |
| `.github/workflows/dart.yml` | Removed the temporary CI diagnostics step (taken from PR #82). |
| `.github/workflows/eras-web-fix-probe.yml` | **Temporary** CI probe used to run format/analyze/test/build in this environment; removed at the end of the branch. |
| `FIREBASE_GOOGLE_SIGNIN_SETUP.md` (root + app copy), `FIREBASE_GOOGLE_SIGNIN_STATUS.md`, this report | Documentation of the new Web mechanism and of what remains to be configured/deployed. |

No backend file was changed: the server-side Google flow already verifies the
Firebase ID token, resolves/links/creates the ERAS user and issues the ERAS JWT.

## 4. What changed for Web

- **Mechanism**: `FirebaseAuth.signInWithPopup(GoogleAuthProvider())` — Firebase
  owns Google's OAuth UI, so ERAS receives a real **Firebase ID token** (never a
  Google access token).
- **Popup blocked / in-app browser**: the `auth/popup-blocked` and
  `auth/operation-not-supported-in-this-environment` codes switch to
  `signInWithRedirect`; the UI shows "Continuing with Google in this tab…" and
  the page finishes the flow when it returns.
- **Returning from a redirect or refreshing the page**: the login/register
  screen resumes in `initState` (`getRedirectResult()` then
  `currentUser.getIdToken()`), so a session survives a reload without another
  popup, and the chosen public registration role is restored from local storage
  and consumed exactly once.
- **Cancelled / dismissed**: reported as a normal cancellation — no error, no
  session change, no account created.
- **Every other failure** (unauthorized domain, Google provider disabled,
  network loss, invalid API key, browser storage blocked, backend 503, backend
  auth rejection, malformed API response): one safe ERAS sentence from
  `googleAuthErrorMessageForCode` / `erasGoogleGenericFailureMessage`, never a
  raw code, never a minified error.
- **Firebase readiness**: `ErasFirebaseConfig.ensureInitialized()` is warmed at
  startup and awaited before the first Google attempt; a build without the
  Firebase web config reports "not configured" instead of failing.
- **No secrets**: the Web build still receives only the public Firebase web
  config and the public OAuth client id, through the existing `--dart-define`
  architecture; no credential was added to the repository.

## 5. Mobile preservation

Android/iOS/desktop keep the platform account picker
(`GoogleSignIn.signIn()` → `signInWithCredential` → `getIdToken()`), unchanged
in behaviour. In particular the rule that fixed the earlier Android
`DEVELOPER_ERROR` (`sign_in_failed`, `h2: 10`) is preserved and still locked by
tests: the Android client passes **no** `clientId` and **no** `serverClientId`,
so the google-services plugin's `default_web_client_id` stays in charge of the
ID-token audience. `sign_in_canceled` still maps to a clean cancellation, and
the native sign-out path is unchanged.

## 6. New-user flow

Register screen → role required (REQUESTER/RESPONDER) → Firebase Google popup →
Firebase ID token → `POST /api/auth/google` with the role → backend creates the
account with a public role only, `authProvider: GOOGLE`, `emailVerified: true`
and the one-time welcome claim → response `isNewUser`/`created` → **ERAS welcome
state**, then the role-routed area. No OTP/verification email is involved for a
Google-verified address, and the password-OTP flow is untouched.

## 7. Existing-user flow

Same first steps, but the backend resolves a known Firebase UID (or links the
verified Google email to the existing active ERAS account) and returns the
normal login payload with `isNewUser:false`. The client routes straight to the
existing role destination (responder readiness first for responders), never
shows the welcome state, and never triggers another welcome email. The role
always comes from PostgreSQL; a client can never grant itself ADMIN.

## 8. Welcome-email behaviour

Unchanged and unaffected by this fix. The welcome email is claimed and attempted
exactly once per *new* account (Resend first, configured SMTP fallback); the
response reports the actual `welcomeEmailSent` / accepted / delivered state, and
the frontend only shows the welcome screen for `isNewUser`/`created`. Existing
Google users (including linked accounts) produce no new welcome email. No OTP
email is sent to a Google-verified account.

## 9. Metadata changed

- `web/manifest.json`: `"name": "ERAS Console"`, `"short_name": "ERAS Console"`
  (install prompt name), updated description; icons, theme/background colours,
  `start_url`, `display` and related-app settings unchanged.
- `web/index.html`: `<title>ERAS — Emergency Resource Allocation System</title>`
  (browser title), `apple-mobile-web-app-title` = `ERAS Console` (iOS installed
  name), added meta description and `theme-color`; the app's `MaterialApp.title`
  matches the browser title.
- **Not changed**, as required: the Dart package name `dispatch_console_flutter`
  (`pubspec.yaml`), Firebase project ID, backend service name, database names,
  route names, icons, theme colours, service-worker/PWA behaviour, and the
  Android label (already `ERAS`).

## 10. Test results

| Check | Result |
| --- | --- |
| `dart format` (CI, Flutter stable / Dart 3.13.5) | 85 files checked, **0 changes** |
| `flutter analyze` | **No issues found** |
| `flutter test` | **404 tests passed, 0 failed** — includes the new `google_web_signin_test.dart` (web strategy, dismissed popup, blocked popup → redirect, redirect resume, registration persistence/consumption, malformed stored state, safe error mapping, native regression, sign-out) and `pwa_metadata_test.dart` (install name/title/metadata/icons) |
| `flutter build web --release` (compile check, CI) | **Succeeded**; `build/web/index.html` produced, with `--dart-define=ERAS_API_BASE_URL=https://eras-api-sdjo.onrender.com/api` |
| Backend CI (`npm` + Prisma migrate/schema + audit + Jest) | **Passed** |
| Manual acceptance A–H | **Not executed live** — no browser/Google network here. A/B (password register+OTP and password login) remain covered by the existing widget suite; C/D by `google_signin_flow_test.dart` plus the welcome-email backend tests; E/F by the new web tests; G by the resume test; H by the PWA metadata test. Live A–H must be run after deployment. |

## 11. Build and deploy commands

The deployed Web build must include the Firebase Web configuration — the bare
`flutter build web --release --dart-define=ERAS_API_BASE_URL=…` command alone
leaves `ErasFirebaseConfig.isConfigured == false` on Web, which is why Google
sign-in would report "not configured" instead of opening the popup.

```bash
cd frontend/emergency_app
export ERAS_API_BASE_URL=https://eras-api-sdjo.onrender.com/api
export ERAS_GOOGLE_MAPS_API_KEY=<referrer-restricted maps key>
export ERAS_FIREBASE_API_KEY=<firebase web api key>
export ERAS_FIREBASE_APP_ID=<firebase web app id>
export ERAS_FIREBASE_MESSAGING_SENDER_ID=<project number>
export ERAS_FIREBASE_PROJECT_ID=<firebase project id>
export ERAS_FIREBASE_AUTH_DOMAIN=<project>.firebaseapp.com
export ERAS_GOOGLE_WEB_CLIENT_ID=<web oauth client id>   # kept for compatibility
./tool/build_production_web.sh        # validates inputs, builds build/web, never prints keys
ERAS_FIREBASE_PROJECT_ID=<firebase project id> ./tool/deploy_firebase_web.sh
# or: firebase deploy --only hosting --project eras-production-f3ce6 --non-interactive
```

Then hard-refresh `https://eras-production-f3ce6.web.app` (or use a private
window for the first run) and execute acceptance A–H.

## 12. Manual Firebase Console configuration required

1. **Authentication → Sign-in method → Google: Enabled**, with a support email.
2. **Authentication → Settings → Authorized domains** must contain
   `eras-production-f3ce6.web.app` (Firebase Hosting domains of the same project
   are normally added automatically — verify) plus `localhost` for debug.
3. **Authentication → Settings → Authorized redirect URIs** must include
   `https://<project>.firebaseapp.com/__/auth/handler` (the default) for the
   redirect fallback.
4. The Firebase **Web app's** config values used for the build must come from
   *Project settings → Your apps → Web app* (the same project as the deployed
   site).
5. The Google provider client in Google Cloud must keep
   `https://eras-production-f3ce6.web.app` (and `http://localhost:<port>`) as
   authorized JavaScript origins; keep the existing web client id in
   `GOOGLE_CLIENT_ID(S)` on Render if Android/external ID tokens are still
   accepted.
6. Confirm Render's `FIREBASE_PROJECT_ID` (and/or `GOOGLE_CLIENT_IDS`) is set,
   otherwise `POST /api/auth/google` correctly answers 503 and the UI shows
   "Google sign-in is not configured on this server".

No new Firebase project is created and no credential is committed or shared.
