const express = require('express');
const router = express.Router();
const allocationController = require('../controllers/allocationController');
const authenticate = require('../middleware/authMiddleware');
const authorizeRoles = require('../middleware/roleMiddleware');

// The requester may only confirm receipt of an allocation on their own
// emergency. Ownership is enforced again by the service transaction.
router.patch(
  '/:id/received',
  authenticate,
  authorizeRoles('REQUESTER'),
  allocationController.confirmReceived
);

router.post(
  '/',
  authenticate,
  authorizeRoles('RESPONDER'),
  allocationController.createAllocation
);

router.get(
  '/my',
  authenticate,
  authorizeRoles('RESPONDER'),
  allocationController.getMyAllocations
);

// LEGACY-ONLY allocation history/compatibility API. These routes are retained
// so existing records and integrations remain usable, but they are not the
// normal Flutter responder workflow. New responder work uses
// ACCEPT -> POST /requests/:id/start -> POST /requests/:id/complete.
// A responder may dispatch, deliver, or cancel only an allocation they own.
// DELIVERED is the responder-side fallback for older clients that still use
// allocation delivery; it is valid only from DISPATCHED.
router.patch(
  '/:id/status',
  authenticate,
  authorizeRoles('RESPONDER'),
  allocationController.updateAllocationStatus
);

module.exports = router;
