/*
 * ERAS location bridge.
 *
 * Thin wrapper around the Google Maps JavaScript API used by
 * lib/services/location_service_web.dart. Every method resolves with a JSON
 * *string* so the Dart side never walks untyped JS objects.
 *
 * Google APIs used (must be enabled on the Google Cloud project):
 *   - Maps JavaScript API   (map rendering + this bridge)
 *   - Places API (New)      (AutocompleteSuggestion + Place.fetchFields +
 *                            Place.searchNearby -> Nearby Search (New))
 *
 * The browser key comes from web/google_maps_config.js (git-ignored,
 * HTTP-referrer restricted). No key is read or stored here.
 */
(function () {
  'use strict';

  var sessionToken = null;

  function mapsReady() {
    return typeof google !== 'undefined' && !!google.maps;
  }

  function placesReady() {
    return mapsReady() && !!google.maps.places;
  }

  function ok(payload) {
    payload.ok = true;
    return JSON.stringify(payload);
  }

  function fail(message) {
    return JSON.stringify({ ok: false, error: String(message) });
  }

  function pageOrigin() {
    try {
      return String(window.location.origin || '');
    } catch (e) {
      return '';
    }
  }

  /**
   * Best-effort text for any thrown/rejected Google error.
   *
   * Maps JavaScript API errors are plain Error objects whose `code`
   * ("REQUEST_DENIED", "OVER_QUERY_LIMIT", ...) and `endpoint`
   * ("PLACES_AUTOCOMPLETE", ...) carry the actual reason.
   * Nothing is swallowed here: the code/endpoint are prefixed to the message
   * exactly as Google reported them.
   */
  function errorText(error) {
    if (!error) return 'Unknown Google error.';

    var parts = [];
    if (error.endpoint) parts.push(String(error.endpoint));
    if (error.code && String(error.code) !== String(error.endpoint)) {
      parts.push(String(error.code));
    }
    if (error.name && error.name !== 'Error' && !parts.length) {
      parts.push(String(error.name));
    }

    var message = error.message ? String(error.message) : String(error);
    return parts.length ? parts.join(': ') + ': ' + message : message;
  }

  /**
   * Appends the concrete Google Cloud fix for the authorization failures ERAS
   * actually hits in the browser. The raw Google error is always kept in front
   * of the hint — the error is never hidden or replaced.
   */
  function withAuthorizationHint(text, api) {
    var lower = String(text || '').toLowerCase();
    var denied =
      lower.indexOf('request_denied') !== -1 ||
      lower.indexOf('permission_denied') !== -1 ||
      lower.indexOf('not allowed to use') !== -1 ||
      lower.indexOf('are blocked') !== -1 ||
      lower.indexOf('apitargetblockedmaperror') !== -1 ||
      lower.indexOf('referernotallowedmaperror') !== -1 ||
      lower.indexOf('has not been used in project') !== -1 ||
      lower.indexOf('is disabled') !== -1;

    if (!denied) return text;

    return (
      text +
      ' [ERAS] This is a Google Cloud authorization failure, not an ERAS bug. ' +
      'Check that "' +
      api +
      '" is ENABLED in the project AND listed in the browser key\'s API ' +
      'restrictions, and that this exact origin (' +
      (pageOrigin() || 'unknown origin') +
      '/*) is an allowed HTTP referrer for that key.'
    );
  }

  async function ensurePlaces() {
    if (placesReady()) return true;
    if (mapsReady() && typeof google.maps.importLibrary === 'function') {
      try {
        await google.maps.importLibrary('places');
        return placesReady();
      } catch (e) {
        return false;
      }
    }
    return false;
  }

  /**
   * Place autocomplete (Place Autocomplete Data API, new).
   * https://developers.google.com/maps/documentation/javascript/place-autocomplete-data
   *
   * Nearby bias: when the requester already has coordinates we pass a
   * locationBias circle around them, so "hospital" returns hospitals near the
   * requester instead of unrelated places worldwide.
   */
  async function autocomplete(query, latitude, longitude, radiusMeters) {
    if (!(await ensurePlaces())) {
      return fail('Google Places library is not loaded.');
    }

    var text = String(query || '').trim();
    if (!text) return ok({ predictions: [] });

    var hasBias =
      latitude !== null && latitude !== undefined &&
      longitude !== null && longitude !== undefined;

    try {
      if (google.maps.places.AutocompleteSuggestion &&
          google.maps.places.AutocompleteSessionToken) {
        if (!sessionToken) {
          sessionToken = new google.maps.places.AutocompleteSessionToken();
        }

        var request = { input: text, sessionToken: sessionToken };
        if (hasBias) {
          request.locationBias = {
            center: { lat: Number(latitude), lng: Number(longitude) },
            radius: Math.max(1, Math.min(Number(radiusMeters) || 30000, 50000)),
          };
        }

        var response =
          await google.maps.places.AutocompleteSuggestion
            .fetchAutocompleteSuggestions(request);

        var suggestions = (response && response.suggestions) || [];
        var predictions = suggestions
          .map(function (suggestion) {
            var p = suggestion.placePrediction;
            if (!p) return null;
            return {
              placeId: p.placeId,
              primaryText: p.mainText ? p.mainText.toString() : p.text.toString(),
              secondaryText: p.secondaryText ? p.secondaryText.toString() : '',
            };
          })
          .filter(Boolean);

        return ok({ predictions: predictions });
      }

      // Fallback for older Maps JS releases.
      var service = new google.maps.places.AutocompleteService();
      var legacyRequest = { input: text };
      if (hasBias) {
        legacyRequest.location =
          new google.maps.LatLng(Number(latitude), Number(longitude));
        legacyRequest.radius =
          Math.max(1, Math.min(Number(radiusMeters) || 30000, 50000));
      }

      var legacy = await new Promise(function (resolve, reject) {
        service.getPlacePredictions(legacyRequest, function (res, status) {
          if (status === google.maps.places.PlacesServiceStatus.OK ||
              status === google.maps.places.PlacesServiceStatus.ZERO_RESULTS) {
            resolve(res || []);
          } else {
            reject(new Error('Places status: ' + status));
          }
        });
      });

      return ok({
        predictions: legacy.map(function (item) {
          var formatting = item.structured_formatting || {};
          return {
            placeId: item.place_id,
            primaryText: formatting.main_text || item.description,
            secondaryText: formatting.secondary_text || '',
          };
        }),
      });
    } catch (error) {
      // Typical failure: "Requests to this API places.googleapis.com method
      // google.maps.places.v1.Places.AutocompletePlaces are blocked."
      // -> Places API (New) missing from the browser key's API restrictions.
      return fail(withAuthorizationHint(errorText(error), 'Places API (New)'));
    }
  }

  /**
   * Resolves a selected prediction to its exact coordinates.
   * The selected place's own lat/lng becomes the canonical request location.
   */
  async function placeDetails(placeId) {
    if (!(await ensurePlaces())) {
      return fail('Google Places library is not loaded.');
    }
    if (!placeId) return fail('Missing place id.');

    try {
      if (google.maps.places.Place) {
        var place = new google.maps.places.Place({ id: String(placeId) });
        await place.fetchFields({
          fields: ['displayName', 'formattedAddress', 'location'],
        });

        // One session token covers one autocomplete session + its selection.
        sessionToken = null;

        if (!place.location) return fail('Google returned no coordinates.');

        var name = place.displayName ? place.displayName.toString() : '';
        var address = place.formattedAddress || '';
        var label = name && address && address.indexOf(name) !== 0
          ? name + ', ' + address
          : (address || name);

        return ok({
          label: label,
          placeId: String(placeId),
          latitude: place.location.lat(),
          longitude: place.location.lng(),
        });
      }

      var container = document.createElement('div');
      var legacyService = new google.maps.places.PlacesService(container);
      var detail = await new Promise(function (resolve, reject) {
        legacyService.getDetails(
          { placeId: String(placeId), fields: ['name', 'formatted_address', 'geometry'] },
          function (res, status) {
            if (status === google.maps.places.PlacesServiceStatus.OK && res) {
              resolve(res);
            } else {
              reject(new Error('Places status: ' + status));
            }
          }
        );
      });

      sessionToken = null;

      if (!detail.geometry || !detail.geometry.location) {
        return fail('Google returned no coordinates.');
      }

      var legacyLabel = detail.name && detail.formatted_address
        ? detail.name + ', ' + detail.formatted_address
        : (detail.formatted_address || detail.name || '');

      return ok({
        label: legacyLabel,
        placeId: String(placeId),
        latitude: detail.geometry.location.lat(),
        longitude: detail.geometry.location.lng(),
      });
    } catch (error) {
      return fail(withAuthorizationHint(errorText(error), 'Places API (New)'));
    }
  }

  /**
   * Nearby Search (New).
   * https://developers.google.com/maps/documentation/places/web-service/nearby-search
   *
   * Called with the requester's own GPS coordinates as the circle center and
   * a category's Google place types (Table A) as includedTypes. Results are
   * ranked by distance (rankPreference = DISTANCE) so the nearest real places
   * come first, and only the fields the UI renders are requested:
   * id, displayName, formattedAddress, location.
   *
   * When Places API (New) is disabled/not enabled for the project the promise
   * rejects (for example "Places API (New) has not been used in project ...
   * or it is disabled"); the rejection text is passed through so the Dart
   * side can degrade the NEARBY PLACES section gracefully.
   */
  async function searchNearby(
    latitude,
    longitude,
    includedTypes,
    radiusMeters,
    maxResults
  ) {
    if (!(await ensurePlaces())) {
      return fail('Google Places library is not loaded.');
    }

    var Place = google.maps.places.Place;
    if (!Place || typeof Place.searchNearby !== 'function') {
      return fail(
        'Nearby Search (New) is not available in this Maps JavaScript API ' +
          'release.'
      );
    }

    var types = (Array.isArray(includedTypes) ? includedTypes : [])
      .map(function (type) {
        return String(type || '').trim();
      })
      .filter(Boolean);
    if (!types.length) return fail('No place types were requested.');

    // Nearby Search (New) bounds: 0 < radius <= 50000 m, 1..20 results.
    var radius = Number(radiusMeters) || 5000;
    radius = Math.max(1, Math.min(radius, 50000));
    var limit = Number(maxResults) || 10;
    limit = Math.max(1, Math.min(limit, 20));

    var rankPreference = 'DISTANCE';
    try {
      var preference = google.maps.places.SearchNearbyRankPreference;
      if (preference && preference.DISTANCE) {
        rankPreference = preference.DISTANCE;
      }
    } catch (e) {
      /* keep the literal enum value */
    }

    try {
      var response = await Place.searchNearby({
        // Field mask: only what the UI renders (and is billed for).
        fields: ['id', 'displayName', 'formattedAddress', 'location'],
        includedTypes: types,
        locationRestriction: {
          center: { lat: Number(latitude), lng: Number(longitude) },
          radius: radius,
        },
        maxResultCount: limit,
        rankPreference: rankPreference,
      });

      var places = (response && response.places) || [];
      var results = [];
      for (var i = 0; i < places.length; i++) {
        var place = places[i];
        if (!place || !place.location) continue;
        var name = place.displayName ? String(place.displayName) : '';
        if (!name) continue;
        results.push({
          placeId: place.id ? String(place.id) : '',
          name: name,
          address: place.formattedAddress
            ? String(place.formattedAddress)
            : '',
          latitude: place.location.lat(),
          longitude: place.location.lng(),
        });
      }

      return ok({ places: results });
    } catch (error) {
      return fail(withAuthorizationHint(errorText(error), 'Places API (New)'));
    }
  }

  // -------------------------------------------------------------------------
  // Diagnostics
  //
  // Answers the Part A/B questions directly in the browser, with no hidden
  // errors: which key is actually used at runtime (masked), what the page
  // origin/referrer really is, which Google libraries loaded, and what each of
  // the three APIs replies for a live probe.
  //
  // Used by web/eras_location_diagnostics.html and available in the console as
  //   await erasLocationBridge.diagnostics(10.00846, 76.45163)
  // -------------------------------------------------------------------------
  async function diagnostics(latitude, longitude) {
    var runtime = window.ERAS_MAPS_RUNTIME || {};
    var lat = latitude === undefined || latitude === null ? null : Number(latitude);
    var lng = longitude === undefined || longitude === null ? null : Number(longitude);

    var report = {
      page: {
        href: (function () {
          try {
            return String(window.location.href);
          } catch (e) {
            return '';
          }
        })(),
        origin: pageOrigin(),
        referrer: (function () {
          try {
            return String(document.referrer || '');
          } catch (e) {
            return '';
          }
        })(),
      },
      key: {
        configured: !!runtime.keyConfigured,
        // Only a masked tail is ever exposed, never the key itself.
        masked: runtime.keyMasked || null,
        length: runtime.keyLength || 0,
        source: runtime.keySource || 'web/google_maps_config.js',
      },
      loader: {
        scriptUrl: runtime.loaderUrl || null,
        libraries: runtime.libraries || null,
        authFailure: !!window.ERAS_MAPS_AUTH_FAILURE,
      },
      libraries: {
        mapsJs: mapsReady(),
        mapsVersion: mapsReady() && google.maps.version ? String(google.maps.version) : null,
        places: placesReady(),
        placesNew:
          placesReady() &&
          !!google.maps.places.Place &&
          typeof google.maps.places.Place.searchNearby === 'function' &&
          !!google.maps.places.AutocompleteSuggestion,
        placesLegacy: placesReady() && !!google.maps.places.AutocompleteService,
      },
      probes: {},
    };

    if (lat !== null && lng !== null) {
      report.probes.placesAutocomplete = JSON.parse(
        await autocomplete('hospital', lat, lng, 30000)
      );
      report.probes.placesNearby = JSON.parse(
        await searchNearby(lat, lng, ['hospital'], 5000, 5)
      );
    }

    return JSON.stringify(report);
  }

  window.erasLocationBridge = {
    isAvailable: function () {
      return mapsReady();
    },
    autocomplete: autocomplete,
    placeDetails: placeDetails,
    searchNearby: searchNearby,
    diagnostics: diagnostics,
  };
})();
