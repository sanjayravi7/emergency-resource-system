// Regression tests for web/eras_google_maps_loader.js.
//
// Run with: node tool/eras_google_maps_loader_test.mjs
// The Maps key below is a synthetic test value; never use it in a deployment.

import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

const here = dirname(fileURLToPath(import.meta.url));
const loaderPath = resolve(here, '../web/eras_google_maps_loader.js');
const bridgePath = resolve(here, '../web/eras_location_bridge.js');
const indexPath = resolve(here, '../web/index.html');
const diagnosticsPath = resolve(here, '../web/eras_location_diagnostics.html');
const loaderSource = readFileSync(loaderPath, 'utf8');
const bridgeSource = readFileSync(bridgePath, 'utf8');
const indexSource = readFileSync(indexPath, 'utf8');
const diagnosticsSource = readFileSync(diagnosticsPath, 'utf8');
const testKey = `AIza${'x'.repeat(35)}`;

let checks = 0;
let failures = 0;

function check(name, condition, detail = '') {
  checks += 1;
  if (condition) {
    console.log(`  ok   ${name}`);
  } else {
    failures += 1;
    console.log(`  FAIL ${name}${detail ? ` -> ${detail}` : ''}`);
  }
}

function makeScript() {
  const listeners = new Map();
  return {
    src: '',
    async: false,
    nonce: '',
    readyState: 'loading',
    addEventListener(name, callback) {
      const callbacks = listeners.get(name) || [];
      callbacks.push(callback);
      listeners.set(name, callbacks);
    },
    emit(name, event = {}) {
      this.readyState = name === 'load' ? 'complete' : this.readyState;
      for (const callback of listeners.get(name) || []) callback(event);
      const propertyHandler = this[`on${name}`];
      if (typeof propertyHandler === 'function') propertyHandler.call(this, event);
    },
    getAttribute(name) {
      return name === 'src' ? this.src : null;
    },
  };
}

function makeHarness({ google, existingScripts = [], onMapsScript } = {}) {
  const scripts = [...existingScripts];
  const imports = [];
  const sandbox = {
    URLSearchParams,
    console: { warn() {}, error() {} },
    location: { origin: 'https://eras.website', href: 'https://eras.website/' },
    document: {
      createElement(name) {
        if (name !== 'script') throw new Error('Unexpected element type');
        return makeScript();
      },
      getElementsByTagName(name) {
        return name === 'script' ? scripts : [];
      },
      querySelector() {
        return null;
      },
      head: {
        appendChild(script) {
          scripts.push(script);
          if (/maps\.googleapis\.com\/maps\/api\/js/.test(script.src)) {
            onMapsScript?.({ script, sandbox, imports });
          }
          return script;
        },
      },
    },
  };
  if (google) sandbox.google = google;
  sandbox.window = sandbox;
  vm.createContext(sandbox);
  vm.runInContext(loaderSource, sandbox, { filename: loaderPath });
  return { sandbox, scripts, imports, loader: sandbox.erasGoogleMapsLoader };
}

function simulateGoogleApi({ script, sandbox, imports }) {
  const maps = sandbox.google.maps;
  const places = {
    Place: function Place() {},
    AutocompleteSessionToken: function AutocompleteSessionToken() {},
    AutocompleteSuggestion: {
      fetchAutocompleteSuggestions: async (request) => ({
        suggestions: [{
          placePrediction: {
            placeId: 'place-42',
            mainText: { toString: () => `Search result for ${request.input}` },
            secondaryText: { toString: () => 'Kolenchery, Kerala' },
          },
        }],
      }),
    },
  };
  maps.Map = function Map() {};
  maps.MapTypeId = { ROADMAP: 'roadmap' };
  maps.places = places;
  maps.importLibrary = async (name) => {
    imports.push(name);
    if (name === 'maps') return { Map: maps.Map, MapTypeId: maps.MapTypeId };
    if (name === 'places') return places;
    throw new Error('Unexpected library request');
  };
  maps.__ib__?.();
  script?.emit('load');
}

// ---------------------------------------------------------------------------
console.log('only the shared helper owns Maps API bootstrap creation');
{
  check('index references the shared helper exactly once',
    indexSource.split('eras_google_maps_loader.js').length - 1 === 1);
  check('index does not contain a second Maps API URL',
    !indexSource.includes('maps.googleapis.com/maps/api/js'));
  check('diagnostics reuses the shared helper rather than loading Maps directly',
    diagnosticsSource.includes('eras_google_maps_loader.js') &&
      !diagnosticsSource.includes('maps.googleapis.com/maps/api/js'));
  check('Places bridge contains no Maps API script URL',
    !bridgeSource.includes('maps.googleapis.com/maps/api/js'));
  check('config events call an idempotent startup callback',
    indexSource.includes('configScript.onload = startApplication;') &&
      !indexSource.includes('configScript.onload = loadFirebaseSdk(') &&
      !indexSource.includes('configScript.onerror = loadFirebaseSdk('));
}

