const express = require('express');
const router = express.Router();
const requestController = require('../controllers/requestController');
const authenticate = require('../middleware/authMiddleware');
const authorizeRoles = require('../middleware/roleMiddleware');

// Requester
router.post('/', authenticate, authorizeRoles('REQUESTER', 'ADMIN'), requestController.createRequest);
router.get('/my', authenticate, authorizeRoles('REQUESTER'), requestController.getMyRequests);
router.get('/:id', authenticate, requestController.getRequestById);
router.patch('/:id/cancel', authenticate, authorizeRoles('REQUESTER'), requestController.cancelMyRequest);

// Responder & Admin
router.get('/', authenticate, authorizeRoles('RESPONDER', 'ADMIN'), requestController.getAllRequests);
router.patch('/:id/accept', authenticate, authorizeRoles('RESPONDER'), requestController.acceptRequest);
router.patch('/:id/status', authenticate, authorizeRoles('RESPONDER', 'ADMIN'), requestController.updateRequestStatus);

module.exports = router;