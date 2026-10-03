const env = require('../config/env');
const logger = require('../config/logger');

const PLACES_API_BASE_URL = 'https://places.googleapis.com/v1';

class GooglePlacesError extends Error {
  constructor(message, statusCode = 502, code = 'PLACES_API_ERROR') {
    super(message);
    this.name = 'GooglePlacesError';
    this.statusCode = statusCode;
    this.code = code;
  }
}

/**
 * Category mapping for Google Places API (New) Nearby Search.
 * Matches Table A place types (only Table A types may be used in includedTypes).
 */
const CATEGORY_MAP = {
  hospital: ['hospital'],
  police: ['police'],
  firestation: ['fire_station'],
  fire_station: ['fire_station'],
  school: ['school', 'primary_school', 'secondary_school'],
  college: ['university'],
  university: ['university'],
  railwaystation: ['train_station', 'light_rail_station', 'subway_station'],
  railway_station: ['train_station', 'light_rail_station', 'subway_station'],
  railway: ['train_station', 'light_rail_station', 'subway_station'],
  busstation: ['bus_station', 'bus_stop'],
  bus_station: ['bus_station', 'bus_stop'],
  bus: ['bus_station', 'bus_stop'],
  landmark: [
    'cultural_landmark',
    'historical_landmark',
    'monument',
    'historical_place',
    'tourist_attraction',
    'plaza',
  ],
  church: ['church'],
  temple: ['hindu_temple', 'buddhist_temple', 'shinto_shrine'],
  mosque: ['mosque'],
};

// In-memory cache for places requests
const cache = new Map();
const AUTOCOMPLETE_TTL_MS = 60 * 1000;
const DETAILS_TTL_MS = 5 * 60 * 1000;
const NEARBY_TTL_MS = 2 * 60 * 1000;

function getCached(key) {
  const item = cache.get(key);
  if (!item) return null;
  if (item.expiresAt > Date.now()) return item.value;
  cache.delete(key);
  return null;
}

function setCached(key, value, ttlMs) {
  cache.set(key, { value, expiresAt: Date.now() + ttlMs });
}

function clearCache() {
  cache.clear();
}

function redactKey(text, key) {
  if (!text || !key) return text;
  return String(text).split(key).join('[REDACTED]');
}

function haversineDistanceMeters(lat1, lon1, lat2, lon2) {
  const R = 6371008.8;
  const toRad = Math.PI / 180;
  const dLat = (lat2 - lat1) * toRad;
  const dLon = (lon2 - lon1) * toRad;
  const a =
    Math.sin(dLat / 2) * Math.sin(dLat / 2) +
    Math.cos(lat1 * toRad) * Math.cos(lat2 * toRad) * Math.sin(dLon / 2) * Math.sin(dLon / 2);
  const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
  return R * c;
}

function isPlacesApiDisabledError(message) {
  const text = String(message || '').toLowerCase();
  return (
    text.includes('places api (new) has not been used') ||
    (text.includes('places api') && text.includes('disabled')) ||
    text.includes('request_denied') ||
    text.includes('permission_denied') ||
    text.includes('apitargetblockedmaperror') ||
    text.includes('is not authorized to use this service') ||
    (text.includes('places.googleapis.com') && text.includes('blocked')) ||
    text.includes('google.maps.places.v1')
  );
}

function parseGoogleError(status, body, apiKey) {
  let message = '';
  if (body && typeof body === 'object') {
    if (body.error && typeof body.error === 'object') {
      message = body.error.message || body.error.status || '';
    } else if (body.message) {
      message = body.message;
    }
  }
  if (!message) {
    message = `Google Places API returned HTTP ${status}`;
  }

  // Never leak the API key
  message = redactKey(message, apiKey);

  if (isPlacesApiDisabledError(message) || status === 403) {
    return new GooglePlacesError(
      'Nearby places unavailable. Enable Places API (New) in Google Cloud.',
      502,
      'PLACES_API_DISABLED'
    );
  }

  return new GooglePlacesError(message, 502, 'PLACES_UPSTREAM_ERROR');
}

/**
 * Autocomplete suggestions for typed query.
 */
