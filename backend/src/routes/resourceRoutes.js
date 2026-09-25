const express = require('express');
const router = express.Router();
const resourceController = require('../controllers/resourceController');
const authenticate = require('../middleware/authMiddleware');
const authorizeRoles = require('../middleware/roleMiddleware');

// READ - every authenticated role can read the catalog.
// Requesters/responders only receive ACTIVE resources (see controller).
router.get('/availability', authenticate, resourceController.getResourceAvailability);
router.get('/', authenticate, resourceController.getAllResources);

// Low stock overview (ADMIN). Declared before '/:id' so it is not
// swallowed by the id route.
router.get(
  '/low-stock',
  authenticate,
  authorizeRoles('ADMIN'),
  resourceController.getLowStockResources
);

router.get('/:id', authenticate, resourceController.getResourceById);

// WRITE - ADMIN only.
router.post('/', authenticate, authorizeRoles('ADMIN'), resourceController.createResource);
router.patch('/:id', authenticate, authorizeRoles('ADMIN'), resourceController.updateResource);
router.patch(
  '/:id/deactivate',
  authenticate,
  authorizeRoles('ADMIN'),
  resourceController.deactivateResource
);
router.patch(
  '/:id/restore',
  authenticate,
  authorizeRoles('ADMIN'),
  resourceController.restoreResource
);
router.delete('/:id', authenticate, authorizeRoles('ADMIN'), resourceController.deleteResource);

module.exports = router;
