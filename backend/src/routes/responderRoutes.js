const express = require('express');
const router = express.Router();
const responderController = require('../controllers/responderController');
const authenticate = require('../middleware/authMiddleware');
const authorizeRoles = require('../middleware/roleMiddleware');

router.patch(
  "/status",
  authenticate,
  authorizeRoles("RESPONDER"),
  responderController.updateStatus
);

router.patch(
  "/location",
  authenticate,
  authorizeRoles("RESPONDER"),
  responderController.updateLocation
);
module.exports = router;