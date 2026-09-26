/*
 * ERAS location bridge.
 *
 * Thin wrapper around the Google Maps JavaScript API used by
 * lib/services/location_service_web.dart. Every method resolves with a JSON
 * *string* so the Dart side never walks untyped JS objects.
 *
 * Google APIs used (must be enabled on the Google Cloud project):
 *   - Maps JavaScript API   (map rendering + this bridge)
 *   - Geocoding API         (google.maps.Geocoder -> reverse geocoding)
 *   - Places API (New)      (AutocompleteSuggestion + Place.fetchFields +
 *                            Place.searchNearby -> Nearby Search (New))
 *
 * The browser key comes from web/google_maps_config.js (git-ignored,
 * HTTP-referrer restricted). No key is read or stored here.
 */
(function () {
  'use strict';

  var geocoder = null;
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

  /** Best-effort text for any thrown/rejected Google error. */
  function errorText(error) {
    if (!error) return 'Unknown Google error.';
    if (error.message) return String(error.message);
    return String(error);
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

  function getGeocoder() {
    if (!mapsReady()) return null;
    if (!geocoder) geocoder = new google.maps.Geocoder();
    return geocoder;
  }

  /**
   * Reverse geocoding.
   * https://developers.google.com/maps/documentation/geocoding/reverse-geocoding
   * Picks the most specific, human recognisable result rather than a plus code.
   */
  async function reverseGeocode(latitude, longitude) {
    var coder = getGeocoder();
    if (!coder) return fail('Google Maps JavaScript API is not loaded.');

    try {
      var response = await coder.geocode({
        location: { lat: Number(latitude), lng: Number(longitude) },
      });
      var results = (response && response.results) || [];
      if (!results.length) return fail('No address found for these coordinates.');

      var preferredTypes = [
        'point_of_interest',
        'establishment',
        'premise',
        'street_address',
        'sublocality',
        'locality',
      ];

      var best = null;
      for (var t = 0; t < preferredTypes.length && !best; t++) {
        for (var i = 0; i < results.length; i++) {
          var types = results[i].types || [];
          if (types.indexOf(preferredTypes[t]) !== -1 &&
              types.indexOf('plus_code') === -1) {
            best = results[i];
            break;
          }
        }
      }
      if (!best) {
        for (var j = 0; j < results.length && !best; j++) {
          if ((results[j].types || []).indexOf('plus_code') === -1) {
            best = results[j];
          }
        }
      }
      if (!best) best = results[0];

      return ok({
        label: best.formatted_address || '',
        placeId: best.place_id || null,
      });
    } catch (error) {
      return fail(error && error.message ? error.message : error);
    }
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
      return fail(error && error.message ? error.message : error);
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
      return fail(error && error.message ? error.message : error);
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
      return fail(errorText(error));
    }
  }

  window.erasLocationBridge = {
    isAvailable: function () {
      return mapsReady();
    },
    reverseGeocode: reverseGeocode,
    autocomplete: autocomplete,
    placeDetails: placeDetails,
    searchNearby: searchNearby,
  };
})();
