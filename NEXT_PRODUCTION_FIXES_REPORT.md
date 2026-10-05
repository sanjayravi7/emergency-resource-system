# ERAS — next production fixes (2026-10-05)

Four changes: Android Google sign-in, ADMIN user management, email masking and
Google Map gestures. Every change is scoped to the reported problem; no
unrelated UI, backend, authentication, deployment or database change was made.
The GPS / current-location implementation, the release signing configuration,
the package ID, the Firebase project and the production API URL are untouched.

---

## 1. Google sign-in on Android

### Root cause

Two things, one of which is console configuration and one of which is code.

**(a) Code — the native failure never reached a branch that understood it.**
`google_sign_in` 6.2+ surfaces native failures as `GoogleSignInException`, a
plain `Exception`, while the ERAS handler only caught `PlatformException`. Every
native failure therefore fell into the generic `catch` and produced exactly the
reported message:

> Google sign-in could not be completed. Please try again. You can still sign
> in with your email and password.

That made a configuration error (`CommonStatusCodes.DEVELOPER_ERROR`, status
10 — reported by the plugin as `sign_in_failed` / `h2: 10`) indistinguishable
from a network hiccup, and it also meant a *dismissed* account picker could be
reported as a failure.

**(b) Configuration — the release signing certificate decides the outcome.**
Android Google sign-in is authorised by *package name + the SHA-1 of the
certificate that signed the APK*, never by a client id. The ID-token audience
comes from the `default_web_client_id` resource that the google-services Gradle
plugin generates from `android/app/google-services.json`. So a release APK
works only when the Android OAuth client in that file lists the release
certificate:

```
package      io.github.sanjayravi7.eras
release SHA-1   183A5CC4DD91C8AE1525486434FF0831CAA35C27
release SHA-256 78C99AC78B0FE9E9E5495B18E065937C46831A591758FCFF36A8A3B7DED8154D
project      eras-production-f3ce6
```

If the fingerprint is missing, Google refuses the request before an account
picker appears (status 10). This fails in a **release** build while a debug
build works, which is the classic signature.

### What changed (code)

`frontend/emergency_app/lib/services/google_auth_service.dart`

- New `GoogleNativeSignInFailure` + `describeGoogleSignInFailure()` +
  `nativeGoogleSignInMessage()` (pure, `@visibleForTesting`). They normalise
  **both** plugin shapes (`PlatformException` and `GoogleSignInException`,
  matched by runtime type so the file is not coupled to one plugin version),
  recover the Google status code from `details` or from the message (`h2: 10`),
  and keep the sanitized diagnostic contract (`sanitizeGoogleAuthDiagnosticMessage`
  already redacts tokens, client ids and keys).
- `statusCode == 10` now maps to an honest, actionable sentence instead of
  "please try again", and `adb logcat` shows
  `[eras-auth] google sign-in cancelled/failed code=… statusCode=…`.
- A cancelled `GoogleSignInException` returns `cancelled` again (no error, no
  session change) — previously it was shown as a failure.
- A missing ID token is now logged (`no-token` / `access-token-only`): on
  Android that means `google-services.json` has no `client_type` 3 (web) OAuth
  client, because `google_sign_in` only requests an ID token when a server
  client id exists. Firebase can still exchange an access token, so this is a
  diagnostic and not a failure.
- The native `GoogleSignIn` is now created once per service instead of on every
  property access, so `signOut()` talks to the client that completed
  `signIn()` and `initWithParams` is not re-run on each call.

`frontend/emergency_app/tool/verify_firebase_android_config.py`

- Accepts `--release-sha256` (echoed as a console reminder:
  `google-services.json` only carries SHA-1 in `certificate_hash`).
- An unregistered release SHA-1 now fails with the exact expected/registered
  fingerprints plus the console steps and the Play App Signing note.

`frontend/emergency_app/tool/build_release_apk.sh` passes `--release-sha256`
through, so a production build refuses to continue with an unregistered
release certificate.

Nothing else in the Google flow changed: Firebase Auth still owns the token,
`POST /api/auth/google` still verifies it, the ERAS JWT / role / `isActive`
rules are untouched, and email + password login is untouched.

### REQUIRED console action (cannot be fixed in code)

1. **Firebase console** → Project settings → Your apps → Android app
   `io.github.sanjayravi7.eras` → **Add fingerprint** → paste
   `183A5CC4DD91C8AE1525486434FF0831CAA35C27` → Save.
   (Register the SHA-256 in the same place; Google Cloud derives it.)
2. If the APK is distributed through **Google Play**, also add the
   **Play App Signing** certificate SHA-1 (Play Console → Setup → App
   integrity): Play re-signs the APK, so the runtime certificate is Google's.
3. **Download the new `google-services.json`** into
   `frontend/emergency_app/android/app/` (the fingerprint is compiled in) and
   rebuild the release APK.
4. Confirm the backend `FIREBASE_PROJECT_ID` on Render is exactly
   `eras-production-f3ce6` — a mismatch (`eras-production`) would make token
   verification fail with `Google sign-in could not be verified`.

Then verify with:

