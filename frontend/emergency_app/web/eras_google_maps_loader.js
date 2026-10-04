/*
 * ERAS's single Maps JavaScript API loader for Flutter Web.
 *
 * Uses Google's Dynamic Library Import bootstrap, and imports both required
 * libraries before Flutter starts. The package google_maps_flutter_web
 * consumes the populated google.maps namespace; it does not need its own
 * script loader.
 *
 * This file deliberately owns all Maps API script/bootstrap creation. Callers
 * (index.html, the diagnostics page, and the Places bridge) share this
 * singleton and its promise rather than creating another script/bootstrap.
 */
(function (root) {
  'use strict';

  var API_NAME = 'erasGoogleMapsLoader';
  var VERSION = 1;
  var KEY_PATTERN = /^AIza[A-Za-z0-9_-]{35}$/;
  var SAFE_USER_MESSAGE =
    'Maps and place search are temporarily unavailable. Please contact ERAS support.';

  // Re-evaluating this file must not replace the existing singleton or reset
  // its promise. This also protects against accidental duplicate helper tags.
  if (root[API_NAME] && root[API_NAME].version === VERSION) return;

  var state = {
    status: 'idle',
    promise: null,
    key: null,
    initializationCount: 0,
    scriptCount: 0,
    errorCode: null,
  };

  function loaderError(code, message) {
    var error = new Error(message);
    error.name = 'ErasGoogleMapsLoaderError';
    error.code = code;
    error.userMessage = SAFE_USER_MESSAGE;
    return error;
  }

  function isValidKey(key) {
    return typeof key === 'string' && KEY_PATTERN.test(key);
  }

  function normalizeKey(key) {
    return typeof key === 'string' ? key.trim() : '';
  }

  function getMapsNamespace() {
    return root.google && root.google.maps ? root.google.maps : null;
  }

  function hasLoadedMapsAndPlaces(maps) {
    return !!(
      maps &&
      typeof maps.Map === 'function' &&
      maps.MapTypeId &&
      maps.places
    );
  }

  function mapsApiScriptTags() {
    var tags = [];
    var source = root.document && root.document.getElementsByTagName
      ? root.document.getElementsByTagName('script')
      : (root.document && root.document.scripts) || [];

    for (var i = 0; i < source.length; i += 1) {
      var script = source[i];
      var url = String((script && (script.src || script.getAttribute && script.getAttribute('src'))) || '');
      if (/maps\.googleapis\.com\/maps\/api\/js(?:[?#]|$)/i.test(url)) {
        tags.push(script);
      }
    }
    return tags;
  }

  function maskKey(key) {
    var text = String(key || '');
    return text.length > 4 ? '****' + text.slice(-4) : '****';
  }

  function maskedScriptUrl() {
    var scripts = mapsApiScriptTags();
    if (!scripts.length) return null;

    var url = String(scripts[0].src || '');
    return url.replace(/([?&]key=)([^&]*)/i, function (_match, prefix, value) {
      var decoded = value;
      try {
        decoded = decodeURIComponent(value.replace(/\+/g, ' '));
      } catch (_error) {
        // Keep the raw query fragment only long enough to mask its tail.
      }
      return prefix + maskKey(decoded);
    });
  }

  function requiredLibraries(maps) {
    if (!maps || typeof maps.importLibrary !== 'function') {
      if (hasLoadedMapsAndPlaces(maps)) {
        return Promise.resolve({
          maps: { Map: maps.Map, MapTypeId: maps.MapTypeId },
          places: maps.places,
        });
      }
      return Promise.reject(loaderError(
        'LIBRARIES_UNAVAILABLE',
        'The Maps JavaScript API loaded without the required Maps and Places libraries.'
      ));
    }

    // Keep a reference to the existing API function. In particular, this
    // reuses an already-installed Google bootstrap instead of registering a
    // second bootstrap or inserting another Maps API script.
    var importLibrary = maps.importLibrary;
    return Promise.all([
      importLibrary.call(maps, 'maps'),
      importLibrary.call(maps, 'places'),
    ]).then(function (libraries) {
      var readyMaps = getMapsNamespace();
      if (!hasLoadedMapsAndPlaces(readyMaps)) {
        throw loaderError(
          'LIBRARIES_UNAVAILABLE',
          'Google Maps loaded, but the Maps and Places libraries did not initialize.'
        );
      }
      return {
        google: root.google,
        maps: libraries[0],
        places: libraries[1],
      };
    });
  }

  function installDynamicLibraryImportBootstrap(key) {
    var google = root.google || (root.google = {});
    var maps = google.maps || (google.maps = {});

    // The official bootstrap can be installed only once. ensureLoaded checks
    // for this function before reaching this path; retain this guard as a
    // final defense if another caller won a race between those checks.
    if (typeof maps.importLibrary === 'function') return maps;

    var requestedLibraries = new Set();
    var loaderOptions = { key: key, v: 'weekly' };
    var scriptLoadPromise = null;

    function loadApiScript() {
      if (scriptLoadPromise) return scriptLoadPromise;

      // Defer URL construction by one microtask so parallel importLibrary()
      // calls for maps and places are both included in the initial request,
      // just like Google's recommended inline bootstrap.
      scriptLoadPromise = new Promise(function (resolve, reject) {
        Promise.resolve().then(function () {
          var script = root.document.createElement('script');
          var params = new URLSearchParams();
          params.set('libraries', Array.from(requestedLibraries).join(','));

          Object.keys(loaderOptions).forEach(function (name) {
            var queryName = name.replace(/[A-Z]/g, function (letter) {
              return '_' + letter.toLowerCase();
            });
            params.set(queryName, loaderOptions[name]);
          });

          params.set('callback', 'google.maps.__ib__');
          script.src = 'https://maps.googleapis.com/maps/api/js?' + params.toString();
          script.async = true;
          maps.__ib__ = function () {
            resolve();
          };
          script.onerror = function () {
            reject(loaderError(
              'SCRIPT_LOAD_FAILED',
              'The Google Maps JavaScript API script failed to load.'
            ));
          };

          var nonceScript = root.document.querySelector
            ? root.document.querySelector('script[nonce]')
            : null;
          if (nonceScript && nonceScript.nonce) script.nonce = nonceScript.nonce;

          state.scriptCount += 1;
          root.document.head.appendChild(script);
        }).catch(function () {
          reject(loaderError(
            'SCRIPT_LOAD_FAILED',
            'The Google Maps JavaScript API script could not be created.'
          ));
        });
      });

      return scriptLoadPromise;
    }

    var bootstrapImportLibrary = function (libraryName) {
      var args = Array.prototype.slice.call(arguments);
      requestedLibraries.add(String(libraryName));
      return loadApiScript().then(function () {
        var loadedMaps = getMapsNamespace();
        if (!loadedMaps || typeof loadedMaps.importLibrary !== 'function' ||
            loadedMaps.importLibrary === bootstrapImportLibrary) {
          throw loaderError(
            'LIBRARIES_UNAVAILABLE',
            'The Google Maps JavaScript API did not initialize its library importer.'
          );
        }
        return loadedMaps.importLibrary.apply(loadedMaps, args);
      });
    };
    maps.importLibrary = bootstrapImportLibrary;

    return maps;
  }

  function waitForExistingScript(script) {
    return new Promise(function (resolve, reject) {
      var settled = false;

      function finish(error) {
        if (settled) return;
        settled = true;
        if (error) {
          reject(error);
          return;
        }
        requiredLibraries(getMapsNamespace()).then(resolve, reject);
      }

      if (script && typeof script.addEventListener === 'function') {
        script.addEventListener('load', function () {
          finish();
        }, { once: true });
        script.addEventListener('error', function () {
          finish(loaderError(
            'SCRIPT_LOAD_FAILED',
            'The existing Google Maps JavaScript API script failed to load.'
          ));
        }, { once: true });
      } else if (script) {
        var oldLoad = script.onload;
        var oldError = script.onerror;
        script.onload = function (event) {
          if (typeof oldLoad === 'function') oldLoad.call(script, event);
          finish();
        };
        script.onerror = function (event) {
          if (typeof oldError === 'function') oldError.call(script, event);
          finish(loaderError(
            'SCRIPT_LOAD_FAILED',
            'The existing Google Maps JavaScript API script failed to load.'
          ));
        };
      }

      var readyState = script && script.readyState;
      if (hasLoadedMapsAndPlaces(getMapsNamespace())) {
        finish();
      } else if (readyState === 'loaded' || readyState === 'complete') {
        finish();
      } else if (!script) {
        finish(loaderError(
          'SCRIPT_LOAD_FAILED',
          'The existing Google Maps JavaScript API script could not be found.'
        ));
      }
    });
  }

  function initialize(key) {
    var cleanKey = normalizeKey(key);

    if (state.promise) {
      if (state.reuseExisting || !cleanKey || state.key === cleanKey) {
        return state.promise;
      }
      return Promise.reject(loaderError(
        'CONFLICTING_API_KEY',
        'Google Maps has already started with a different key configuration. Reload the page to use one browser key.'
      ));
    }

    var existingMaps = getMapsNamespace();
    var existingScripts = mapsApiScriptTags();
    var reuseExisting = !!existingMaps || existingScripts.length > 0;
    if (!reuseExisting && !cleanKey) {
      return Promise.reject(loaderError(
        'MISSING_API_KEY',
        'ERAS_GOOGLE_MAPS_API_KEY is not configured. Set the browser key before building the web application.'
      ));
    }
    if (!reuseExisting && !isValidKey(cleanKey)) {
      return Promise.reject(loaderError(
        'INVALID_API_KEY_CONFIGURATION',
        'ERAS_GOOGLE_MAPS_API_KEY is malformed. Use a valid browser Maps key issued by Google Cloud.'
      ));
    }

    state.key = cleanKey;
    state.reuseExisting = reuseExisting;
    state.status = 'loading';
    state.initializationCount += 1;

    // Publish the shared promise before touching an existing Google importer.
    // That way even a re-entrant call from another loader observes and reuses
    // this initialization instead of starting a second one.
    state.promise = Promise.resolve().then(function () {
      var maps = getMapsNamespace();
      if (maps && typeof maps.importLibrary === 'function') {
        return requiredLibraries(maps);
      }
      if (hasLoadedMapsAndPlaces(maps)) {
        return requiredLibraries(maps);
      }

      var existingScripts = mapsApiScriptTags();
      if (existingScripts.length) {
        return waitForExistingScript(existingScripts[0]);
      }
      if (maps) {
        // An existing but incomplete Maps namespace means another script or
        // bootstrap has begun initialization. Do not create a second one.
        throw loaderError(
          'EXISTING_LOADER_INCOMPLETE',
          'Google Maps is already initializing, but its library importer is not ready.'
        );
      }

      var bootstrapMaps = installDynamicLibraryImportBootstrap(cleanKey);
      return requiredLibraries(bootstrapMaps);
    }).then(function (result) {
      state.status = 'loaded';
      state.errorCode = null;
      return result;
    }, function (error) {
      state.status = 'failed';
      state.errorCode = error && error.code ? error.code : 'LOAD_FAILED';
      throw error;
    });

    return state.promise;
  }

  root[API_NAME] = {
    version: VERSION,
    ensureLoaded: initialize,
    isValidKey: function (key) {
      return isValidKey(normalizeKey(key));
    },
    getUserMessage: function () {
      return SAFE_USER_MESSAGE;
    },
    getDiagnostics: function () {
      return {
        status: state.status,
        initializationCount: state.initializationCount,
        scriptCount: state.scriptCount,
        errorCode: state.errorCode,
        scriptUrl: maskedScriptUrl(),
        libraries: ['maps', 'places'],
        loader: 'google-dynamic-library-import',
      };
    },
  };
})(typeof window !== 'undefined' ? window : globalThis);
