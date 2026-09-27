# ERAS — Manual Device Acceptance Checklist (Phase I, Part 14)

The automated (headless) suites in this repository do **not** exercise real
Android/iOS GPS permissions, real Google Maps platform rendering, or real
background location behaviour. Those require a physical device or a full
emulator with Google Play services and a valid, referrer-restricted Maps key.

The checks below are **manual acceptance criteria** and are explicitly **not
automated**. Run them on a real device before a production release.

## A. Android location / GPS

| # | Scenario | Expected result |
|---|----------|-----------------|
| A1 | GPS permission **granted** (precise) | Responder location publishes; requester map shows the responder marker moving; `responder.location.update` events flow. |
| A2 | GPS permission **denied** | App shows a clear "location permission required" state; no crash; responder can still see requests but cannot publish location. |
| A3 | **Approximate** location only (Android 12+) | App functions; coordinates are coarse; direct connection line still renders. |
| A4 | Location services **disabled** at OS level | App prompts to enable; graceful degraded state; no crash. |
| A5 | **Reconnect** after network drop | Socket reconnects; only authorized request/user/responder rooms are rejoined; live location resumes without duplicate markers. |
| A6 | **Background → foreground** transition | Stream pauses/resumes correctly; no stale position shown as "live"; the persisted latest point is used until a fresh fix arrives. |

## B. Google Maps rendering

| # | Scenario | Expected result |
|---|----------|-----------------|
| B1 | Map **loads** with the referrer-restricted browser key | Base map tiles render; no "For development purposes only" watermark on a correctly billed key. |
| B2 | **Markers render** | Emergency marker + responder marker appear at correct coordinates. |
| B3 | **Multiple responders render** | Each ACTIVE responder on a request renders a distinct marker; markers update independently. |
| B4 | **Direct connection lines render** | A straight line is drawn between each responder and the emergency (local geometry only — ERAS computes no driving route). |
| B5 | **Get Directions** | Opens the key-less Google Maps universal URL (`https://www.google.com/maps/dir/?api=1`) in the platform maps app/tab with correct origin/destination. |

## C. Auth / session (manual)

| # | Scenario | Expected result |
|---|----------|-----------------|
| C1 | Login persistence | Token is held in memory for the session; after a full app restart the user must log in again (by design — no token is written to device storage). |
| C2 | Logout | Token cleared; socket disconnected; no further authorized events received. |
| C3 | Account deactivated server-side while online | Within `SOCKET_SESSION_REVALIDATE_MS` the socket receives `socket.invalidated` and disconnects; REST calls return 401. |

## How to run a device build

```
# Web (preview / production origin must be added to the Maps key referrers)
cp frontend/emergency_app/web/google_maps_config.template.js \
   frontend/emergency_app/web/google_maps_config.js   # then set the key
flutter run -d chrome

# Android emulator/device pointing at a backend
flutter run --dart-define=ERAS_API_BASE_URL=http://10.0.2.2:5000/api
```

See `GOOGLE_MAPS_SETUP.md` / `web/google_maps_config.template.js` for the exact
Google Cloud API + referrer restriction requirements.
