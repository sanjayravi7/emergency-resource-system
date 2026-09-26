// Node-based checks for web/eras_location_bridge.js.
//
// Flutter widget tests cannot execute the JavaScript bridge, so this script
// loads the bridge into a sandboxed VM with a stubbed `google.maps.places` and
// verifies the Nearby Search (New) request the bridge actually builds:
//
//   * field mask is exactly id, displayName, formattedAddress, location
//   * locationRestriction circle: requester center + 5 km radius
//   * includedTypes are passed through (category -> Google types)
//   * rankPreference is DISTANCE
//   * maxResultCount clamped to 1..20
//   * results map to placeId/name/address/latitude/longitude
//   * rejected promises (Places API (New) disabled) come back as
//     { ok: false, error } instead of throwing
//
// Run with:  node tool/eras_location_bridge_test.mjs

import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

const here = dirname(fileURLToPath(import.meta.url));
const bridgePath = resolve(here, '../web/eras_location_bridge.js');
const bridgeSource = readFileSync(bridgePath, 'utf8');

function loadBridge(googleStub, options = {}) {
  const sandbox = {
    google: googleStub,
    document: { createElement: () => ({}), referrer: options.referrer || '' },
    location: {
      origin: options.origin || 'http://localhost:8080',
      href: `${options.origin || 'http://localhost:8080'}/`,
    },
    ERAS_MAPS_RUNTIME: options.runtime,
    console,
  };
  sandbox.window = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(bridgeSource, sandbox, { filename: bridgePath });
  return sandbox.window.erasLocationBridge;
}

let checks = 0;
let failures = 0;

function check(name, condition, detail) {
  checks += 1;
  if (condition) {
    console.log(`  ok   ${name}`);
  } else {
    failures += 1;
    console.log(`  FAIL ${name}${detail ? ` -> ${detail}` : ''}`);
  }
}

function nearbyGoogleStub(behavior) {
  return {
    maps: {
      places: {
        Place: {
          searchNearby: async (request) => behavior(request),
        },
        SearchNearbyRankPreference: {
          DISTANCE: 'DISTANCE',
          POPULARITY: 'POPULARITY',
        },
      },
    },
  };
}

// A Google Place as returned by the new Places library: displayName is a
// string-like object, location exposes lat()/lng().
function googlePlace(id, name, address, lat, lng) {
  return {
    id,
    displayName: { toString: () => name },
    formattedAddress: address,
    location: { lat: () => lat, lng: () => lng },
  };
}

// ---------------------------------------------------------------------------
console.log('searchNearby builds the documented Nearby Search (New) request');
{
  const requests = [];
  const bridge = loadBridge(
    nearbyGoogleStub((request) => {
      requests.push(request);
      return {
        places: [
          googlePlace('place-a', 'Hospital A', 'Main Road', 9.991, 76.662),
          googlePlace('place-b', 'Hospital B', 'Church Road', 9.995, 76.658),
        ],
      };
    }),
  );

  const raw = await bridge.searchNearby(
    9.9876,
    76.6543,
    ['hospital'],
    5000,
    10
  );
  const parsed = JSON.parse(raw);

  check('resolves ok:true', parsed.ok === true, raw);
  check('exactly one request', requests.length === 1);

  const request = requests[0];
  check(
    'field mask only id/displayName/formattedAddress/location',
    JSON.stringify(request.fields) ===
      JSON.stringify(['id', 'displayName', 'formattedAddress', 'location']),
    JSON.stringify(request.fields)
  );
  check(
    'includedTypes passthrough',
    JSON.stringify(request.includedTypes) === JSON.stringify(['hospital']),
    JSON.stringify(request.includedTypes)
  );
  check(
    'circle center is the requester coordinates',
    request.locationRestriction.center.lat === 9.9876 &&
      request.locationRestriction.center.lng === 76.6543,
    JSON.stringify(request.locationRestriction.center)
  );
  check(
    'radius is 5 km (not 30 km)',
    request.locationRestriction.radius === 5000,
    String(request.locationRestriction.radius)
  );
  check(
    'rankPreference is DISTANCE',
    request.rankPreference === 'DISTANCE',
    String(request.rankPreference)
  );
  check(
    'maxResultCount is 10',
    request.maxResultCount === 10,
    String(request.maxResultCount)
  );

  check(
    'results map name/address/coordinates',
    parsed.places.length === 2 &&
      parsed.places[0].placeId === 'place-a' &&
      parsed.places[0].name === 'Hospital A' &&
      parsed.places[0].address === 'Main Road' &&
      parsed.places[0].latitude === 9.991 &&
      parsed.places[0].longitude === 76.662,
    JSON.stringify(parsed.places[0])
  );
}

