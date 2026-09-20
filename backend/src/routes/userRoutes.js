const express = require('express');
const router = express.Router();
const adminController = require('../controllers/adminController');
const authenticate = require('../middleware/authMiddleware');
const authorizeRoles = require('../middleware/roleMiddleware');

router.use(authenticate, authorizeRoles('ADMIN'));

router.get('/', adminController.getAllUsers);
router.patch('/:id/role', adminController.updateUserRole);
router.patch('/:id/activate', adminController.activateUser);
router.patch('/:id/deactivate', adminController.deactivateUser);

module.exports = router;