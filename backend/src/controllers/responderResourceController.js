const responderResourceService = require('../services/responderResourceService');

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
    const resource = await responderResourceService.addResource(req.user.id, req.body);
    res.status(201).json({ success: true, resource });
  } catch (error) {
    next(error);
  }
};

exports.updateResource = async (req, res, next) => {
  try {
    const resource = await responderResourceService.updateResource(req.user.id, req.params.id, req.body);
    res.json({ success: true, resource });
  } catch (error) {
    next(error);
  }
};

exports.deleteResource = async (req, res, next) => {
  try {
    await responderResourceService.deleteResource(req.user.id, req.params.id);
    res.json({ success: true, message: 'Deleted successfully' });
  } catch (error) {
    next(error);
  }
};