// ---------------------------------------------------------------------------
console.log('dynamic Maps loading is one shared, idempotent initialization');
{
  const harness = makeHarness({
    onMapsScript({ script, sandbox, imports }) {
      Promise.resolve().then(() => simulateGoogleApi({ script, sandbox, imports }));
    },
  });

  const loaderSingleton = harness.loader;
  const first = harness.loader.ensureLoaded(testKey);
  vm.runInContext(loaderSource, harness.sandbox, { filename: loaderPath });
  const repeated = harness.sandbox.erasGoogleMapsLoader.ensureLoaded(testKey);
  check('re-evaluating the helper preserves its singleton',
    harness.sandbox.erasGoogleMapsLoader === loaderSingleton);
  check('repeated calls receive the same promise', first === repeated);
  const result = await first;
  const diagnostics = harness.loader.getDiagnostics();
  const mapsScripts = harness.scripts.filter((script) =>
    /maps\.googleapis\.com\/maps\/api\/js/.test(script.src)
  );
  check('one loader initialization is recorded', diagnostics.initializationCount === 1);
  check('one Maps API script tag is created', mapsScripts.length === 1);
  check('one loader script insertion is recorded', diagnostics.scriptCount === 1);
  check('Maps and Places both resolve', !!result.maps && !!result.places);
  check(
    'the bootstrap requests both libraries',
    new URL(mapsScripts[0].src).searchParams.get('libraries') === 'maps,places',
    new URL(mapsScripts[0].src).searchParams.get('libraries') || '(missing)'
  );
  check('diagnostic script URL masks the configured key',
    !diagnostics.scriptUrl?.includes(testKey) && diagnostics.scriptUrl?.includes('****'));
  check('the actual API script URL is not written to the loader diagnostics',
    !JSON.stringify(diagnostics).includes(testKey));
}

// ---------------------------------------------------------------------------
console.log('Places autocomplete works after the shared Maps initialization');
{
  const harness = makeHarness({
    onMapsScript({ script, sandbox, imports }) {
      Promise.resolve().then(() => simulateGoogleApi({ script, sandbox, imports }));
    },
  });

  await harness.loader.ensureLoaded(testKey);
  vm.runInContext(bridgeSource, harness.sandbox, { filename: bridgePath });
  const raw = await harness.sandbox.erasLocationBridge.autocomplete(
    'hospital', 9.99, 76.66, 30000
  );
  const result = JSON.parse(raw);
  check('Places autocomplete resolves a real prediction after Maps load',
    result.ok === true && result.predictions[0]?.placeId === 'place-42');
  check('Places bridge reuses the single API script',
    harness.scripts.filter((script) =>
      /maps\.googleapis\.com\/maps\/api\/js/.test(script.src)
    ).length === 1);
  check('Places bridge does not register another bootstrap',
    harness.loader.getDiagnostics().initializationCount === 1);
}

// ---------------------------------------------------------------------------
console.log('an existing Google importer is reused without a new bootstrap');
{
  const imports = [];
  const places = { Place: function Place() {} };
  const maps = {
    Map: function Map() {},
    MapTypeId: { ROADMAP: 'roadmap' },
    places,
    importLibrary(name) {
      imports.push(name);
      return Promise.resolve(name === 'maps' ? { Map: this.Map } : places);
    },
  };
  const originalImporter = maps.importLibrary;
  const harness = makeHarness({ google: { maps } });
  const first = harness.loader.ensureLoaded('');
  const repeated = harness.loader.ensureLoaded(testKey);
  check('an existing API is reused even when the new caller has no key',
    first === repeated);
  await first;
  check('the existing importer identity is unchanged', maps.importLibrary === originalImporter);
  check('existing importer loads both required libraries', imports.join(',') === 'maps,places');
  check('no new Maps API script is inserted', harness.scripts.length === 0);
}

// ---------------------------------------------------------------------------
console.log('an already loaded Maps namespace is reused without needing a key');
{
  const maps = {
    Map: function Map() {},
    MapTypeId: { ROADMAP: 'roadmap' },
    places: { Place: function Place() {} },
  };
  const harness = makeHarness({ google: { maps } });
  const first = harness.loader.ensureLoaded('');
  const repeated = harness.loader.ensureLoaded(testKey);
  check('fully loaded Maps and Places return the shared promise', first === repeated);
  const result = await first;
  check('loaded namespaces resolve Maps and Places', !!result.maps && !!result.places);
  check('no script is inserted for an already loaded namespace', harness.scripts.length === 0);
}

// ---------------------------------------------------------------------------
console.log('an existing Maps script that is still loading is reused');
{
  const existing = makeScript();
  existing.src = 'https://maps.googleapis.com/maps/api/js?key=already-present&libraries=places';
  const harness = makeHarness({
    google: { maps: {} },
    existingScripts: [existing],
  });
  const pending = harness.loader.ensureLoaded(testKey);
  await Promise.resolve();
  simulateGoogleApi({ script: existing, sandbox: harness.sandbox, imports: harness.imports });
  await pending;
  check('the existing script is the only Maps API tag', harness.scripts.length === 1);
  check('no replacement bootstrap is inserted', harness.loader.getDiagnostics().scriptCount === 0);
}

// ---------------------------------------------------------------------------
console.log('missing and malformed key configuration fails safely');
{
  const missing = makeHarness();
  let missingError;
  try {
    await missing.loader.ensureLoaded('');
  } catch (error) {
    missingError = error;
  }
  check('missing key has a clear ERAS_GOOGLE_MAPS_API_KEY error',
    missingError?.code === 'MISSING_API_KEY' && /ERAS_GOOGLE_MAPS_API_KEY/.test(missingError.message));
  check('missing key does not create a Maps script', missing.scripts.length === 0);

  const malformedValue = 'not-a-google-browser-key';
  const malformed = makeHarness();
  let malformedError;
  try {
    await malformed.loader.ensureLoaded(malformedValue);
  } catch (error) {
    malformedError = error;
  }
  check('malformed key configuration is rejected',
    malformedError?.code === 'INVALID_API_KEY_CONFIGURATION');
  check('user-facing configuration message is generic and safe',
    malformedError?.userMessage ===
      'Maps and place search are temporarily unavailable. Please contact ERAS support.' &&
      !malformedError.userMessage.includes(malformedValue) &&
      !malformedError.userMessage.includes('AIza'));
  check('malformed key does not create a Maps script', malformed.scripts.length === 0);
}

console.log('');
console.log(`${checks - failures}/${checks} checks passed`);
process.exit(failures === 0 ? 0 : 1);