```bash
cd frontend/emergency_app
python3 tool/verify_firebase_android_config.py \
  --file android/app/google-services.json \
  --project-id eras-production-f3ce6 \
  --web-client-id "$ERAS_GOOGLE_WEB_CLIENT_ID" \
  --release-sha1  183A5CC4DD91C8AE1525486434FF0831CAA35C27 \
  --release-sha256 78C99AC78B0FE9E9E5495B18E065937C46831A591758FCFF36A8A3B7DED8154D \
  --generated-res build/app/generated/res/google-services \
  --require-generated-res
```

---

## 2. ADMIN user management (and the “ravi / ID 8” record)

No record was deleted. The API now gives an administrator a **safe** capability
set, and a read-only script answers “may this account be removed?”.

### New / changed endpoints (all ADMIN-only unless stated)

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/api/users` | user list **plus** a `history` block with the relationship counters and `deletable` |
| PATCH | `/api/users/:id` | correct another account's **name** and **phone** |
| PATCH | `/api/users/me` | **any authenticated user** corrects their **own** name / phone |
| DELETE | `/api/users/:id` | delete an account **only** when it has no history (`{ "confirm": true }`) |
| PATCH | `/api/users/:id/role` | unchanged, now also refuses to remove the last active ADMIN |
| PATCH | `/api/users/:id/deactivate` | unchanged, now also refuses to remove the last active ADMIN |

Guaranteed by `backend/src/services/userAdminService.js`:

- **Email, role, `isActive` and password are not writable** through the profile
  endpoints — they are rejected loudly (each has its own guarded endpoint),
  because rewriting an address would break login, OTP, password reset and
  Google/Firebase linking. Unknown fields are rejected, not ignored.
- **Deletion counts first**: emergencies requested, emergencies accepted,
  responder assignments, allocations, responder inventory and help-type rows.
  Any of them → **409 `USER_HAS_HISTORY`** naming the counts and telling the
  administrator to deactivate instead. The count is re-checked *inside* the
  transaction, and Prisma's restrictive foreign keys remain the last line of
  defence.
- **Never the last administrator**, and never your own account.
- Every change is written to the append-only audit trail
  (`ADMIN_UPDATED_USER_PROFILE`, `ADMIN_DELETED_USER`, …).

### Creating / promoting an administrator (no public endpoint)

`backend/scripts/provision-admin.js` (run from a trusted shell with
`DATABASE_URL`; never a route, never reachable by a client):

```bash
# promote an existing account
NODE_ENV=production ERAS_ADMIN_MODE=promote \
ERAS_ADMIN_EMAIL=someone@example.com \
ERAS_CONFIRM_ADMIN_PROVISION=PROMOTE_ONE_ADMIN \
npm run promote:admin

