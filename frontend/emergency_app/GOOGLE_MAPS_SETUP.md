# Google Maps setup for ERAS Flutter Web

ERAS uses the official `google_maps_flutter` package. On Flutter Web, that package uses the Google Maps JavaScript API loaded from `web/index.html`.

## 1. Google Cloud project

1. Open the Google Cloud Console.
2. Create or select the project used for ERAS development/deployment.
3. Make sure billing is enabled for the project. Google Maps Platform requests require billing even when usage remains within free monthly credits.

## 2. Enable the Web API

Enable **Maps JavaScript API** for the project.

The current ERAS map only displays markers and camera bounds. It does not require Places, Geocoding, Directions, or a third-party mapping API.

## 3. Create and restrict an API key

Create an API key under **APIs & Services → Credentials** and restrict it before use.

Recommended web restrictions:

- **Application restrictions:** HTTP referrers (web sites)
- **API restrictions:** Maps JavaScript API only
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

`web/google_maps_config.js` is ignored by Git. `web/index.html` loads it at runtime and then configures the official Maps JavaScript API bootstrap loader for `google_maps_flutter_web`.

## 5. Running locally

```bash
cd frontend/emergency_app
flutter pub get
flutter run -d chrome
```

If the key is missing, ERAS logs a browser-console warning and the map cannot load Google tiles. Request creation and text-only locations still work; ERAS never substitutes fake coordinates.

## 6. Data flow summary

- Requester GPS available: ERAS stores `EmergencyRequest.latitude`, `EmergencyRequest.longitude`, and the requester-confirmed `location` text.
- Requester GPS unavailable/denied: ERAS stores only the location text and shows that a precise map pin is unavailable.
- Responder live location: Socket.IO `responder.location.update` updates `LiveLocationStore`, and the Google Map marker moves immediately without a REST refresh.
- Terminal requests: completed/cancelled requests are removed from active map tracking.
