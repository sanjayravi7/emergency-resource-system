const express = require('express');
const authenticate = require('../middleware/authMiddleware');
const locationController = require('../controllers/locationController');

const router = express.Router();

// Reverse geocoding is an explicit requester action, never a socket telemetry path.
router.get('/reverse', authenticate, locationController.reverseGeocode);

module.exports = router;
