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

// FCM device token registration. Client errors (bad token, wrong role) come
// back as 400; everything else keeps the existing error middleware path.
const isDeviceTokenClientError = (message) =>
  /device token|Only responders/i.test(message || '');

exports.registerDeviceToken = async (req, res, next) => {
  try {
    const { token, platform } = req.body || {};
    const deviceToken = await responderService.registerDeviceToken(req.user.id, {
      token,
      platform,
    });
    res.status(201).json({ success: true, deviceToken });
  } catch (error) {
    if (isDeviceTokenClientError(error.message)) {
      return res.status(400).json({ success: false, message: error.message });
    }
    next(error);
  }
};

exports.removeDeviceToken = async (req, res, next) => {
  try {
    const { token } = req.body || {};
    const result = await responderService.removeDeviceToken(req.user.id, token);
    res.json({ success: true, ...result });
  } catch (error) {
    if (isDeviceTokenClientError(error.message)) {
      return res.status(400).json({ success: false, message: error.message });
    }
    next(error);
  }
};
