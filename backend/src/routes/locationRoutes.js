const express = require('express');
const authenticate = require('../middleware/authMiddleware');
const locationController = require('../controllers/locationController');

const router = express.Router();

// Explicit requester actions, never a socket telemetry path.
router.get('/reverse', authenticate, locationController.reverseGeocode);
router.get('/autocomplete', authenticate, locationController.autocomplete);
router.get('/details/:placeId', authenticate, locationController.placeDetails);
router.get('/details', authenticate, locationController.placeDetails);
router.get('/nearby', authenticate, locationController.searchNearby);

module.exports = router;
