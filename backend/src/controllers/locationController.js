const reverseGeocodingService = require('../services/reverseGeocodingService');
const googlePlacesService = require('../services/googlePlacesService');

function coordinate(value, min, max) {
  if (value === undefined || value === null) return null;
  const str = String(value).trim();
  if (!str) return null;
  const number = Number(str);
  return Number.isFinite(number) && number >= min && number <= max ? number : null;
}

async function reverseGeocode(req, res, next) {
  const latitude = coordinate(req.query.latitude, -90, 90);
  const longitude = coordinate(req.query.longitude, -180, 180);
  if (latitude === null) {
    return res.status(422).json({ success: false, message: 'latitude must be a number between -90 and 90' });
  }
  if (longitude === null) {
    return res.status(422).json({ success: false, message: 'longitude must be a number between -180 and 180' });
  }

  try {
    const data = await reverseGeocodingService.fetchPhoton(latitude, longitude);
    if (!data) {
      return res.status(404).json({ success: false, message: 'No address found for these coordinates' });
    }
    return res.json({ success: true, data });
  } catch (error) {
    if (error instanceof reverseGeocodingService.ReverseGeocodingError) {
      return res.status(error.statusCode).json({ success: false, message: error.message });
    }
    return next(error);
  }
}

/**
 * Native place autocomplete suggestions.
 */
async function autocomplete(req, res, next) {
  const query = typeof req.query.query === 'string' ? req.query.query : '';
  const latitude = coordinate(req.query.latitude, -90, 90);
  const longitude = coordinate(req.query.longitude, -180, 180);
  const radiusMeters = req.query.radius ? Number(req.query.radius) : undefined;

  try {
    const data = await googlePlacesService.autocomplete({
      query,
      latitude,
      longitude,
      radiusMeters,
    });
    return res.json({ success: true, data });
  } catch (error) {
    if (error instanceof googlePlacesService.GooglePlacesError) {
      return res.status(error.statusCode).json({
        success: false,
        message: error.message,
        code: error.code,
      });
    }
    return next(error);
  }
}

/**
 * Native place details / selected-place coordinate resolution.
 */
async function placeDetails(req, res, next) {
  const placeId = req.params.placeId || req.query.placeId;
  if (!placeId || typeof placeId !== 'string' || !placeId.trim()) {
    return res.status(400).json({ success: false, message: 'placeId is required' });
  }

  try {
    const data = await googlePlacesService.placeDetails(placeId.trim());
    return res.json({ success: true, data });
  } catch (error) {
    if (error instanceof googlePlacesService.GooglePlacesError) {
      return res.status(error.statusCode).json({
        success: false,
        message: error.message,
        code: error.code,
      });
    }
    return next(error);
  }
}

/**
 * Native nearby places search by category.
 */
async function searchNearby(req, res, next) {
  const latitude = coordinate(req.query.latitude, -90, 90);
  const longitude = coordinate(req.query.longitude, -180, 180);

  if (latitude === null) {
    return res.status(422).json({ success: false, message: 'latitude must be a number between -90 and 90' });
  }
  if (longitude === null) {
    return res.status(422).json({ success: false, message: 'longitude must be a number between -180 and 180' });
  }

  // Reject 0,0
  if (latitude === 0 && longitude === 0) {
    return res.status(422).json({ success: false, message: 'Coordinates (0, 0) are invalid' });
  }

  const category = req.query.category;
  const includedTypes = req.query.types || req.query.includedTypes;
  const radiusMeters = req.query.radius ? Number(req.query.radius) : undefined;
  const maxResults = req.query.maxResults ? Number(req.query.maxResults) : undefined;

  try {
    const data = await googlePlacesService.searchNearby({
      latitude,
      longitude,
      category,
      includedTypes,
      radiusMeters,
      maxResults,
    });
    return res.json({ success: true, data });
  } catch (error) {
    if (error instanceof googlePlacesService.GooglePlacesError) {
      return res.status(error.statusCode).json({
        success: false,
        message: error.message,
        code: error.code,
      });
    }
    return next(error);
  }
}

module.exports = {
  reverseGeocode,
  autocomplete,
  placeDetails,
  searchNearby,
};
