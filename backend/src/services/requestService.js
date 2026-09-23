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
exports.getCompatibleRequestsForResponder = async (responderId) => {
  const activeEmergency =
    await prisma.emergencyRequest.findFirst({
      where: {
        acceptedById: Number(responderId),
        status: {
          in: [
            'ACCEPTED',
            'IN_PROGRESS',
            'PARTIALLY_ALLOCATED',
          ],
        },
      },
      select: {
        id: true,
      },
    });

  if (activeEmergency) {
    return [];
  }

  const responderResources =
    await prisma.responderResource.findMany({
      where: {
        responderId: Number(responderId),
        status: 'AVAILABLE',
        availableQuantity: {
          gt: 0,
        },
      },
    });

  const requests =
    await prisma.emergencyRequest.findMany({
      where: {
        status: 'PENDING',
      },
      include: {
        requiredResources: true,
      },
      orderBy: [
        { priority: 'desc' },
        { createdAt: 'asc' },
      ],
    });

  return requests.filter((request) => {
    if (!request.requiredResources.length) {
      return false;
    }

    return request.requiredResources.every(
      (required) => {
        const resource =
          responderResources.find(
            (item) =>
              item.resourceId === required.resourceId,
          );

        return (
          resource &&
          resource.availableQuantity >=
            required.quantity
        );
      },
    );
  });
};
exports.acceptEmergencyRequest = async (responderId, requestId) => {
  return await prisma.$transaction(async (tx) => {
    const request = await tx.emergencyRequest.findUnique({
      where: { id: Number(requestId) },
      include: {
        requiredResources: true,
      },
    });

    if (!request) {
      throw new Error('Request not found');
    }

    if (request.status !== 'PENDING') {
      throw new Error('Only PENDING requests can be accepted');
    }

    const responder = await tx.user.findUnique({
      where: { id: Number(responderId) },
    });

    if (!responder || responder.role !== 'RESPONDER') {
      throw new Error('Only responders can accept emergencies');
    }

    if (!responder.isActive) {
      throw new Error('Responder is inactive');
    }

    if (responder.responderStatus !== 'AVAILABLE') {
      throw new Error('Responder is not available to accept');
    }

    // ----------------------------------------------------
    // RULE 1: One active emergency per responder
    // ----------------------------------------------------
    const activeEmergency = await tx.emergencyRequest.findFirst({
      where: {
        acceptedById: Number(responderId),
        status: {
          in: ['ACCEPTED', 'IN_PROGRESS', 'PARTIALLY_ALLOCATED'],
        },
      },
      select: {
        id: true,
      },
    });

    if (activeEmergency) {
      throw new Error(
        'Responder already has an active emergency',
      );
    }

    // ----------------------------------------------------
    // RULE 2: Responder must have the required resources
    // ----------------------------------------------------
    if (!request.requiredResources.length) {
      throw new Error(
        'Request has no required resource',
      );
    }

    const responderResources =
      await tx.responderResource.findMany({
        where: {
          responderId: Number(responderId),
          status: 'AVAILABLE',
          availableQuantity: {
            gt: 0,
          },
        },
      });

    for (const required of request.requiredResources) {
      const matching = responderResources.find(
        (resource) =>
          resource.resourceId === required.resourceId &&
          resource.availableQuantity >= required.quantity,
      );

      if (!matching) {
        throw new Error(
          'Responder does not have the required resource available',
        );
      }
    }

    // ----------------------------------------------------
    // ACCEPT REQUEST
    // ----------------------------------------------------
    const updatedRequest =
      await tx.emergencyRequest.update({
        where: {
          id: Number(requestId),
        },
        data: {
          status: 'ACCEPTED',
          acceptedById: Number(responderId),
          acceptedAt: new Date(),
        },
        include: {
          requiredResources: true,
        },
      });

    // Responder becomes BUSY
    await tx.user.update({
      where: {
        id: Number(responderId),
      },
      data: {
        responderStatus: 'BUSY',
        lastActiveAt: new Date(),
      },
    });

    return updatedRequest;
  });
};

exports.updateRequestStatus = async (requestId, status) => {
  // Can add state machine rules here
  return await prisma.emergencyRequest.update({
    where: { id: Number(requestId) },
    data: { status }
  });
};