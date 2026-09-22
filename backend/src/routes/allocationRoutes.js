const express = require('express');
const router = express.Router();
const allocationController = require('../controllers/allocationController');
const authenticate = require('../middleware/authMiddleware');
const authorizeRoles = require('../middleware/roleMiddleware');

router.use(authenticate, authorizeRoles('RESPONDER', 'ADMIN'));

router.post(
  "/",
  authenticate,
  authorizeRoles("RESPONDER"),
  allocationController.createAllocation
);

router.get(
  "/my",
  authenticate,
  authorizeRoles("RESPONDER"),
  allocationController.getMyAllocations
);

router.patch(
  "/:id/status",
  authenticate,
  authorizeRoles("RESPONDER"),
  allocationController.updateAllocationStatus
);

module.exports = router;