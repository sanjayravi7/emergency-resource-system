const resourceService = require('../services/resourceService');

exports.createResource = async (req, res, next) => {
  try {
    const resource = await resourceService.createResource(req.body);
    res.status(201).json({ success: true, resource });
  } catch (error) {
    next(error);
  }
};

exports.getAllResources = async (req, res, next) => {
  try {
    const resources = await resourceService.getAllResources();
    res.json({ success: true, resources });
  } catch (error) {
    next(error);
  }
};

exports.getResourceById = async (req, res, next) => {
  try {
    const resource = await resourceService.getResourceById(req.params.id);
    res.json({ success: true, resource });
  } catch (error) {
    next(error);
  }
};

exports.updateResource = async (req, res, next) => {
  try {
    const resource = await resourceService.updateResource(req.params.id, req.body);
    res.json({ success: true, resource });
  } catch (error) {
    next(error);
  }
};

exports.deleteResource = async (req, res, next) => {
  try {
    await resourceService.deleteResource(req.params.id);
    res.json({ success: true, message: 'Resource deleted' });
  } catch (error) {
    next(error);
  }
};