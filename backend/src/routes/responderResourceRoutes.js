const express = require('express');
const router = express.Router();
const responderResourceController = require('../controllers/responderResourceController');
const authenticate = require('../middleware/authMiddleware');
const authorizeRoles = require('../middleware/roleMiddleware');
 
router.get(
  "/",
  authenticate,
  authorizeRoles("RESPONDER"),
  responderResourceController.getAllResources
);

router.use(authenticate, authorizeRoles('RESPONDER', 'ADMIN'));

router.get('/my', responderResourceController.getMyResources);
router.post('/', responderResourceController.addResource);
router.patch('/:id', responderResourceController.updateResource);
router.delete('/:id', responderResourceController.deleteResource);

module.exports = router;