async function autocomplete({ query, latitude, longitude, radiusMeters } = {}) {
  const trimmed = typeof query === 'string' ? query.trim() : '';
  if (!trimmed) {
    return { predictions: [] };
  }

  const apiKey = env.GOOGLE_PLACES_API_KEY;
  if (!apiKey) {
    throw new GooglePlacesError(
      'Places API is not configured on the server. Set GOOGLE_PLACES_API_KEY in the backend environment.',
      503,
      'PLACES_NOT_CONFIGURED'
    );
  }

  const hasBias =
    Number.isFinite(latitude) &&
    Number.isFinite(longitude) &&
    latitude >= -90 &&
    latitude <= 90 &&
    longitude >= -180 &&
    longitude <= 180 &&
    !(latitude === 0 && longitude === 0);

  const radius = Math.max(1, Math.min(Number(radiusMeters) || 30000, 50000));
  const cacheKey = `ac:${trimmed}:${hasBias ? `${latitude},${longitude},${radius}` : 'nobias'}`;
  const cached = getCached(cacheKey);
  if (cached) return cached;

  const requestBody = { input: trimmed };
  if (hasBias) {
    requestBody.locationBias = {
      circle: {
        center: { latitude: Number(latitude), longitude: Number(longitude) },
        radius,
      },
    };
  }

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), env.GOOGLE_PLACES_TIMEOUT_MS);

  try {
    const response = await fetch(`${PLACES_API_BASE_URL}/places:autocomplete`, {
      method: 'POST',
      signal: controller.signal,
      headers: {
        'Content-Type': 'application/json',
        'X-Goog-Api-Key': apiKey,
      },
      body: JSON.stringify(requestBody),
    });

    const body = await response.json().catch(() => ({}));

    if (!response.ok) {
      throw parseGoogleError(response.status, body, apiKey);
    }

    const suggestions = Array.isArray(body.suggestions) ? body.suggestions : [];
    const predictions = suggestions
      .map((item) => {
        const p = item.placePrediction;
        if (!p) return null;
        const placeId = p.placeId || (p.place ? String(p.place).replace(/^places\//, '') : '');
        const primaryText =
          (p.structuredFormat && p.structuredFormat.mainText && p.structuredFormat.mainText.text) ||
          (p.text && p.text.text) ||
          '';
        const secondaryText =
          (p.structuredFormat &&
            p.structuredFormat.secondaryText &&
            p.structuredFormat.secondaryText.text) ||
          '';

        if (!placeId || !primaryText) return null;
        return { placeId, primaryText, secondaryText };
      })
      .filter(Boolean);

    const result = { predictions };
    setCached(cacheKey, result, AUTOCOMPLETE_TTL_MS);
    return result;
  } catch (error) {
    if (error.name === 'AbortError') {
      throw new GooglePlacesError('Places autocomplete request timed out', 504, 'TIMEOUT');
    }
    if (error instanceof GooglePlacesError) throw error;
    logger.error('places.autocomplete_error', { message: redactKey(error?.message, apiKey) });
    throw new GooglePlacesError('Places autocomplete failed', 502, 'PLACES_ERROR');
  } finally {
    clearTimeout(timeout);
  }
}

/**
 * Place Details: resolve selected placeId into coordinates and label.
 */
async function placeDetails(placeId) {
  if (typeof placeId !== 'string' || !placeId.trim()) {
    throw new GooglePlacesError('A valid placeId is required', 400, 'INVALID_PLACE_ID');
  }

  const cleanPlaceId = placeId.trim().replace(/^places\//, '');
  const apiKey = env.GOOGLE_PLACES_API_KEY;
  if (!apiKey) {
    throw new GooglePlacesError(
      'Places API is not configured on the server. Set GOOGLE_PLACES_API_KEY in the backend environment.',
      503,
      'PLACES_NOT_CONFIGURED'
    );
  }

  const cacheKey = `details:${cleanPlaceId}`;
  const cached = getCached(cacheKey);
  if (cached) return cached;

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), env.GOOGLE_PLACES_TIMEOUT_MS);

  try {
    const url = `${PLACES_API_BASE_URL}/places/${encodeURIComponent(cleanPlaceId)}`;
    const response = await fetch(url, {
      method: 'GET',
      signal: controller.signal,
      headers: {
        'Content-Type': 'application/json',
        'X-Goog-Api-Key': apiKey,
        'X-Goog-FieldMask': 'id,displayName,formattedAddress,location',
      },
    });

    const body = await response.json().catch(() => ({}));

    if (!response.ok) {
      throw parseGoogleError(response.status, body, apiKey);
    }

    const location = body.location;
    const lat = location && Number(location.latitude);
    const lng = location && Number(location.longitude);

    if (
      !Number.isFinite(lat) ||
      !Number.isFinite(lng) ||
      lat < -90 ||
      lat > 90 ||
      lng < -180 ||
      lng > 180
    ) {
      throw new GooglePlacesError(
        'Google returned no valid coordinates for the selected place.',
        502,
        'NO_COORDINATES'
      );
    }

    // Never use (0, 0) coordinates
    if (lat === 0 && lng === 0) {
      throw new GooglePlacesError(
        'Google returned invalid (0, 0) coordinates for the selected place.',
        502,
        'ZERO_COORDINATES'
      );
    }

    const name = (body.displayName && body.displayName.text) || '';
    const address = body.formattedAddress || '';
    const label =
      name && address && !address.startsWith(name)
        ? `${name}, ${address}`
        : address || name || cleanPlaceId;

    const result = {
      placeId: body.id || cleanPlaceId,
      label,
      latitude: lat,
      longitude: lng,
    };

    setCached(cacheKey, result, DETAILS_TTL_MS);
    return result;
  } catch (error) {
    if (error.name === 'AbortError') {
      throw new GooglePlacesError('Place details request timed out', 504, 'TIMEOUT');
    }
    if (error instanceof GooglePlacesError) throw error;
    logger.error('places.details_error', { message: redactKey(error?.message, apiKey) });
    throw new GooglePlacesError('Place details resolution failed', 502, 'PLACES_ERROR');
  } finally {
    clearTimeout(timeout);
  }
}

