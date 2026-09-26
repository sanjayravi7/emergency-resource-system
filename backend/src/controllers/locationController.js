const { fetchPhoton, ReverseGeocodingError } = require('../services/reverseGeocodingService');

function coordinate(value, min, max) {
  if (typeof value !== 'string' || value.trim() === '') return null;
  const number = Number(value);
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
    const data = await fetchPhoton(latitude, longitude);
    if (!data) {
      return res.status(404).json({ success: false, message: 'No address found for these coordinates' });
    }
    return res.json({ success: true, data });
  } catch (error) {
    if (error instanceof ReverseGeocodingError) {
      return res.status(error.statusCode).json({ success: false, message: error.message });
    }
    return next(error);
  }
}

module.exports = { reverseGeocode };
