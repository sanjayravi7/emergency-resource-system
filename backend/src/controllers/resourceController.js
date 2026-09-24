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
    // ADMIN sees the full catalog (including deactivated resources) so it can
    // be managed. Everyone else only ever sees active resources.
    const isAdmin = req.user && req.user.role === 'ADMIN';

    const includeInactive =
      isAdmin && String(req.query.includeInactive ?? 'true') !== 'false';

    const resources = await resourceService.getAllResources({
      activeOnly: !includeInactive,
      type: req.query.type,
      search: req.query.search,
    });

    res.json({ success: true, resources });
  } catch (error) {
    next(error);
  }
};

exports.getLowStockResources = async (req, res, next) => {
  try {
    const resources = await resourceService.getLowStockResources();
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

exports.deactivateResource = async (req, res, next) => {
  try {
    const resource = await resourceService.setResourceActive(req.params.id, false);
    res.json({ success: true, resource });
  } catch (error) {
    next(error);
  }
};

exports.restoreResource = async (req, res, next) => {
  try {
    const resource = await resourceService.setResourceActive(req.params.id, true);
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
