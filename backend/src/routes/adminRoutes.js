const express = require('express');
const router = express.Router();
const adminController = require('../controllers/adminController');
const authenticate = require('../middleware/authMiddleware');
const authorizeRoles = require('../middleware/roleMiddleware');
const { adminSensitiveLimiter } = require('../middleware/rateLimiters');

router.use(authenticate, authorizeRoles('ADMIN'));

router.get('/requests', adminController.getAllRequests);
router.post('/requests', adminController.createRequest);
router.patch('/requests/:id/assign/:responderId', adminController.assignRequest);
router.patch('/requests/:id/cancel', adminController.cancelRequest);
router.patch('/requests/:id/assignments/:responderId/end', adminController.endAssignment);
router.patch('/requests/:id/status', adminController.updateRequestStatus);
router.get('/allocations', adminController.getAllAllocations);
router.get('/responders', adminController.getAllResponders);

// ADMIN-only after-action log removal. The request body must carry
// { "confirm": true }; the visible log entry is archived (never destroyed) and
// the action itself is recorded as an ADMIN_DELETED_LOG audit event.
router.delete(
  '/logs/:id',
  adminSensitiveLimiter,
  adminController.deleteLogEntry
);

// Read-only view of the append-only security audit trail. There is
// deliberately no endpoint that deletes audit records.
router.get('/audit-logs', adminController.getAuditLogs);

module.exports = router;