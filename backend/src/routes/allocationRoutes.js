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

// A responder may dispatch or cancel only an allocation they own.
router.patch(
  '/:id/status',
  authenticate,
  authorizeRoles('RESPONDER'),
  allocationController.updateAllocationStatus
);

module.exports = router;