/**
 * Nearby Places: search around coordinates using Places API (New) Nearby Search.
 */
async function searchNearby({
  latitude,
  longitude,
  category,
  includedTypes,
  radiusMeters,
  maxResults,
} = {}) {
  const lat = Number(latitude);
  const lng = Number(longitude);

  if (
    !Number.isFinite(lat) ||
    !Number.isFinite(lng) ||
    lat < -90 ||
    lat > 90 ||
    lng < -180 ||
    lng > 180
  ) {
    throw new GooglePlacesError(
      'Valid latitude (-90..90) and longitude (-180..180) are required.',
      400,
      'INVALID_COORDINATES'
    );
  }

  // Never use 0,0
  if (lat === 0 && lng === 0) {
    throw new GooglePlacesError(
      'Coordinates (0, 0) are invalid for nearby place search.',
      400,
      'ZERO_COORDINATES'
    );
  }

  // Resolve types
  let types = [];
  if (category && typeof category === 'string') {
    const normalizedCategory = category.trim().toLowerCase().replace(/[\s-]+/g, '_');
    types = CATEGORY_MAP[normalizedCategory] || [];
  }
  if (!types.length && Array.isArray(includedTypes)) {
    types = includedTypes.map((t) => String(t || '').trim()).filter(Boolean);
  } else if (!types.length && typeof includedTypes === 'string' && includedTypes.trim()) {
    types = includedTypes.split(',').map((t) => t.trim()).filter(Boolean);
  }

  if (!types.length) {
    throw new GooglePlacesError(
      'No valid place types requested for nearby search.',
      400,
      'INVALID_TYPES'
    );
  }

  const radius = Math.max(1, Math.min(Number(radiusMeters) || 5000, 50000));
  const limit = Math.max(1, Math.min(Number(maxResults) || 10, 20));

  const apiKey = env.GOOGLE_PLACES_API_KEY;
  if (!apiKey) {
    throw new GooglePlacesError(
      'Places API is not configured on the server. Set GOOGLE_PLACES_API_KEY in the backend environment.',
      503,
      'PLACES_NOT_CONFIGURED'
    );
  }

  const cacheKey = `nearby:${lat.toFixed(4)},${lng.toFixed(4)}:${types.sort().join(',')}:${radius}:${limit}`;
  const cached = getCached(cacheKey);
  if (cached) return cached;

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), env.GOOGLE_PLACES_TIMEOUT_MS);

  try {
    const response = await fetch(`${PLACES_API_BASE_URL}/places:searchNearby`, {
      method: 'POST',
      signal: controller.signal,
      headers: {
        'Content-Type': 'application/json',
        'X-Goog-Api-Key': apiKey,
        'X-Goog-FieldMask':
          'places.id,places.displayName,places.formattedAddress,places.location',
      },
      body: JSON.stringify({
        includedTypes: types,
        maxResultCount: limit,
        locationRestriction: {
          circle: {
            center: { latitude: lat, longitude: lng },
            radius,
          },
        },
        rankPreference: 'DISTANCE',
      }),
    });

    const body = await response.json().catch(() => ({}));

    if (!response.ok) {
      throw parseGoogleError(response.status, body, apiKey);
    }

    const rawPlaces = Array.isArray(body.places) ? body.places : [];
    const places = rawPlaces
      .map((p) => {
        const placeLat = p.location && Number(p.location.latitude);
        const placeLng = p.location && Number(p.location.longitude);
        const placeId = p.id || '';
        const name = (p.displayName && p.displayName.text) || '';

        if (
          !Number.isFinite(placeLat) ||
          !Number.isFinite(placeLng) ||
          placeLat < -90 ||
          placeLat > 90 ||
          placeLng < -180 ||
          placeLng > 180 ||
          (placeLat === 0 && placeLng === 0) ||
          !placeId ||
          !name
        ) {
          return null;
        }

        const distanceMeters = Math.round(
          haversineDistanceMeters(lat, lng, placeLat, placeLng)
        );

        return {
          placeId,
          name,
          address: p.formattedAddress || '',
          latitude: placeLat,
          longitude: placeLng,
          distanceMeters,
        };
      })
      .filter(Boolean);

    // Rank by distance ascending
    places.sort((a, b) => a.distanceMeters - b.distanceMeters);

    const result = { places };
    setCached(cacheKey, result, NEARBY_TTL_MS);
    return result;
  } catch (error) {
    if (error.name === 'AbortError') {
      throw new GooglePlacesError('Nearby places search timed out', 504, 'TIMEOUT');
    }
    if (error instanceof GooglePlacesError) throw error;
    logger.error('places.nearby_error', { message: redactKey(error?.message, apiKey) });
    throw new GooglePlacesError('Nearby places search failed', 502, 'PLACES_ERROR');
  } finally {
    clearTimeout(timeout);
  }
}

module.exports = {
  GooglePlacesError,
  CATEGORY_MAP,
  autocomplete,
  placeDetails,
  searchNearby,
  haversineDistanceMeters,
  isPlacesApiDisabledError,
  clearCache,
};
