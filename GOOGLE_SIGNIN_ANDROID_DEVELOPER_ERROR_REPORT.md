# Android Google Sign-In `DEVELOPER_ERROR` (status 10) — root cause and fix

**Symptom (fresh release APK):**

```
google sign-in cancelled/failed: code=sign_in_failed; message=h2: 10
```

`10` is `CommonStatusCodes.DEVELOPER_ERROR`. `h2` is the R8-obfuscated name of
`com.google.android.gms.common.api.ApiException`, so `h2: 10` is literally
`ApiException.toString()`.

---

## 1. Root cause

**The Android `GoogleSignIn` constructor must omit both `clientId` and
`serverClientId` when `google-services.json` is present. It did not: it passed
`serverClientId: ErasFirebaseConfig.googleWebClientId`, a web OAuth client id
hand-copied into the APK through `--dart-define=ERAS_GOOGLE_WEB_CLIENT_ID`.**

That value *overrides* the OAuth configuration that `google-services.json`
supplies, so the release APK asked Google for an ID token (and a server auth
code) addressed to a client that is not the one the app is registered against.
Google rejects that request before the account flow can complete, with
`DEVELOPER_ERROR` (10).

### Mechanism, verified against the pinned plugin sources

`pubspec.lock` pins `google_sign_in 6.3.0`, `google_sign_in_android 6.2.1`,
`google_sign_in_web 0.12.4+4`, `google_sign_in_platform_interface 2.5.0`.

`google_sign_in_android 6.2.1`, `GoogleSignInPlugin.init`
(`android/src/main/java/io/flutter/plugins/googlesignin/GoogleSignInPlugin.java`),
resolves the ID-token audience in this order:

```java
// The clientId parameter is not supported on Android.
// Android apps are identified by their package name and the SHA-1 of their signing key.
String serverClientId = params.getServerClientId();
if (!isNullOrEmpty(params.getClientId()) && isNullOrEmpty(serverClientId)) {
  Log.w("google_sign_in", "clientId is not supported on Android and is "
      + "interpreted as serverClientId. ...");
  serverClientId = params.getClientId();
}
if (isNullOrEmpty(serverClientId)) {
  int webClientIdIdentifier = context.getResources()
      .getIdentifier("default_web_client_id", "string", context.getPackageName());
  if (webClientIdIdentifier != 0) {
    serverClientId = context.getString(webClientIdIdentifier);
  }
}
if (!isNullOrEmpty(serverClientId)) {
  optionsBuilder.requestIdToken(serverClientId);
  optionsBuilder.requestServerAuthCode(serverClientId, params.getForceCodeForRefreshToken());
}
```

Three facts follow directly from this code:

1. A Dart-supplied `serverClientId` **wins**. The `default_web_client_id`
   resource — the value the google-services Gradle plugin generates from the
   `client_type` 3 entry of `google-services.json`, i.e. the one that is
   guaranteed to agree with the registered Android OAuth client, package name
   and SHA-1 — is only consulted when Dart supplied nothing.
2. A Dart-supplied `clientId` on Android is *also* reinterpreted as
   `serverClientId` (with only a warning). A web client id passed as `clientId`
   would therefore land in exactly the same place.
3. Whatever wins is used for **both** `requestIdToken(...)` and
   `requestServerAuthCode(...)`, so a wrong value fails both halves of the
   OAuth request.

`google_sign_in 6.3.0` documents the same precedence:

> `clientId` — "This option is not supported on all platforms (e.g. Android).
> It is optional if file-based configuration is used. **The value specified
> here has precedence over a value from a configuration file.**"
>
> `serverClientId` — "By default, it is initialized from a configuration file
> if available. **The value specified here has precedence over a value from a
> configuration file.**"

And `_doInitialization()` forwards both fields verbatim:

```dart
await GoogleSignInPlatform.instance.initWithParams(SignInInitParameters(
  ... clientId: clientId, serverClientId: serverClientId, ...));
```

### How 10 becomes the exact log line

`GoogleSignInPlugin.onSignInResult` (same file):

```java
String errorCode = errorCodeForStatus(e.getStatusCode());
finishWithError(errorCode, e.toString());
```

