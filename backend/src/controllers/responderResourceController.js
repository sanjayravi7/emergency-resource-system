const responderResourceService = require('../services/responderResourceService');

exports.getMyResources = async (req, res, next) => {
  try {
    const resources = await responderResourceService.getResourcesByResponder(req.user.id);
    res.json({ success: true, resources });
  } catch (error) {
    next(error);
  }
};

// Inventory input errors are client errors (400). Infrastructure failures keep
// the existing error-middleware path (never a 400 with a Prisma message).
const isInventoryInputError = (message) =>
  /must be|invalid status|quantity|boolean|resourceId|isEnabled/i.test(message || '');

exports.addResource = async (req, res, next) => {
  try {
    const resource = await responderResourceService.addResource(req.user, req.body);
    res.status(201).json({ success: true, resource });
  } catch (error) {
    if (isInventoryInputError(error.message)) {
      return res.status(400).json({ success: false, message: error.message });
    }
    next(error);
  }
};

// PATCH is the responder readiness endpoint. A responder can only update its
// own row; ADMIN keeps the route's established management access.
exports.updateResource = async (req, res, next) => {
  try {
    const resource = await responderResourceService.updateResource(
      req.user,
      req.params.id,
      req.body
    );
    res.json({ success: true, resource });
  } catch (error) {
    if (isInventoryInputError(error.message)) {
      return res.status(400).json({ success: false, message: error.message });
    }
    next(error);
  }
};

exports.deleteResource = async (req, res, next) => {
  try {
    await responderResourceService.deleteResource(req.user, req.params.id);
    res.json({ success: true, message: 'Deleted successfully' });
  } catch (error) {
    next(error);
  }
};

exports.getAllResources = async (req, res, next) => {
  try {
    const resources = await responderResourceService.getAllResources(req.user.role);
    res.json({ success: true, resources });
  } catch (error) {
    next(error);
  }
};
