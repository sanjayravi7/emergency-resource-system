const express = require("express");
const router = express.Router();

const requestController = require("../controllers/requestController");
const authenticate = require("../middleware/authMiddleware");
const authorizeRoles = require("../middleware/roleMiddleware");

// REQUESTER creates an emergency
router.post(
  "/",
  authenticate,
  authorizeRoles("REQUESTER"),
  requestController.createRequest
);

// RESPONDER views all compatible emergency requests
router.get(
  "/compatible",
  authenticate,
  authorizeRoles("RESPONDER"),
  requestController.getCompatibleRequests
);

// RESPONDER views the emergencies they already accepted
router.get(
  "/assigned",
  authenticate,
  authorizeRoles("RESPONDER"),
  requestController.getAssignedRequests
);

// REQUESTER views their own requests
router.get(
  "/my",
  authenticate,
  authorizeRoles("REQUESTER"),
  requestController.getMyRequests
);

// RESPONDER views all emergency requests
router.get(
  "/",
  authenticate,
  authorizeRoles("RESPONDER"),
  requestController.getAllRequests
);

// RESPONDER accepts an emergency
router.patch(
  "/:id/accept",
  authenticate,
  authorizeRoles("RESPONDER"),
  requestController.acceptRequest
);

// RESPONDER starts work on any accepted emergency (resource-free or bearing)
router.post(
  "/:id/start",
  authenticate,
  authorizeRoles("RESPONDER"),
  requestController.startResponse
);

// RESPONDER completes any in-progress emergency
router.post(
  "/:id/complete",
  authenticate,
  authorizeRoles("RESPONDER"),
  requestController.completeResponse
);

// LEGACY/administrative cleanup route. The current Flutter responder UI
// releases its assignment through COMPLETE RESPONSE instead of exposing an
// End Assignment control.
router.patch(
  "/:id/assignment/end",
  authenticate,
  authorizeRoles("RESPONDER"),
  requestController.endAssignment
);

// REQUESTER cancels their own request
router.patch(
  "/:id/cancel",
  authenticate,
  authorizeRoles("REQUESTER"),
  requestController.cancelMyRequest
);

module.exports = router;