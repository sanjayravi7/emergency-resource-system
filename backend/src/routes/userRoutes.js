const express = require('express');
const router = express.Router();
const adminController = require('../controllers/adminController');
const userController = require('../controllers/userController');
const authenticate = require('../middleware/authMiddleware');
const authorizeRoles = require('../middleware/roleMiddleware');
const { adminSensitiveLimiter } = require('../middleware/rateLimiters');

// SELF-SERVICE FIRST: any authenticated account may correct its OWN display
// name / phone number. It is registered before the ADMIN gate below (and
// before the `/:id` patterns) so a REQUESTER or RESPONDER can reach it while
// every other route on this router stays ADMIN-only.
router.patch('/me', authenticate, userController.updateOwnProfile);

// Everything below is ADMIN-only. Note that `/me` above is matched first, so
// the `/:id` patterns can never resolve to the literal path `me`.
router.use(authenticate, authorizeRoles('ADMIN'));

router.get('/', adminController.getAllUsers);
// Profile correction (name/phone). Email, role and isActive are refused by the
// controller because each has its own guarded endpoint.
router.patch('/:id', adminController.updateUserProfile);
router.patch('/:id/role', adminController.updateUserRole);
router.patch('/:id/activate', adminController.activateUser);
router.patch('/:id/deactivate', adminController.deactivateUser);

// Destructive account removal. Only ever succeeds for an account with no
// emergency/allocation history; the body must carry { "confirm": true } and
// the action is rate limited like every other sensitive admin operation.
router.delete(
  '/:id',
  adminSensitiveLimiter,
  adminController.deleteUser
);

module.exports = router;
