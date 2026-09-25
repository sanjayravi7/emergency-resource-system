const express = require('express');
const router = express.Router();
const responderController = require('../controllers/responderController');
const authenticate = require('../middleware/authMiddleware');
const authorizeRoles = require('../middleware/roleMiddleware');

router.get('/', authenticate, responderController.getResponders);

router.patch(
  '/status',
  authenticate,
  authorizeRoles('RESPONDER'),
  responderController.updateStatus
);

router.patch(
  '/location',
  authenticate,
  authorizeRoles('RESPONDER'),
  responderController.updateLocation
);

router.post(
  '/heartbeat',
  authenticate,
  authorizeRoles('RESPONDER'),
  responderController.heartbeat
);

router.post(
  '/logout',
  authenticate,
  authorizeRoles('RESPONDER'),
  responderController.logout
);

module.exports = router;
