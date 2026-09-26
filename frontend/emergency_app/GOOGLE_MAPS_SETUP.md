# Google Maps setup for ERAS Flutter Web

ERAS uses the official `google_maps_flutter` package. On Flutter Web, that package uses the Google Maps JavaScript API loaded from `web/index.html`.

## 1. Google Cloud project

1. Open the Google Cloud Console.
2. Create or select the project used for ERAS development/deployment.
3. Make sure billing is enabled for the project. Google Maps Platform requests require billing even when usage remains within free monthly credits.

## 2. Enable the required APIs

Enable all three of the following for the project:

| API | Used by |
| --- | --- |
| **Maps JavaScript API** | map rendering (`GoogleMap`, `operational_google_map.dart`) and the location bridge |
| **Geocoding API** | reverse geocoding (`google.maps.Geocoder`) — GPS/map-tap coordinates → human readable place |
| **Places API (New)** | requester place autocomplete (`google.maps.places.AutocompleteSuggestion`), `Place.fetchFields` for the selected place's exact coordinates, and the NEARBY PLACES selector (`Place.searchNearby` — Nearby Search (New)) |

> If autocomplete returns `REQUEST_DENIED` / `ApiTargetBlockedMapError`, or nearby places show *"Nearby places unavailable. Enable Places API (New) in Google Cloud."*, the **Places API (New)** is not enabled, or the key's *API restrictions* list does not include it. Enabling *Places API (Legacy)* alone is not sufficient for the new `AutocompleteSuggestion` / `Place.searchNearby` flows (the bridge does fall back to the legacy `AutocompleteService` for search when only the old API is available). The map and reverse geocoding use other APIs and keep working either way.

## 3. Create and restrict an API key

Create an API key under **APIs & Services → Credentials** and restrict it before use.

Recommended web restrictions:

- **Application restrictions:** HTTP referrers (web sites)
- **API restrictions:** Maps JavaScript API, Geocoding API, Places API (New)
- **Development referrers:**
  - `http://localhost:*/*`
  - `http://127.0.0.1:*/*`
  - Arena preview hosts, for example `https://*-*.e2b.app/*`
- **Production referrers:** add only the exact deployed ERAS origin(s), for example `https://eras.example.org/*`

Do not commit unrestricted keys or production secrets.

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
- `lib/services/location_service_web.dart` — Flutter Web implementation, calls `window.erasLocationBridge` through `dart:js_interop` (no raw JS in widgets).
- `lib/services/location_service_stub.dart` — non-web target; reports `isAvailable == false` and never fabricates results.
- `lib/widgets/requester_location_picker.dart` — search field + "Use my current location" + place field + coordinate readout + NEARBY PLACES selector + tap-to-pin preview map.
- `web/eras_location_bridge.js` — the JS bridge: Geocoder, AutocompleteSuggestion, `Place.fetchFields` and `Place.searchNearby` (Nearby Search (New)).

Reverse geocoding runs **only** on explicit requester actions (current location, map tap). Socket.IO responder location updates are never reverse geocoded.

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

Nothing crashes and the current-location + reverse-geocoding workflow (Geocoding API) keeps working. **Refresh** retries once the API has been enabled in Google Cloud.

`tool/eras_location_bridge_test.mjs` (plain Node, no Flutter needed) verifies the bridge's request shape: field mask, 5 km circle around the requester, `includedTypes`, `rankPreference = DISTANCE`, result mapping and the disabled-API error path. Run it with `node tool/eras_location_bridge_test.mjs`.

## 7. Data flow summary

- Requester GPS available: coordinates are stored in the form immediately, then reverse geocoded to fill the `location` text. ERAS stores `EmergencyRequest.latitude`, `EmergencyRequest.longitude` and that text.
- Requester selects a searched place: the place's own coordinates from Google become `latitude`/`longitude`; the typed search text is never stored.
- Requester selects a nearby place (hospital, police station, …): that place's own name/address and coordinates from Nearby Search (New) become the label and `latitude`/`longitude`; the request appears at that exact point on the Dispatch Board.
- Requester GPS unavailable/denied: ERAS stores only the location text and shows that a precise map pin is unavailable.
- Responder live location: Socket.IO `responder.location.update` updates `LiveLocationStore`, and the Google Map marker moves immediately without a REST refresh.
- Terminal requests: completed/cancelled requests are removed from active map tracking.
