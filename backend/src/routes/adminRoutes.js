const express = require('express');
const router = express.Router();
const adminController = require('../controllers/adminController');
const authenticate = require('../middleware/authMiddleware');
const authorizeRoles = require('../middleware/roleMiddleware');

router.use(authenticate, authorizeRoles('ADMIN'));

router.get('/requests', adminController.getAllRequests);
router.get('/allocations', adminController.getAllAllocations);
router.get('/responders', adminController.getAllResponders);

module.exports = router;