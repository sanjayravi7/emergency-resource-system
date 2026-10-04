// Copy this file to web/google_maps_config.js for local development only.
// Production builds source this value from ERAS_GOOGLE_MAPS_API_KEY via
// tool/build_production_web.sh. Do not commit the generated file or any key.
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
//
// Reverse geocoding uses Photon through the authenticated ERAS backend; no
// Google Geocoding API key or browser API restriction is required.
//
//   Application restrictions -> HTTP referrers (web sites):
//     http://localhost:8080/*
//     http://127.0.0.1:8080/*
//     http://localhost:8081/*
//     http://127.0.0.1:8081/*
//     https://eras.website/*
//     https://eras-production-f3ce6.web.app/*
//     (add exact local/Arena preview origins only where needed)
//
// Driving directions are NOT computed by ERAS: the map draws a direct
// connection line and "Get directions" opens a key-less Google Maps URL
// (https://www.google.com/maps/dir/?api=1). No Routes API key exists anywhere.
window.ERAS_GOOGLE_MAPS_API_KEY = 'YOUR_REFERRER_RESTRICTED_MAPS_JS_API_KEY';
