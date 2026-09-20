const prisma = require('../config/prisma');

exports.createEmergencyRequest = async (userId, data) => {
  const { requiredResources, ...requestData } = data;
  
  return await prisma.emergencyRequest.create({
    data: {
      ...requestData,
      requesterId: userId,
      requiredResources: requiredResources ? {
        create: requiredResources.map(r => ({
          resourceId: r.resourceId,
          quantity: r.quantity
        }))
      } : undefined
    },
    include: { requiredResources: true }
  });
};

exports.getRequestsByUser = async (userId) => {
  return await prisma.emergencyRequest.findMany({ 
    where: { requesterId: userId },
    include: { requiredResources: true }
  });
};

exports.getRequestById = async (id) => {
  const request = await prisma.emergencyRequest.findUnique({ 
    where: { id: Number(id) },
    include: { requiredResources: true }
  });
  if (!request) throw new Error('Request not found');
  return request;
};

exports.cancelEmergencyRequest = async (userId, id) => {
  const request = await this.getRequestById(id);
  if (request.requesterId !== userId) throw new Error('Unauthorized: You can only cancel your own requests');
  if (request.status !== 'PENDING') throw new Error('Only PENDING requests can be cancelled');
  
  return await prisma.emergencyRequest.update({
    where: { id: Number(id) },
    data: { status: 'CANCELLED' }
  });
};

exports.getAllRequests = async () => {
  return await prisma.emergencyRequest.findMany({
    include: { requiredResources: true }
  });
};

exports.acceptEmergencyRequest = async (responderId, requestId) => {
  const request = await this.getRequestById(requestId);
  if (request.status !== 'PENDING') {
    throw new Error('Only PENDING requests can be accepted');
  }

  // Ensure responder is available
  const user = await prisma.user.findUnique({ where: { id: responderId } });
  if (user.role !== 'RESPONDER') {
    throw new Error('Only responders can accept emergencies');
  }
  if (user.responderStatus !== 'AVAILABLE') {
    throw new Error('Responder is not available to accept');
  }

  return await prisma.emergencyRequest.update({
    where: { id: Number(requestId) },
    data: { status: 'ACCEPTED' }
  });
};

exports.updateRequestStatus = async (requestId, status) => {
  // Can add state machine rules here
  return await prisma.emergencyRequest.update({
    where: { id: Number(requestId) },
    data: { status }
  });
};