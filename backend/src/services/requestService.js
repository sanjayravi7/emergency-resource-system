const prisma = require('../config/prisma');

const {
  validateEmergencyRequestInput,
  normalizeRequiredResources,
} = require('../validators/requestValidator');

// ------------------------------------------------------------------
// Shared include shape.
//
// Every request returned to Flutter carries:
//  - the requester (id, name, email, phone)
//  - the assigned responder (once accepted)
//  - the required resources WITH the resource catalog row
//  - the allocations made against the request
// ------------------------------------------------------------------
const requesterSelect = {
  id: true,
  name: true,
  email: true,
  phone: true,
};

const responderSelect = {
  id: true,
  name: true,
  email: true,
  phone: true,
  responderStatus: true,
  location: true,
};

const requestInclude = {
  requiredResources: {
    include: {
      resource: true,
    },
  },
  requester: {
    select: requesterSelect,
  },
  acceptedBy: {
    select: responderSelect,
  },
  allocations: {
    include: {
      resource: {
        select: {
          id: true,
          name: true,
          type: true,
          unit: true,
        },
      },
      responder: {
        select: {
          id: true,
          name: true,
          phone: true,
        },
      },
    },
  },
};

exports.requestInclude = requestInclude;

// ------------------------------------------------------------------
// CREATE
//
// Backend is the final authority:
//  - the requester must be authenticated (route level)
//  - resource ids must exist in PostgreSQL
//  - resources must be ACTIVE
//  - quantities must be positive whole numbers
//  - quantity cannot exceed the catalog availability
// ------------------------------------------------------------------
exports.createEmergencyRequest = async (userId, data) => {
  const validationError = validateEmergencyRequestInput(data);

  if (validationError) {
    throw new Error(validationError);
  }

  const requiredResources = normalizeRequiredResources(data.requiredResources);

  const resourceIds = requiredResources.map((r) => r.resourceId);

  const resources = await prisma.resource.findMany({
    where: {
      id: {
        in: resourceIds,
      },
    },
  });

  const resourceById = new Map(resources.map((r) => [r.id, r]));

  for (const required of requiredResources) {
    const resource = resourceById.get(required.resourceId);

    if (!resource) {
      throw new Error(`Resource ${required.resourceId} does not exist`);
    }

    if (resource.isActive === false) {
      throw new Error(`Resource "${resource.name}" is not active`);
    }

    if (resource.availableQuantity <= 0) {
      throw new Error(`Resource "${resource.name}" is out of stock`);
    }

    if (required.quantity > resource.availableQuantity) {
      throw new Error(
        `Only ${resource.availableQuantity} of "${resource.name}" are currently available`
      );
    }
  }

  return await prisma.emergencyRequest.create({
    data: {
      emergencyType: String(data.emergencyType).trim(),
      description: String(data.description).trim(),
      location: String(data.location).trim(),
      latitude: typeof data.latitude === 'number' ? data.latitude : null,
      longitude: typeof data.longitude === 'number' ? data.longitude : null,
      priority: data.priority ? String(data.priority) : 'MEDIUM',
      requesterId: userId,
      requiredResources: {
        create: requiredResources.map((r) => ({
          resourceId: r.resourceId,
          quantity: r.quantity,
        })),
      },
    },
    include: requestInclude,
  });
};

// ------------------------------------------------------------------
// READ
// ------------------------------------------------------------------
exports.getRequestsByUser = async (userId) => {
  return await prisma.emergencyRequest.findMany({
    where: { requesterId: Number(userId) },
    include: requestInclude,
    orderBy: { createdAt: 'desc' },
  });
};

exports.getRequestById = async (id) => {
  const request = await prisma.emergencyRequest.findUnique({
    where: { id: Number(id) },
    include: requestInclude,
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
    include: requestInclude,
    orderBy: { createdAt: 'desc' },
  });
};

/**
 * Requests this responder has accepted (their own workload).
 * Used by the dispatch board after acceptance, because an accepted
 * request correctly disappears from the compatible PENDING list.
 */
exports.getAssignedRequestsForResponder = async (responderId) => {
  return await prisma.emergencyRequest.findMany({
    where: {
      acceptedById: Number(responderId),
    },
    include: requestInclude,
    orderBy: { createdAt: 'desc' },
  });
};

exports.getCompatibleRequestsForResponder = async (responderId) => {
  // ----------------------------------------------------
  // RULE: responder must be an active, available RESPONDER
  // ----------------------------------------------------
  const responder = await prisma.user.findUnique({
    where: {
      id: Number(responderId),
    },
    select: {
      id: true,
      role: true,
      isActive: true,
      responderStatus: true,
    },
  });

  if (
    !responder ||
    responder.role !== 'RESPONDER' ||
    !responder.isActive ||
    responder.responderStatus !== 'AVAILABLE'
  ) {
    return [];
  }

  // ----------------------------------------------------
  // RULE: one active emergency per responder
  // ----------------------------------------------------
  const activeEmergency = await prisma.emergencyRequest.findFirst({
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
    return [];
  }

  // ----------------------------------------------------
  // RULE: responder must have available matching resources
  // ----------------------------------------------------
  const responderResources = await prisma.responderResource.findMany({
    where: {
      responderId: Number(responderId),
      status: 'AVAILABLE',
      availableQuantity: {
        gt: 0,
      },
    },
  });

  const requests = await prisma.emergencyRequest.findMany({
    where: {
      status: 'PENDING',
    },
    include: requestInclude,
    orderBy: [
      { priority: 'desc' },
      { createdAt: 'asc' },
    ],
  });

  return requests.filter((request) => {
    if (!request.requiredResources.length) {
      return false;
    }

    return request.requiredResources.every((required) => {
      const matchingResource = responderResources.find(
        (resource) =>
          resource.resourceId === required.resourceId &&
          resource.availableQuantity >= required.quantity,
      );

      return !!matchingResource;
    });
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
