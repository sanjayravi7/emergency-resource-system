# Google Maps setup for ERAS

ERAS uses the official `google_maps_flutter` package. On Flutter Web, that package uses the Google Maps JavaScript API loaded from `web/index.html`.

ERAS does **not** compute driving directions itself. The operational map draws a simple direct connection line between the responder and the emergency (local map geometry), and real driving directions are handed to Google Maps through a **Google Maps URL** — see §7. No Routes API and no server-side routing key are involved.

## 0. One key, and one key only

ERAS needs a **single browser Google API key**.

| | **BROWSER key** |
| --- | --- |
| Stored in | `frontend/emergency_app/web/google_maps_config.js` (git-ignored) |
| Visible to users | **Yes** — it is downloaded by every browser |
| APIs (enabled *and* in the key's API restrictions) | **Maps JavaScript API**, **Places API (New)** |
| Application restrictions | HTTP referrers (web sites) |
| Used by | `web/index.html`, `web/eras_location_bridge.js`, `google_maps_flutter` |

Notes:

- The browser key **must** be public: the Maps JavaScript API is loaded by the browser, so the key is in the page. The only protection Google offers for it is the HTTP-referrer allow-list, which is why its API restrictions must stay limited to the browser APIs above.
- **No server-side Google key is required.** Google Maps URLs (`https://www.google.com/maps/dir/?api=1&…`) are key-less and free, and reverse geocoding uses Photon, not Google.

## 1. Google Cloud project

1. Open the Google Cloud Console.
2. Create or select the project used for ERAS development/deployment.
3. Make sure billing is enabled for the project. Google Maps Platform requests require billing even when usage remains within free monthly credits.

## 2. Enable the required APIs

**APIs & Services → Library**, enable the Google APIs listed below:

| API | Key | Used by |
| --- | --- | --- |
| **Maps JavaScript API** | browser | map rendering (`GoogleMap`, `operational_google_map.dart`) and the location bridge |
| Photon reverse geocoding | **server** | GPS/map-tap coordinates → human-readable place via `GET /api/location/reverse` |
| **Places API (New)** | browser | requester place autocomplete (`google.maps.places.AutocompleteSuggestion`), `Place.fetchFields` for the selected place's exact coordinates, and the NEARBY PLACES selector (`Place.searchNearby` — Nearby Search (New)) |

Enabling an API is only half of the configuration — the key's own **API restrictions** list must contain it as well. A key that is enabled project-wide but restricted to "Maps JavaScript API" produces exactly the two failures below.

### 2a. Symptom → cause table

| Browser symptom | Cause | Fix |
| --- | --- | --- |
| `No address found` from `GET /api/location/reverse` | Photon returned no feature for the selected coordinates. Coordinates are retained and the Place field remains editable. | Enter a place manually or choose a Google Places result. |
| `Requests to this API places.googleapis.com method google.maps.places.v1.Places.AutocompletePlaces are blocked.` | The new Places surface (`places.googleapis.com`) is not covered by the key. **Places API (New)** is a *different* entry from the legacy *Places API* — selecting only the legacy one blocks every `AutocompleteSuggestion` / `Place.fetchFields` / `Place.searchNearby` call. | Enable **Places API (New)** and add exactly that entry to the key's API restrictions. |
| `RefererNotAllowedMapError`, `InvalidKeyMapError`, `ApiNotActivatedMapError` (reported by `gm_authFailure` in the console) | The key itself is rejected for this origin. | Add `<origin>/*` to the key's HTTP referrers. |
| **Get directions** does nothing | The platform blocked the pop-up/deep link, or no handler is installed. | Allow pop-ups for the ERAS origin. The URL is key-less, so this is never an API-key problem. |

> Note: reverse geocoding is not a Google browser feature in ERAS. The authenticated backend endpoint calls Photon, so no Google Geocoding API billing, key, or browser restriction is needed for this feature.

## 3. Create and restrict the keys

Create the keys under **APIs & Services → Credentials**. Do not commit unrestricted keys or production secrets.

### 3a. Browser key (Maps JavaScript API + Places API (New))

- **Application restrictions:** HTTP referrers (web sites)
- **API restrictions → Restrict key:** `Maps JavaScript API`, `Places API (New)`
- **Development referrers** — the local Flutter Web origins ERAS is served from:
  - `http://localhost:8080/*`
  - `http://127.0.0.1:8080/*`
  - `http://localhost:8081/*`
  - `http://127.0.0.1:8081/*`
  - (optional wildcards during development: `http://localhost:*/*`, `http://127.0.0.1:*/*`)
  - Arena preview hosts, for example `https://*-*.e2b.app/*`
- **Production referrers:** add only the exact deployed ERAS origin(s), for example `https://eras.example.org/*`

Reuse the project's existing browser key — do not create a second one. Adding the two missing APIs to the existing key is the whole fix.

### 3b. Server key — not needed

ERAS requires **no server-side Google API key**. Driving directions are delegated to Google Maps URLs (§7), which need no key, and reverse geocoding uses Photon.

### 3c. Verify the browser key in the browser (no guessing)

`web/eras_location_diagnostics.html` is served next to the app. Open it on the **same origin and port** the app runs on:

```
http://localhost:8080/eras_location_diagnostics.html
http://localhost:8081/eras_location_diagnostics.html
```

It prints, live and unmodified:

- the exact `window.location.origin` Google sees, and the referrer entry to allow-list (`<origin>/*`),
- the masked key actually used at runtime (last 4 characters + length) and the loader URL,
- whether `google.maps`, the `places` library and the Places API (New) classes loaded,
- the verbatim result of three probes: `Geocoder.geocode`, `AutocompleteSuggestion.fetchAutocompleteSuggestions`, `Place.searchNearby`,
- the concrete Google Cloud fix for whichever probe failed.

The same report is available in the app console:

```js
JSON.parse(await erasLocationBridge.diagnostics(10.00846, 76.45163))
```

`web/index.html` also logs the masked key + origin at startup and installs `window.gm_authFailure`, so a rejected key is reported explicitly instead of failing silently.

## 4. Local Flutter Web configuration

Copy the template and add your restricted development key:

```bash
cd frontend/emergency_app
cp web/google_maps_config.template.js web/google_maps_config.js
```

Edit `web/google_maps_config.js`:

```js
window.ERAS_GOOGLE_MAPS_API_KEY = 'YOUR_REFERRER_RESTRICTED_MAPS_JS_API_KEY';
```

`web/google_maps_config.js` is ignored by Git. `web/index.html` loads it at runtime, then loads the Maps JavaScript API with the direct script loader before starting Flutter. This is intentional: `google_maps_flutter_web` reads globals such as `google.maps.MapTypeId.ROADMAP`, while the newer `importLibrary` bootstrap keeps those globals lazy until application code imports the `maps` library.

## 5. Running locally

```bash
cd frontend/emergency_app
flutter pub get
flutter run -d chrome
```

If the key is missing, ERAS logs a browser-console warning and the map cannot load Google tiles. Request creation and text-only locations still work; ERAS never substitutes fake coordinates.

## 6. Requester location workflow (client side)

`web/index.html` loads the Maps JavaScript API with `&libraries=places`, then `web/eras_location_bridge.js`, then Flutter.

- `lib/services/location_service.dart` — platform-agnostic contract (`reverseGeocode`, `autocomplete`, `resolvePrediction`, `searchNearbyPlaces`) plus the `GeoPoint` / `ResolvedPlace` / `PlacePrediction` / `NearbyPlace` models and the `NearbyPlaceCategory` → Google place-type mapping.
- `lib/services/location_service_web.dart` — Flutter Web implementation; reverse geocoding calls the authenticated ERAS backend, while Google Places calls remain in `window.erasLocationBridge`.
- `lib/services/location_service_stub.dart` — non-web target; reports `isAvailable == false` and never fabricates results.
- `lib/widgets/requester_location_picker.dart` — search field + "Use my current location" + place field + coordinate readout + NEARBY PLACES selector + tap-to-pin preview map.
- `web/eras_location_bridge.js` — the JS bridge: AutocompleteSuggestion, `Place.fetchFields` and `Place.searchNearby` (Nearby Search (New)).

Reverse geocoding runs **only** on explicit requester actions (current location, map tap) through authenticated `GET /api/location/reverse`. The backend calls Photon with timeout handling and a small coordinate cache. Socket.IO responder location updates are never reverse geocoded. Photon is a public service: do not poll it for autocomplete and do not call it for telemetry updates.

Nearby bias: autocomplete requests include `locationBias` (a 30 km circle around the requester's current coordinates) whenever coordinates are already known. This is a *bias*, not a restriction, and belongs to the manual-search feature only — it is intentionally not the Nearby Search radius.

### 6a. NEARBY PLACES selector (Nearby Search (New))

Once the requester has coordinates (GPS, searched place or map tap), the form shows a **NEARBY PLACES** section with a **Refresh** button and category chips: Hospital, Police, Fire Station, School, College, Railway, Bus Station, Landmark, Church, Temple, Mosque.

Each request is a real [Nearby Search (New)](https://developers.google.com/maps/documentation/places/web-service/nearby-search) call through the JS bridge:

| Parameter | Value | Why |
| --- | --- | --- |
| `locationRestriction` | circle centered on the requester's latitude/longitude, radius **5000 m** | 5 km is a neighbourhood-scale radius: the list names the requester's immediate surroundings. Results are distance-ranked, so a wider circle only adds farther places, never better ones. (30 km is the autocomplete *bias*, a separate feature.) |
| `includedTypes` | the category's Google place types (see table below) | Table A types only — Table B values cannot be used as Nearby Search filters |
| `rankPreference` | `DISTANCE` | the nearest real places come first |
| `maxResultCount` | 10 | keeps the visible list short and the request cheap (API max is 20) |
| `fields` (field mask) | `id`, `displayName`, `formattedAddress`, `location` | only the fields the UI renders |

Category → Google place types (Table A):

| Chip | Google `includedTypes` |
| --- | --- |
| Hospital | `hospital` |
| Police | `police` |
| Fire Station | `fire_station` |
| School | `school`, `primary_school`, `secondary_school` |
| College | `university` (Google has no `college` type) |
| Railway | `train_station`, `light_rail_station`, `subway_station` |
| Bus Station | `bus_station`, `bus_stop` |
| Landmark | `cultural_landmark`, `historical_landmark`, `monument`, `historical_place`, `tourist_attraction`, `plaza` |
| Church | `church` |
| Temple | `hindu_temple`, `buddhist_temple`, `shinto_shrine` |
| Mosque | `mosque` |

Notes:

- There is no **Junction** chip: `intersection` is a Table B type, which Nearby Search (New) cannot filter by. Junctions are reachable through the Landmark category and through manual search (autocomplete).
- The straight-line distance shown per result ("1.2 km") is computed locally from the requester's coordinates and the place's real coordinates (haversine); Nearby Search does not return a distance field.

**When Nearby Search is called** (kept restrictive to avoid excessive API requests):

1. the requester's current location is obtained (only when a category is already selected — picking the first category performs the first call),
2. the requester selects/re-selects a category chip or taps **Refresh**,
3. the requester changes location (map tap, searched place, or a selected nearby place).

It is **never** called from responder Socket.IO location updates (`LiveLocationStore`) or from typing in the search field.

**Selecting a nearby result** makes that real Google place the request location: its `displayName`/`formattedAddress` become the place label, its own coordinates become the canonical latitude/longitude, the preview marker/camera move there, and the request can be submitted. The search text is never used as a coordinate source.

**Graceful degradation:** when Places API (New) is disabled/not enabled for the project or key (the request rejects with "Places API (New) has not been used in project … or it is disabled" / `REQUEST_DENIED` / `ApiTargetBlockedMapError`), the section shows exactly:

> Nearby places unavailable. Enable Places API (New) in Google Cloud.

Nothing crashes and the current-location + reverse-geocoding workflow uses the authenticated backend Photon endpoint. **Refresh** retries the nearby Google Places request.

`tool/eras_location_bridge_test.mjs` (plain Node, no Flutter needed) verifies the bridge's request shape: field mask, 5 km circle around the requester, `includedTypes`, `rankPreference = DISTANCE`, result mapping, the disabled-API error path, the verbatim geocoder/Places authorization errors plus their fix hints, and the `diagnostics()` report. Run it with `node tool/eras_location_bridge_test.mjs`.

## 7. Navigation: direct connection line + Google Maps URL

ERAS never calls the Google Routes API, the Maps JavaScript `DirectionsService`, or any other routing service.

### 7a. Direct connection line (inside the ERAS map)

- A `Polyline` (`kDirectConnectionPolylineId`) is drawn directly between the responder's latest coordinate and the emergency coordinate.
- It is **pure local map geometry**: no HTTP request, no API key, no throttling. It is *not* a road route and is never labelled as one.
- It is shown only while the request is active, the emergency has coordinates, a responder accepted the request, and that responder has a live or last-known position. It disappears when the request is completed/cancelled, the assignment is removed, or a coordinate disappears. Historical request data is untouched.
- It updates on every responder GPS update, because it is recomputed from the current board state on each build.

### 7b. Real driving directions (outside ERAS)

**Get directions** opens the Google Maps universal Directions URL:

```
https://www.google.com/maps/dir/?api=1
  &origin=<responderLat>,<responderLng>
  &destination=<emergencyLat>,<emergencyLng>
  &travelmode=driving
  &dir_action=navigate
```

- Built by `lib/services/direct_connection_service.dart` (`buildGoogleMapsDirectionsUri`), with all parameters URL-encoded.
- Opened through the `ExternalUrlLauncher` abstraction (`lib/services/url_launcher_adapter.dart`, backed by the `url_launcher` package), so tests never launch navigation.
- Opens the **Google Maps app on Android and iOS** when installed, and falls back to the Google Maps website on desktop/web.
- **Requires no Google API key** and no billing configuration.
- `dir_action=navigate` is included when the responder position is a live GPS fix; a stale last-known position omits it.

### 7c. Navigation card and map controls

- Card: `RESPONDER → EMERGENCY`, `Responder location: LIVE|LAST KNOWN`, `Emergency location: SET`, an optional `Direct distance: X.X km` (explicitly straight-line — **not** a road or driving distance) and the **Get directions** button. ERAS computes **no ETA**.
- Map controls: **Center on emergency**, **Fit pins** (camera fits the requester + responder coordinates; no route calculation), **Get directions**. The camera is never force-followed; pan/zoom stays with the user.

## 8. Data flow summary

- Requester GPS available: coordinates are stored in the form immediately, then reverse geocoded to fill the `location` text. ERAS stores `EmergencyRequest.latitude`, `EmergencyRequest.longitude` and that text.
- Requester selects a searched place: the place's own coordinates from Google become `latitude`/`longitude`; the typed search text is never stored.
- Requester selects a nearby place (hospital, police station, …): that place's own name/address and coordinates from Nearby Search (New) become the label and `latitude`/`longitude`; the request appears at that exact point on the Dispatch Board.
- Requester GPS unavailable/denied: ERAS stores only the location text and shows that a precise map pin is unavailable.
- Responder live location: Socket.IO `responder.location.update` updates `LiveLocationStore`, and the Google Map marker moves immediately without a REST refresh.
- Navigation: the map draws a direct connection line between the responder's latest coordinate and the emergency coordinate (local geometry only); actual driving directions come from the key-less Google Maps URL opened by **Get directions**.
- Terminal requests: completed/cancelled requests are removed from active map tracking and their connection line is removed.
