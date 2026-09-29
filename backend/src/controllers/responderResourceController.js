const responderResourceService = require('../services/responderResourceService');

function handleInventoryError(error, res, next) {
  const message = error?.message || '';
  if (/only manage your own|unauthorized/i.test(message)) {
    return res.status(403).json({ success: false, message });
  }
  if (
    /required|valid|invalid|quantity|active|status|boolean|not found|cannot exceed/i.test(
      message
    )
  ) {
    return res.status(400).json({ success: false, message });
  }
  return next(error);
}

exports.getMyResources = async (req, res, next) => {
  try {
    const resources = await responderResourceService.getResourcesByResponder(req.user.id);
    res.json({ success: true, resources });
  } catch (error) {
    next(error);
  }
};

exports.addResource = async (req, res, next) => {
  try {
    const resource = await responderResourceService.addResource(req.user, req.body);
    res.status(201).json({ success: true, resource });
  } catch (error) {
    handleInventoryError(error, res, next);
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
    handleInventoryError(error, res, next);
  }
};

exports.deleteResource = async (req, res, next) => {
  try {
    await responderResourceService.deleteResource(req.user, req.params.id);
    res.json({ success: true, message: 'Deleted successfully' });
  } catch (error) {
    handleInventoryError(error, res, next);
  }
};

exports.getAllResources = async (req, res, next) => {
  try {
    const resources = await responderResourceService.getAllResources();
    res.json({ success: true, resources });
  } catch (error) {
    next(error);
  }
};
