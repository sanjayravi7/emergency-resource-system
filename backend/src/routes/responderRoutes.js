const express = require('express');
const router = express.Router();
const responderController = require('../controllers/responderController');
const authenticate = require('../middleware/authMiddleware');
const authorizeRoles = require('../middleware/roleMiddleware');

router.get('/', authenticate, responderController.getResponders);

router.get(
  '/help-types',
  authenticate,
  authorizeRoles('RESPONDER'),
  responderController.getHelpTypes
);

router.put(
  '/help-types',
  authenticate,
  authorizeRoles('RESPONDER'),
  responderController.updateHelpTypes
);

router.patch(
  '/help-types',
  authenticate,
  authorizeRoles('RESPONDER'),
  responderController.updateHelpTypes
);

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

// FCM device tokens (one row per installed device). Responders register on
// login/token rotation and remove on logout, so pushes about new compatible
// emergencies reach backgrounded apps. Tokens are transport metadata only -
// the emergency request row remains the source of truth.
router.post(
  '/device-tokens',
  authenticate,
  authorizeRoles('RESPONDER'),
  responderController.registerDeviceToken
);

router.delete(
  '/device-tokens',
  authenticate,
  authorizeRoles('RESPONDER'),
  responderController.removeDeviceToken
);

module.exports = router;
