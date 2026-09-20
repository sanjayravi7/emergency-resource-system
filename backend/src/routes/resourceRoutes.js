const express = require('express');
const router = express.Router();
const resourceController = require('../controllers/resourceController');
const authenticate = require('../middleware/authMiddleware');
const authorizeRoles = require('../middleware/roleMiddleware');

router.get('/', authenticate, resourceController.getAllResources);
router.get('/:id', authenticate, resourceController.getResourceById);
router.post('/', authenticate, authorizeRoles('ADMIN'), resourceController.createResource);
router.patch('/:id', authenticate, authorizeRoles('ADMIN'), resourceController.updateResource);
router.delete('/:id', authenticate, authorizeRoles('ADMIN'), resourceController.deleteResource);

module.exports = router;