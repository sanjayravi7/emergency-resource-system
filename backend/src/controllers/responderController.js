const responderService = require('../services/responderService');

exports.updateStatus = async (req, res, next) => {
  try {
    const { status } = req.body;
    const user = await responderService.updateResponderStatus(req.user.id, status);
    res.json({ success: true, user });
  } catch (error) {
    next(error);
  }
};

exports.updateLocation = async (req, res, next) => {
  try {
    const { location, latitude, longitude } = req.body;
    const user = await responderService.updateResponderLocation(req.user.id, location, latitude, longitude);
    res.json({ success: true, user });
  } catch (error) {
    next(error);
  }
};
exports.getResponders = async (req, res, next) => {
  try {
    const responders = await responderService.getResponders();

    res.json({
      success: true,
      responders,
    });
  } catch (error) {
    next(error);
  }
};
// NOTE: the responder-resource catalog is served by
// responderResourceController.getAllResources
// (GET /api/responder-resources). A duplicate copy used to live here and
// referenced an undefined service, so it could only ever throw.
