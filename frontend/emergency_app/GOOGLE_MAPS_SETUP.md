# Google Maps setup for ERAS

ERAS uses the official `google_maps_flutter` package. On Flutter Web, that package uses the Google Maps JavaScript API loaded from `web/index.html`. Road routing (responder → emergency) is **not** a browser API: it runs server side in the ERAS backend.

## 0. Two keys, on purpose

ERAS uses **two separate Google API keys**. They can never be the same key, because they are protected in fundamentally different ways.

| | **BROWSER key** | **SERVER key** |
| --- | --- | --- |
| Stored in | `frontend/emergency_app/web/google_maps_config.js` (git-ignored) | `backend/.env` → `GOOGLE_ROUTES_API_KEY` (git-ignored) |
| Visible to users | **Yes** — it is downloaded by every browser | **No** — it never leaves the server process |
| APIs (enabled *and* in the key's API restrictions) | **Maps JavaScript API**, **Places API (New)** | **Routes API** |
| Application restrictions | HTTP referrers (web sites) | IP addresses (server egress IPs); unrestricted is acceptable only for local development |
| Used by | `web/index.html`, `web/eras_location_bridge.js`, `google_maps_flutter` | `backend/src/services/routesService.js` only |

Why the split:

- The browser key **must** be public: the Maps JavaScript API is loaded by the browser, so the key is in the page. The only protection Google offers for it is the HTTP-referrer allow-list, which is why its API restrictions must stay limited to the three browser APIs.
- The Routes API is a plain web service. A referrer header is trivially forged, so a browser-exposed Routes key could be used by anyone. The Routes key therefore lives only in the backend environment and is reachable exclusively through the authenticated endpoint `POST /api/routes/compute`. It must never appear in Dart code, `web/google_maps_config.js`, `index.html`, or any frontend JavaScript.

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
| **Routes API** | **server** | real road route + distance + traffic-aware ETA between the responder's live position and the emergency (`POST /api/routes/compute`) |

Enabling an API is only half of the configuration — the key's own **API restrictions** list must contain it as well. A key that is enabled project-wide but restricted to "Maps JavaScript API" produces exactly the two failures below.

### 2a. Symptom → cause table

| Browser symptom | Cause | Fix |
| --- | --- | --- |
| `No address found` from `GET /api/location/reverse` | Photon returned no feature for the selected coordinates. Coordinates are retained and the Place field remains editable. | Enter a place manually or choose a Google Places result. |
| `Requests to this API places.googleapis.com method google.maps.places.v1.Places.AutocompletePlaces are blocked.` | The new Places surface (`places.googleapis.com`) is not covered by the key. **Places API (New)** is a *different* entry from the legacy *Places API* — selecting only the legacy one blocks every `AutocompleteSuggestion` / `Place.fetchFields` / `Place.searchNearby` call. | Enable **Places API (New)** and add exactly that entry to the key's API restrictions. |
| `RefererNotAllowedMapError`, `InvalidKeyMapError`, `ApiNotActivatedMapError` (reported by `gm_authFailure` in the console) | The key itself is rejected for this origin. | Add `<origin>/*` to the key's HTTP referrers. |
| `Google Routes API error (HTTP 403)` from `POST /api/routes/compute` | The **Routes API** is not enabled, or the *server* key is restricted to other APIs / other IPs. | Enable Routes API and fix the server key restrictions. This never involves the browser key. |

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

### 3b. Server key (Routes API)

- **Application restrictions:** IP addresses (the backend's egress IP) — or None for local development
- **API restrictions → Restrict key:** `Routes API` only
- Store it as `GOOGLE_ROUTES_API_KEY` in `backend/.env` (see `backend/.env.example`). Never in the frontend.

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

## 7. Road route: responder → emergency (server side)

The route is computed by the **Routes API Compute Routes** method, through the backend. The deprecated Maps JavaScript `DirectionsService` is not used anywhere.

### 7a. Request the backend sends

```
POST https://routes.googleapis.com/directions/v2:computeRoutes
X-Goog-Api-Key:   $GOOGLE_ROUTES_API_KEY        (backend environment only)
X-Goog-FieldMask: routes.duration,routes.distanceMeters,routes.polyline.encodedPolyline
```

```jsonc
{
  "origin":      { "location": { "latLng": { "latitude": <responder>, "longitude": <responder> } } },
  "destination": { "location": { "latLng": { "latitude": <emergency>, "longitude": <emergency> } } },
  "travelMode": "DRIVE",
  "routingPreference": "TRAFFIC_AWARE",
  "computeAlternativeRoutes": false,
  "units": "METRIC",
  "languageCode": "en-US"
}
```

Only the three field-mask fields are requested, so Google returns (and bills) nothing else.

### 7b. ERAS endpoint

```
POST /api/routes/compute        (Authorization: Bearer <JWT> required)

{ "origin": { "latitude": 10.00846, "longitude": 76.45163 },
  "destination": { "latitude": 10.05276, "longitude": 76.35211 } }
```

Validation rejects a missing origin, a missing destination, a non-numeric coordinate, a half coordinate pair, and any latitude outside ±90 / longitude outside ±180 — all with `400` and **without** calling Google.

Response (`200`) contains only:

```json
{ "success": true,
  "data": { "distanceMeters": 7412, "durationSeconds": 1080, "duration": "1080s",
            "encodedPolyline": "…", "distanceText": "7.4 km", "durationText": "18 min" } }
```

The API key is never part of any response, log line or error message: `routesService.redactApiKey()` strips key material (including `key=…` parameters and `AIza…` literals) from every upstream error before it is returned or logged.

Failure mapping: `401` unauthenticated · `400` invalid coordinates · `404` Google found no drivable route · `502` upstream/network error · `503` `GOOGLE_ROUTES_API_KEY` not configured.

### 7c. Client behaviour (`lib/services/active_route_controller.dart`)

- A route exists **only** when the request is active, has coordinates, has an accepted responder, and that responder has a current or last-known position. Completed/cancelled requests drop the route and stop recalculating.
- Route updates are throttled: after the first route, a recalculation needs **≥ 15 s since the last request AND ≥ 100 m of responder movement** (the safer of the two rules; a changed emergency coordinate or a manual retry bypasses the movement rule, and a failed attempt may retry once per interval). A burst of `responder.location.update` events therefore produces at most one Routes API call.
- While a new route is computed the previous polyline stays on the map and the card shows "Updating route…". On failure the old route and the responder marker stay, and the error is shown non-blocking.
- The polyline is Google's decoded `encodedPolyline` — never a straight connector — and the ETA is Google's own traffic-aware duration, never distance ÷ speed.
- Map controls: **Center on emergency**, **Fit pins**, **Fit route** (frames both endpoints and the route geometry). The camera is never force-followed; pan/zoom stays with the user.

## 8. Data flow summary

- Requester GPS available: coordinates are stored in the form immediately, then reverse geocoded to fill the `location` text. ERAS stores `EmergencyRequest.latitude`, `EmergencyRequest.longitude` and that text.
- Requester selects a searched place: the place's own coordinates from Google become `latitude`/`longitude`; the typed search text is never stored.
- Requester selects a nearby place (hospital, police station, …): that place's own name/address and coordinates from Nearby Search (New) become the label and `latitude`/`longitude`; the request appears at that exact point on the Dispatch Board.
- Requester GPS unavailable/denied: ERAS stores only the location text and shows that a precise map pin is unavailable.
- Responder live location: Socket.IO `responder.location.update` updates `LiveLocationStore`, and the Google Map marker moves immediately without a REST refresh.
- Road route: the throttled `POST /api/routes/compute` call turns the responder's latest coordinate + the emergency coordinate into a real road polyline, distance and traffic-aware ETA. No key reaches the browser.
- Terminal requests: completed/cancelled requests are removed from active map tracking and their route is removed.
