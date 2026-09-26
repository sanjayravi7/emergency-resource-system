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
| **Places API (New)** | requester place autocomplete (`google.maps.places.AutocompleteSuggestion`) and `Place.fetchFields` for the selected place's exact coordinates |

> If autocomplete returns `REQUEST_DENIED` / `ApiTargetBlockedMapError`, the **Places API (New)** is not enabled, or the key's *API restrictions* list does not include it. Enabling *Places API (Legacy)* alone is not sufficient for the new `AutocompleteSuggestion` flow (the bridge does fall back to the legacy `AutocompleteService` when only the old API is available).

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

- `lib/services/location_service.dart` — platform-agnostic contract (`reverseGeocode`, `autocomplete`, `resolvePrediction`) plus the `GeoPoint` / `ResolvedPlace` / `PlacePrediction` models.
- `lib/services/location_service_web.dart` — Flutter Web implementation, calls `window.erasLocationBridge` through `dart:js_interop`.
- `lib/services/location_service_stub.dart` — non-web target; reports `isAvailable == false` and never fabricates results.
- `lib/widgets/requester_location_picker.dart` — search field + "Use my current location" + place field + coordinate readout + tap-to-pin preview map.

Reverse geocoding runs **only** on explicit requester actions (current location, map tap). Socket.IO responder location updates are never reverse geocoded.

Nearby bias: autocomplete requests include `locationBias` (a 30 km circle around the requester's current coordinates) whenever coordinates are already known.

## 7. Data flow summary

- Requester GPS available: coordinates are stored in the form immediately, then reverse geocoded to fill the `location` text. ERAS stores `EmergencyRequest.latitude`, `EmergencyRequest.longitude` and that text.
- Requester selects a searched place: the place's own coordinates from Google become `latitude`/`longitude`; the typed search text is never stored.
- Requester GPS unavailable/denied: ERAS stores only the location text and shows that a precise map pin is unavailable.
- Responder live location: Socket.IO `responder.location.update` updates `LiveLocationStore`, and the Google Map marker moves immediately without a REST refresh.
- Terminal requests: completed/cancelled requests are removed from active map tracking.