// ---------------------------------------------------------------------------
console.log('bounds and input validation');
{
  const requests = [];
  const bridge = loadBridge(
    nearbyGoogleStub((request) => {
      requests.push(request);
      return { places: [] };
    }),
  );

  await bridge.searchNearby(10, 76, ['police'], 60000, 99);
  check('radius clamped to 50000 m', requests[0].locationRestriction.radius === 50000);
  check('maxResultCount clamped to 20', requests[0].maxResultCount === 20);

  await bridge.searchNearby(10, 76, ['police'], 0, 0);
  check(
    'radius 0/invalid falls back to the 5 km default',
    requests[1].locationRestriction.radius === 5000
  );
  check(
    'maxResultCount 0/invalid falls back to 10',
    requests[1].maxResultCount === 10
  );

  const noTypes = JSON.parse(await bridge.searchNearby(10, 76, [], 5000, 10));
  check(
    'empty type list -> ok:false',
    noTypes.ok === false && /no place types/i.test(noTypes.error),
    JSON.stringify(noTypes)
  );
}

// ---------------------------------------------------------------------------
console.log('Places API (New) disabled -> graceful ok:false, no throw');
{
  const bridge = loadBridge(
    nearbyGoogleStub(() =>
      Promise.reject(
        new Error(
          'Places API (New) has not been used in project 3804150054 before or ' +
            'it is disabled. Enable it by visiting ' +
            'https://console.developers.google.com/apis/api/places.googleapis.com/overview?project=3804150054 then retry.'
        )
      )
    ),
  );

  const raw = await bridge.searchNearby(9.9876, 76.6543, ['hospital'], 5000, 10);
  const parsed = JSON.parse(raw);
  check(
    'disabled API rejects into ok:false',
    parsed.ok === false,
    raw
  );
  check(
    'error mentions disabled Places API (New)',
    /places api \(new\) has not been used/i.test(parsed.error) &&
      /disabled/i.test(parsed.error),
    parsed.error
  );
}

// ---------------------------------------------------------------------------
console.log('unusable results are skipped');
{
  const bridge = loadBridge(
    nearbyGoogleStub(async () => ({
      places: [
        googlePlace('place-a', 'Hospital A', 'Main Road', 9.991, 76.662),
        { id: 'no-location', displayName: { toString: () => 'Ghost' } },
        { id: 'no-name', location: { lat: () => 1, lng: () => 2 } },
      ],
    }))
  );

  const parsed = JSON.parse(
    await bridge.searchNearby(9.9876, 76.6543, ['hospital'], 5000, 10)
  );
  check(
    'only places with name + location survive',
    parsed.places.length === 1 && parsed.places[0].placeId === 'place-a',
    JSON.stringify(parsed.places)
  );
}

// ---------------------------------------------------------------------------
console.log('other bridge exports stay intact');
{
  const bridge = loadBridge(nearbyGoogleStub(async () => ({ places: [] })));
  check(
    'exports reverseGeocode/autocomplete/placeDetails/searchNearby',
    typeof bridge.isAvailable === 'function' &&
      typeof bridge.reverseGeocode === 'function' &&
      typeof bridge.autocomplete === 'function' &&
      typeof bridge.placeDetails === 'function' &&
      typeof bridge.searchNearby === 'function'
  );
  check('isAvailable true with google.maps present', bridge.isAvailable() === true);

  const empty = loadBridge({});
  check('isAvailable false without google.maps', empty.isAvailable() === false);
}

