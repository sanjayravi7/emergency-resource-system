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