# create a brand new administrator (as before)
NODE_ENV=production ERAS_ADMIN_NAME="…" ERAS_ADMIN_EMAIL=… \
ERAS_ADMIN_PASSWORD=… ERAS_CONFIRM_ADMIN_PROVISION=PROVISION_ONE_ADMIN \
npm run provision:admin
```

`ERAS_ADMIN_DRY_RUN=1` prints the plan without writing. Nothing secret is
printed.

### The “ravi • ID 8 / indexceramic2018@gmail.com” record

Run the read-only inspector first — it never writes:

```bash
cd backend && npm run inspect:user -- --id 8
# or:  node scripts/inspect-user.js --email indexceramic2018@gmail.com
```

It prints the account, the counters (requests, assignments, allocations,
inventory, help types, auth codes, device tokens, audit rows) and a verdict:

- **history present** → *preserve*. Correct the label with
  `PATCH /api/users/8 { "name": "<correct name>" }`, or stop sign-in with
  `PATCH /api/users/8/deactivate` (the responder directory only lists active
  responders, so deactivation also removes it from the shared screen). The
  equivalent SQL is printed as a fallback.
- **no history** → `DELETE /api/users/8 { "confirm": true }` as an ADMIN.

---

## 3. Partial email masking

### Server (authoritative)

- New `backend/src/domain/emailMasking.js`: `maskEmail` keeps the first
  character of the local part, masks the rest (bounded at 16 `*`), preserves
  the domain, and returns `null` for null/empty/malformed input — it never
  throws and never returns a partially usable address.
  `athulkrishna4155@gmail.com → a***************@gmail.com`,
  `sanjayravit7@gmail.com → s***********@gmail.com`.
- `backend/src/domain/privacy.js` applies it at the serialization boundary:
  a request's **requester email is masked for every viewer who is neither that
  requester nor an ADMIN**. Responder contact details keep the existing,
  stricter rule (omitted entirely for non-admins); ADMIN keeps the authorized
  contact visibility of the existing model.
- `GET /api/requests/my` passes `viewerUserId`, so a requester is never shown a
  masked copy of their own address.

### Client (display layer, second layer of defence)

- New `frontend/emergency_app/lib/services/email_privacy.dart` mirrors the
  server rule (`maskEmail`, `displayEmailForOthers(..., isOwnAccount: …)`) and
  is used by the responder directory, the dispatch board (row + `Email` chip)
  and the request detail dialog. Only the signed-in user's own address stays
  readable; everything else renders masked even for an ADMIN, who needs a
  name and an id to identify a responder — not their personal address.

### Not affected

Login, registration, OTP/email verification and password reset keep using the
real address internally. Realtime (Socket.IO) payloads are unchanged: one
broadcast serves the requester room, the responder rooms and the admin room, so
it cannot be serialized per viewer, and it deliberately still carries the
requester's **phone** for emergency contact; the display layer masks what is
rendered. This is documented in `src/realtime/eventEmitters.js`.

---

## 4. Google Map gestures on Android

**Cause.** The map is a platform view inside the Dispatch Board's scrollable
page. A platform view only receives a pointer sequence that **no Flutter
recognizer claims**, and the surrounding `ListView` competes for every drag —
so the page won each drag and the map could neither be panned nor pinched,
while taps (claimed by no parent recognizer) still worked. That is exactly the
reported symptom: the map renders and markers are tappable, but drag and pinch
do nothing.

**Fix.** `frontend/emergency_app/lib/widgets/operational_google_map.dart` now
hands the map a gesture recognizer set:

```dart
final Set<Factory<OneSequenceGestureRecognizer>>
    operationalMapGestureRecognizers = <Factory<OneSequenceGestureRecognizer>>{
  Factory<OneSequenceGestureRecognizer>(() => EagerGestureRecognizer()),
};
```

`EagerGestureRecognizer` makes the map claim the sequences that land on it,
restoring one-finger pan, pinch zoom, double-tap zoom and marker taps. The same
set is applied to the requester location-picker map, which sits in the same
scrollable page.

**Preserved.** Markers, polylines, Socket.IO live responder locations, “Center”,
“Fit pins”, the navigation deck and the location-permission notice are
untouched; the overlay controls are siblings painted above the map in the same
`Stack`, so they keep their own taps, and a drag that starts outside the map
still scrolls the board. The parent scroll view is **not** disabled — the map
simply wins the gestures inside its own area.

---

## Files changed

**Backend**
- `src/domain/emailMasking.js` *(new)*
- `src/domain/privacy.js` (requester email masked per viewer)
- `src/services/requestService.js` (`forViewer(..., viewerUserId)`,
  `getRequestsByUser(..., { viewerUserId })`, comments)
- `src/controllers/requestController.js` (own requests keep the owner's email)
- `src/services/userAdminService.js` *(new)*
- `src/controllers/adminController.js` (user list with history, profile update,
  guarded delete, last-admin guards)
- `src/controllers/userController.js` (`updateOwnProfile`)
- `src/routes/userRoutes.js` (`PATCH /me`, `PATCH /:id`, `DELETE /:id`)
- `src/realtime/eventEmitters.js` (documented realtime privacy decision)
- `scripts/inspect-user.js` *(new)*, `scripts/provision-admin.js` (promote mode,
  dry run), `package.json` (`inspect:user`, `promote:admin`)
- tests: `tests/unit/emailMasking.test.js` *(new)*,
  `tests/unit/userAdminService.test.js` *(new)*, `tests/unit/privacy.test.js`

**Flutter**
- `lib/services/google_auth_service.dart` (native failure handling, diagnostics,
  single sign-in client)
- `lib/services/email_privacy.dart` *(new)*
- `lib/widgets/operational_google_map.dart` (gesture recognizers)
- `lib/widgets/requester_location_picker.dart` (same gesture fix)
- `lib/widgets/board_panel.dart`, `lib/widgets/request_detail_dialog.dart`,
  `lib/widgets/resource_panels.dart` (masked emails)
- tests: `test/email_privacy_test.dart` *(new)*,
  `test/google_signin_native_error_test.dart` *(new)*,
  `test/operational_google_map_test.dart`,
  `test/responder_contact_privacy_test.dart`

**Tooling / docs**
- `tool/verify_firebase_android_config.py`, `tool/build_release_apk.sh`
- `frontend/emergency_app/FIREBASE_GOOGLE_SIGNIN_SETUP.md`, this report

## Verification performed

- Backend: `node --check` on every changed file; `npx jest tests/unit`
  (**10 suites / 104 tests pass**, including the 30 new ones).
- Firebase verifier: happy path and “unregistered release SHA-1” path exercised
  against a synthetic fixture (exit 0 / exit 1 with the guidance text).
- `bash -n` on `build_release_apk.sh`; Dart brace/paren balance and 80-column
  checks on every changed Dart file.

## Not run in this workspace (runs in CI / on the developer machine)

- `flutter analyze`, `flutter test`, `dart format --set-exit-if-changed`,
  `flutter build apk --release`: no Flutter/Dart SDK and no network access to
  `storage.googleapis.com` in this sandbox.
- Database-backed Jest suites (`tests/**` outside `tests/unit`): Prisma could
  not download its query engine (`binaries.prisma.sh` unreachable), so those
  suites were not executed here; they run in the `Backend` workflow with a
  PostgreSQL service.
- Real-device Google sign-in with the release APK.

## Database migration required

**None.** No schema change: user management reuses the existing columns, and
email masking is applied at serialization time.