// ---------------------------------------------------------------------------
console.log('authorization failures surface the raw Google error + a fix hint');
{
  // Exactly what the browser reported for the Geocoder:
  //   GEOCODER_GEOCODE: REQUEST_DENIED: The webpage is not allowed to use the
  //   geocoder.
  const geocoderError = Object.assign(
    new Error('The webpage is not allowed to use the geocoder.'),
    { code: 'REQUEST_DENIED', endpoint: 'GEOCODER_GEOCODE' }
  );

  const bridge = loadBridge(
    {
      maps: {
        Geocoder: function () {
          return {
            geocode: async () => {
              throw geocoderError;
            },
          };
        },
        places: {},
      },
    },
    { origin: 'http://localhost:8080' }
  );

  const parsed = JSON.parse(await bridge.reverseGeocode(10.00846, 76.45163));
  check('geocoder denial -> ok:false', parsed.ok === false, JSON.stringify(parsed));
  check(
    'raw Google endpoint + code are preserved (nothing hidden)',
    /GEOCODER_GEOCODE/.test(parsed.error) &&
      /REQUEST_DENIED/.test(parsed.error) &&
      /not allowed to use the geocoder/i.test(parsed.error),
    parsed.error
  );
  check(
    'hint names the Geocoding API and the page origin',
    /Geocoding API/.test(parsed.error) &&
      /http:\/\/localhost:8080\/\*/.test(parsed.error),
    parsed.error
  );
}

{
  // Exactly what the browser reported for Places API (New):
  //   Requests to this API places.googleapis.com method
  //   google.maps.places.v1.Places.AutocompletePlaces are blocked.
  const bridge = loadBridge(
    {
      maps: {
        places: {
          AutocompleteSessionToken: function () {},
          AutocompleteSuggestion: {
            fetchAutocompleteSuggestions: async () => {
              throw new Error(
                'Requests to this API places.googleapis.com method ' +
                  'google.maps.places.v1.Places.AutocompletePlaces are blocked.'
              );
            },
          },
        },
      },
    },
    { origin: 'http://127.0.0.1:8081' }
  );

  const parsed = JSON.parse(await bridge.autocomplete('hospital', 10, 76, 30000));
  check(
    'blocked AutocompletePlaces -> ok:false with the raw message',
    parsed.ok === false &&
      /AutocompletePlaces are blocked/.test(parsed.error),
    JSON.stringify(parsed)
  );
  check(
    'hint names Places API (New) and the 8081 origin',
    /Places API \(New\)/.test(parsed.error) &&
      /http:\/\/127\.0\.0\.1:8081\/\*/.test(parsed.error),
    parsed.error
  );
}

// ---------------------------------------------------------------------------
console.log('diagnostics() reports key/origin/libraries without leaking the key');
{
  const bridge = loadBridge(
    {
      maps: {
        version: '3.58.10',
        Geocoder: function () {
          return { geocode: async () => ({ results: [] }) };
        },
        places: {
          Place: { searchNearby: async () => ({ places: [] }) },
          AutocompleteSuggestion: {
            fetchAutocompleteSuggestions: async () => ({ suggestions: [] }),
          },
          AutocompleteSessionToken: function () {},
          AutocompleteService: function () {},
        },
      },
    },
    {
      origin: 'http://localhost:8080',
      referrer: 'http://localhost:8080/',
      runtime: {
        keyConfigured: true,
        keyMasked: '****1234',
        keyLength: 39,
        keySource: 'web/google_maps_config.js',
        libraries: 'places',
        loaderUrl:
          'https://maps.googleapis.com/maps/api/js?key=****1234&libraries=places&v=weekly',
      },
    }
  );

  const report = JSON.parse(await bridge.diagnostics(10.00846, 76.45163));
  check('reports the page origin', report.page.origin === 'http://localhost:8080', report.page.origin);
  check('reports only a masked key', report.key.masked === '****1234', JSON.stringify(report.key));
  check(
    'never contains an unmasked key',
    !/AIza/.test(JSON.stringify(report)),
    JSON.stringify(report.key)
  );
  check('detects the loaded Maps JS version', report.libraries.mapsVersion === '3.58.10');
  check('detects Places API (New) availability', report.libraries.placesNew === true);
  check(
    'runs all three probes',
    !!report.probes.geocoding &&
      !!report.probes.placesAutocomplete &&
      !!report.probes.placesNearby,
    JSON.stringify(Object.keys(report.probes))
  );
}

console.log('');
console.log(`${checks - failures}/${checks} checks passed`);
process.exit(failures === 0 ? 0 : 1);