`errorCodeForStatus(10)` hits the `default:` branch → `"sign_in_failed"`, and
`e.toString()` is `"h2: 10"`. `finishWithError` takes only code and message, so
`details` stays null — which is why the diagnostic line has no `detailsCode`.
That reproduces the reported line exactly, including the absence of a details
code, and confirms the failure came from the Google Sign-In SDK rather than
from Firebase Auth or the ERAS backend.

### Why the Google Cloud console looks correct

Nothing in Google Cloud is wrong. The Android OAuth client, the web OAuth
client, the registered release SHA-1 and the enabled Google provider are all
fine — the app was simply not *using* them. It was using a copy of the web
client id that travelled through `--dart-define`, so any drift from the
`google-services.json` that the Gradle plugin baked into the APK (a web client
not linked to this Android client, a value from another project, a stale copy,
trailing whitespace) turns into `DEVELOPER_ERROR`. Removing the override makes
drift structurally impossible: there is then exactly one source of truth.

### Secondary finding on the Web path

`google_sign_in_web 0.12.4+4` does the opposite:

```dart
final String? appClientId = params.clientId ?? autoDetectedClientId;
assert(appClientId != null, 'ClientID not set. ...');
assert(params.serverClientId == null, 'serverClientId is not supported on Web.');
```

The old code set `serverClientId` unconditionally on *every* platform, so a
debug web build tripped that assert. The new resolver keeps `clientId` for web
and forces `serverClientId` to null, which is what the web plugin requires.

---

## 2. What changed

`frontend/emergency_app/lib/services/google_auth_service.dart`

- New `GoogleSignInClientConfig` + `resolveGoogleSignInClientConfig(...)`
  (`@visibleForTesting`, pure, no globals inside — `isWeb` and `platform` are
  parameters so both paths are testable on the VM).
- Rules: **Web** → `clientId = ERAS_GOOGLE_WEB_CLIENT_ID` (trimmed),
  `serverClientId = null`. **Android / iOS / macOS / desktop** → both null, so
  `google-services.json` / `GoogleService-Info.plist` decide.
- `GoogleAuthService.buildSignInClient()` is the only place a `GoogleSignIn`
  is constructed, and `_googleSignIn` delegates to it, so tests exercise the
  production code path rather than a copy of it.
- New `debugGoogleWebClientId` test seam (`@visibleForTesting`, defaults to
  null so production behaviour is unchanged). `flutter test` always runs with
  an empty `ERAS_GOOGLE_WEB_CLIENT_ID`, so without this seam a test could
  never observe the release configuration in which the id *is* compiled in —
  i.e. it could not have caught this bug.
- New `maskGoogleClientId(...)` renders client ids as
  `[client-id:len=..,fp=..]`; `GoogleSignInClientConfig.toString()` uses it, so
  no complete client id can reach a log.

Unchanged on purpose: the `FirebaseAuth.signInWithCredential` →
`user.getIdToken()` → `POST /api/auth/google` hand-off, `sanitizeGoogleAuthDiagnosticMessage`
and the safe diagnostic logging, every user-facing error string
(`_messageForCode`, the `PlatformException` branch, `sign_in_canceled` still
returning `null`), and email/password authentication.

Nothing was weakened: the service still refuses to run when Firebase is not
configured, still requires a non-empty Firebase ID token, and still sends only
that token to the backend. `backend/src/services/firebaseTokenService.js`
accepts a Firebase ID token when `aud === FIREBASE_PROJECT_ID`, so dropping
`serverClientId` on Android cannot affect backend verification.

`frontend/emergency_app/test/google_signin_client_config_test.dart` (new) covers:

- Android/native configuration path (single platform and all of
  `TargetPlatform.values`),
- Web configuration path (including trimming and the unconfigured case),
- no accidental use of the web client id as an Android client id (all native
  platforms, plus the real `GoogleSignIn` instance built by the service under
  `flutter_test`, where `kIsWeb == false` and `defaultTargetPlatform ==
  TargetPlatform.android`),
- the existing flow (`signInAndGetIdToken()` still returns the injected
  Firebase ID token; `signOut()` still degrades safely).

`frontend/emergency_app/tool/verify_firebase_android_config.py`

- Now verifies the four required facts explicitly: Android app package,
  project number (new `--project-number`), presence of a `client_type` 3 web
  OAuth client, and a `client_type` 1 Android OAuth client bound to the
  package.
