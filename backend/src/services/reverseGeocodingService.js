const env = require('../config/env');

const cache = new Map();
const CACHE_TTL_MS = 5 * 60 * 1000;

class ReverseGeocodingError extends Error {
  constructor(message, statusCode = 502) {
    super(message);
    this.name = 'ReverseGeocodingError';
    this.statusCode = statusCode;
  }
}

function displayNameFromProperties(properties = {}) {
  // Photon does not provide a single guaranteed formatted-address field.
  // Compose only fields returned by Photon; never infer or fabricate a label.
  const parts = [
    properties.name,
    [properties.housenumber, properties.street].filter(Boolean).join(' '),
    properties.postcode,
    properties.city || properties.town || properties.village,
    properties.state,
    properties.country,
  ].map((part) => String(part || '').trim()).filter(Boolean);

  return [...new Set(parts)].join(', ');
}

async function fetchPhoton(latitude, longitude) {
  const key = `${latitude},${longitude}`;
  const cached = cache.get(key);
  if (cached && cached.expiresAt > Date.now()) return cached.value;
  if (cached) cache.delete(key);

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), env.PHOTON_TIMEOUT_MS);
  try {
    const url = new URL(env.PHOTON_REVERSE_URL);
    url.searchParams.set('lat', String(latitude));
    url.searchParams.set('lon', String(longitude));

    const response = await fetch(url, {
      signal: controller.signal,
      headers: { Accept: 'application/json', 'User-Agent': env.PHOTON_USER_AGENT },
    });
    if (!response.ok) {
      throw new ReverseGeocodingError(`Photon returned HTTP ${response.status}`);
    }

    const body = await response.json();
    const feature = Array.isArray(body.features) ? body.features[0] : null;
    const properties = feature && feature.properties && typeof feature.properties === 'object'
      ? feature.properties
      : {};
    const displayName = displayNameFromProperties(properties);
    if (!displayName) return null;

    const value = { displayName, latitude, longitude };
    cache.set(key, { value, expiresAt: Date.now() + CACHE_TTL_MS });
    return value;
  } catch (error) {
    if (error.name === 'AbortError') {
      throw new ReverseGeocodingError('Reverse geocoding service timed out', 504);
    }
    if (error instanceof ReverseGeocodingError) throw error;
    throw new ReverseGeocodingError('Reverse geocoding service is unavailable', 502);
  } finally {
    clearTimeout(timeout);
  }
}

module.exports = { fetchPhoton, displayNameFromProperties, ReverseGeocodingError };
