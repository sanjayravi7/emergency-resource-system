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

// REQUESTER cancels their own request
router.patch(
  "/:id/cancel",
  authenticate,
  authorizeRoles("REQUESTER"),
  requestController.cancelMyRequest
);

module.exports = router;