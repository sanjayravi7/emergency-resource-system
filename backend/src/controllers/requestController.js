const requestService = require('../services/requestService');

// A Prisma/infrastructure failure is never a client validation error. Prisma
// phrases every failed query as "Invalid `prisma.x.y()` invocation", which the
// message heuristic below would otherwise misread as a 400 and hide the real
// cause (for example a database column that is still NOT NULL because a
// migration was not deployed).
const isInfrastructureError = (error) =>
  Boolean(
    error &&
      (typeof error.code === 'string' ||
        /^PrismaClient/.test(error.name || '') ||
        /^Invalid `prisma\./.test(error.message || ''))
  );

// Errors raised by request validation are client errors (400),
// not server errors. Everything else keeps the existing behaviour.
const isValidationError = (message) =>
  /required|invalid|quantity|duplicate|does not exist|not active|out of stock|available|latitude|longitude|priority/i.test(
    message || ''
  );

exports.createRequest = async (req, res, next) => {
  try {
    const request = await requestService.createEmergencyRequest(req.user.id, req.body);
    res.status(201).json({ success: true, request });
  } catch (error) {
    if (!isInfrastructureError(error) && isValidationError(error.message)) {
      return res.status(400).json({
        success: false,
        message: error.message,
      });
    }

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

// Acceptance business rejections are client errors (400): they describe an
// action the responder cannot take right now, not an infrastructure fault.
// The historical 'Responder is not available' body is preserved verbatim for
// backward compatibility. Everything else keeps the existing behaviour.
const ACCEPTANCE_CLIENT_ERROR_MESSAGES = [
  'Responder is not available to accept',
  'Responder is inactive',
  'Only responders can accept emergencies',
  'Responder already has an active emergency',
  'Responder is already assigned to this request',
  'Request has already been cancelled',
  'Request has already been completed',
  'Request has no required resource',
  'Responder has no compatible resource with outstanding quantity',
];

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

    if (ACCEPTANCE_CLIENT_ERROR_MESSAGES.includes(error.message)) {
      return res.status(400).json({
        success: false,
        message: error.message,
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
exports.getAssignedRequests = async (req, res, next) => {
  try {
    const requests =
      await requestService.getAssignedRequestsForResponder(req.user.id);

    res.json({
      success: true,
      requests,
    });
  } catch (error) {
    next(error);
  }
};
exports.getCompatibleRequests = async (req, res, next) => {
  try {
    const requests =
      await requestService.getCompatibleRequestsForResponder(
        req.user.id
      );

    res.json({
      success: true,
      requests,
    });
  } catch (error) {
    next(error);
  }
};