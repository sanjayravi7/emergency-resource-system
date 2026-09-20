const requestService = require('../services/requestService');

exports.createRequest = async (req, res, next) => {
  try {
    const request = await requestService.createEmergencyRequest(req.user.id, req.body);
    res.status(201).json({ success: true, request });
  } catch (error) {
    next(error);
  }
};

exports.getMyRequests = async (req, res, next) => {
  try {
    const requests = await requestService.getRequestsByUser(req.user.id);
    res.json({ success: true, requests });
  } catch (error) {
    next(error);
  }
};

exports.getRequestById = async (req, res, next) => {
  try {
    const request = await requestService.getRequestById(req.params.id);
    // Role check mapping goes here logically but simplified for brief
    res.json({ success: true, request });
  } catch (error) {
    next(error);
  }
};

exports.cancelMyRequest = async (req, res, next) => {
  try {
    const request = await requestService.cancelEmergencyRequest(req.user.id, req.params.id);
    res.json({ success: true, request });
  } catch (error) {
    next(error);
  }
};

exports.getAllRequests = async (req, res, next) => {
  try {
    const requests = await requestService.getAllRequests();
    res.json({ success: true, requests });
  } catch (error) {
    next(error);
  }
};

exports.acceptRequest = async (req, res, next) => {
  try {
    const request = await requestService.acceptEmergencyRequest(
      req.user.id,
      req.params.id
    );

    res.json({ success: true, request });
  } catch (error) {
    if (error.message === 'Responder is not available to accept') {
      return res.status(400).json({
        success: false,
        message: 'Responder is not available',
      });
    }

    next(error);
  }
};

exports.updateRequestStatus = async (req, res, next) => {
  try {
    const request = await requestService.updateRequestStatus(req.params.id, req.body.status);
    res.json({ success: true, request });
  } catch (error) {
    next(error);
  }
};