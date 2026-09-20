const express = require('express');
const router = express.Router();
const allocationController = require('../controllers/allocationController');
const authenticate = require('../middleware/authMiddleware');
const authorizeRoles = require('../middleware/roleMiddleware');

router.use(authenticate, authorizeRoles('RESPONDER', 'ADMIN'));

router.get('/my', allocationController.getMyAllocations);
router.post('/', allocationController.createAllocation);
router.patch('/:id/status', allocationController.updateAllocationStatus);

module.exports = router;