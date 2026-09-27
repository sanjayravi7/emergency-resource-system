const express = require('express');
const router = express.Router();
const adminController = require('../controllers/adminController');
const authenticate = require('../middleware/authMiddleware');
const authorizeRoles = require('../middleware/roleMiddleware');

router.use(authenticate, authorizeRoles('ADMIN'));

router.get('/requests', adminController.getAllRequests);
router.patch('/requests/:id/assignments/:responderId/end', adminController.endAssignment);
router.patch('/requests/:id/status', adminController.updateRequestStatus);
router.get('/allocations', adminController.getAllAllocations);
router.get('/responders', adminController.getAllResponders);

module.exports = router;