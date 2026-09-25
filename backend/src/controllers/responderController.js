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
    const user = await responderService.updateResponderLocation(
      req.user.id,
      location,
      latitude,
      longitude
    );
    res.json({ success: true, user });
  } catch (error) {
    next(error);
  }
};

exports.heartbeat = async (req, res, next) => {
  try {
    const user = await responderService.heartbeat(req.user.id);
    res.json({ success: true, user });
  } catch (error) {
    next(error);
  }
};

exports.logout = async (req, res, next) => {
  try {
    await responderService.logoutResponder(req.user.id);
    res.json({ success: true, message: 'Responder is offline' });
  } catch (error) {
    next(error);
  }
};

exports.getResponders = async (req, res, next) => {
  try {
    const responders = await responderService.getResponders();
    res.json({ success: true, responders });
  } catch (error) {
    next(error);
  }
};