- Now also cross-checks the **generated** Android string resources
  (`build/app/generated/res/google-services/<variant>/values/values.xml`)
  against the JSON: `default_web_client_id`, `gcm_defaultSenderId`,
  `project_id`. `--require-generated-res` turns "not built yet" into a failure.
- All client ids, API keys and the project number are printed as
  `[len=..,fp=..]` fingerprints — no complete identifier is ever emitted.

`frontend/emergency_app/tool/build_release_apk.sh`: passes `--project-number`
when `ERAS_FIREBASE_PROJECT_NUMBER` is set, and documents that the
`--dart-define` is for the web build while Android reads
`google-services.json`.

Docs corrected: `FIREBASE_GOOGLE_SIGNIN_SETUP.md` and
`frontend/emergency_app/FIREBASE_GOOGLE_SIGNIN_SETUP.md` previously stated that
`ERAS_GOOGLE_WEB_CLIENT_ID` is Android's `serverClientId`. It is not, and that
statement is what made the override look correct.

---

## 3. Firebase Android configuration inspection

`android/app/google-services.json` is git-ignored (per-deployment) and is
**absent from this checkout**, so `build/app/generated/res/google-services/**`
does not exist here either. The inspection therefore could not be completed
against real values:

```
$ python3 tool/verify_firebase_android_config.py \
    --file android/app/google-services.json \
    --project-id eras-production --web-client-id placeholder
Firebase Android config check failed: android/app/google-services.json is
missing; download it for the configured Firebase Android app
```

To prove the checker itself works, it was run against a clearly synthetic
fixture (fake package-correct JSON plus a matching generated `values.xml`).
All four required assertions and the generated-resource cross-check passed, and
every identifier was masked:

```
Firebase project: eras-fixture-project
Firebase project number: [len=12,fp=a10d8047]
Android application ID: io.github.sanjayravi7.eras
OAuth Web client ID (client_type 3): [len=62,fp=5b3797de] present
Android OAuth client IDs (client_type 1): 1
  [len=55,fp=d0f2d3f7]
Android OAuth SHA-1 certificate hashes in JSON: 1
  11223344556677889900AABBCCDDEEFF00112233
Release signing SHA-1: registered
Generated Android resources (release): default_web_client_id=[len=62,fp=5b3797de]
matches, gcm_defaultSenderId=[len=12,fp=a10d8047] matches, ...
```

Eight negative fixtures each failed with exit 1 and a specific message: no
`client_type` 3 entry, wrong package name, wrong project number, no
`client_type` 1 entry, web client id absent from the JSON, generated
`default_web_client_id` drift, unregistered release SHA-1, and missing
generated resources with `--require-generated-res`.

**Run this on the machine that holds the real file and keystore:**

```bash
cd frontend/emergency_app
python3 tool/verify_firebase_android_config.py \
  --file android/app/google-services.json \
  --project-id  "$ERAS_FIREBASE_PROJECT_ID" \
  --project-number "$ERAS_FIREBASE_PROJECT_NUMBER" \
  --web-client-id "$ERAS_GOOGLE_WEB_CLIENT_ID" \
  --release-sha1 "$RELEASE_SHA1" \
  --generated-res build/app/generated/res/google-services \
  --require-generated-res
```

---

## 4. Commands that could not be run in this workspace

`flutter analyze`, `flutter test` and `flutter build apk --release` were **not**
executed. This sandbox has no Flutter/Dart toolchain and cannot obtain one:

- no `flutter` or `dart` binary anywhere on the filesystem;
- `pub.dev`, `storage.googleapis.com` and `dl.google.com` are network-blocked
  (curl returns 000), so neither the SDK, the engine artifacts, the pub
  packages nor an Android SDK can be downloaded;
- no JDK, and no permission to install one (`apt-get update` → permission
  denied).

Static checks that *were* run: line width against the 80-column page width used
by `dart format` (the only >80 line in the touched files is pre-existing and
untouched), brace/parenthesis balance with comments and string literals
stripped, and an unused-import audit of the new test. `dart.yml` was not
modified, so CI will run `dart format --output=none --set-exit-if-changed .`,
`flutter analyze` and `flutter test` on the change.
