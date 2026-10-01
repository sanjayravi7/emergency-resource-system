const express = require("express");
const router = express.Router();

const requestController = require("../controllers/requestController");
const authenticate = require("../middleware/authMiddleware");
const authorizeRoles = require("../middleware/roleMiddleware");

// REQUESTER creates an emergency
router.post(
  "/",
  authenticate,
  authorizeRoles("REQUESTER", "ADMIN"),
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

// RESPONDER starts work on an accepted emergency (resource-free or resource-bearing)
router.post(
  "/:id/start",
  authenticate,
  authorizeRoles("RESPONDER"),
  requestController.startResponse
);

// RESPONDER completes an in-progress emergency (resource-free or resource-bearing)
router.post(
  "/:id/complete",
  authenticate,
  authorizeRoles("RESPONDER"),
  requestController.completeResponse
);

// RESPONDER may end only their own assignment.
router.patch(
  "/:id/assignment/end",
  authenticate,
  authorizeRoles("RESPONDER"),
  requestController.endAssignment
);

// REQUESTER edits only their own pending request.
router.patch(
  "/:id",
  authenticate,
  authorizeRoles("REQUESTER"),
  requestController.updateOwnRequest
);

// REQUESTER cancels their own request (DELETE is the public cancellation contract).
router.delete(
  "/:id",
  authenticate,
  authorizeRoles("REQUESTER"),
  requestController.cancelMyRequest
);
router.patch(
  "/:id/cancel",
  authenticate,
  authorizeRoles("REQUESTER"),
  requestController.cancelMyRequest
);

module.exports = router;