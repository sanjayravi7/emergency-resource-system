// Copy this file to web/google_maps_config.js for local development.
// Do not commit google_maps_config.js or any unrestricted/production API key.
//
// This is the BROWSER key. It is loaded by web/index.html into the Maps
// JavaScript API loader, so it is necessarily visible in the browser and must
// be protected with HTTP-referrer restrictions.
//
// Google Cloud requirements for THIS key (see GOOGLE_MAPS_SETUP.md):
//
//   Enabled APIs + key "API restrictions" list (both are needed):
//     * Maps JavaScript API   - map rendering
//     * Places API (New)      - autocomplete, place details, Nearby Search
//     * Geocoding API         - reverse geocoding (google.maps.Geocoder)
//
//   Application restrictions -> HTTP referrers (web sites):
//     http://localhost:8080/*
//     http://127.0.0.1:8080/*
//     http://localhost:8081/*
//     http://127.0.0.1:8081/*
//     (add your Arena/preview or production origins as needed)
//
// The Routes API key is a SEPARATE, SERVER-SIDE key. It lives only in the
// backend environment (GOOGLE_ROUTES_API_KEY) and must never be placed here.
window.ERAS_GOOGLE_MAPS_API_KEY = 'YOUR_REFERRER_RESTRICTED_MAPS_JS_API_KEY';
