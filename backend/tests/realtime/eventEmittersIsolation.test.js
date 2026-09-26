jest.mock('../../src/config/prisma', () => ({
  emergencyRequest: { findUnique: jest.fn() },
  allocation: { findUnique: jest.fn(), findMany: jest.fn() },
  user: { findUnique: jest.fn() },
}));

jest.mock('../../src/realtime/socketEvents', () => ({
  emitToRooms: jest.fn(() => true),
  getIO: jest.fn(() => ({})),
  rooms: {
    user: (id) => `user:${Number(id)}`,
    request: (id) => `request:${Number(id)}`,
    responders: 'responders',
    admins: 'admins',
  },
}));

const prisma = require('../../src/config/prisma');
const socketEvents = require('../../src/realtime/socketEvents');
const {
  emitAllocationUpdated,
  emitRequestUpdated,
} = require('../../src/realtime/eventEmitters');

function requestSnapshot() {
  return {
    id: 55,
    requesterId: 10,
    emergencyType: 'Medical',
    description: 'Isolation test',
    location: 'Old Town',
    latitude: 10.5,
    longitude: 76.2,
    priority: 'HIGH',
    status: 'ACCEPTED',
    acceptedById: 20,
    acceptedAt: new Date('2026-09-26T10:00:00.000Z'),
    createdAt: new Date('2026-09-26T09:55:00.000Z'),
    updatedAt: new Date('2026-09-26T10:00:00.000Z'),
    requester: {
      id: 10,
      name: 'Requester',
      email: 'requester@test.com',
      phone: '555-0100',
    },
    acceptedBy: {
      id: 20,
      name: 'Responder',
      phone: '555-0200',
      responderStatus: 'BUSY',
      location: 'Old Town',
      latitude: 10.6,
      longitude: 76.3,
      lastActiveAt: new Date('2026-09-26T10:00:00.000Z'),
    },
    requiredResources: [],
    allocations: [],
  };
}

beforeEach(() => jest.clearAllMocks());

describe('Realtime outbound room isolation', () => {
  test('full request snapshots never go to the global responder room', async () => {
    prisma.emergencyRequest.findUnique.mockResolvedValue(requestSnapshot());

    await emitRequestUpdated(55);

    const fullEmission = socketEvents.emitToRooms.mock.calls.find(
      ([event, payload]) => event === 'request.updated' && payload.request
    );
    const redactedEmission = socketEvents.emitToRooms.mock.calls.find(
      ([event, payload]) => event === 'request.updated' && !payload.request
    );

    expect(fullEmission[2]).toEqual(
      expect.arrayContaining(['request:55', 'user:10', 'user:20', 'admins'])
    );
    expect(fullEmission[2]).not.toContain('responders');
    expect(redactedEmission[1]).toEqual({
      requestId: 55,
      status: 'ACCEPTED',
      available: false,
      updatedAt: new Date('2026-09-26T10:00:00.000Z'),
    });
    expect(redactedEmission[2]).toEqual(['responders']);
  });

  test('allocation snapshots are isolated from unassigned responders', async () => {
    const request = requestSnapshot();
    const allocation = {
      id: 91,
      requestId: 55,
      resourceId: 4,
      responderId: 20,
      responderResourceId: 7,
      quantity: 1,
      status: 'DISPATCHED',
      allocatedAt: new Date('2026-09-26T10:01:00.000Z'),
      updatedAt: new Date('2026-09-26T10:02:00.000Z'),
      resource: { id: 4, name: 'Ambulance', type: 'MEDICAL' },
      responder: { id: 20, name: 'Responder' },
    };
    prisma.allocation.findUnique.mockResolvedValue(allocation);
    prisma.emergencyRequest.findUnique.mockResolvedValue(request);

    await emitAllocationUpdated(91);

    const allocationEmission = socketEvents.emitToRooms.mock.calls.find(
      ([event]) => event === 'allocation.updated'
    );
    expect(allocationEmission[2]).toEqual(
      expect.arrayContaining(['request:55', 'user:10', 'user:20', 'admins'])
    );
    expect(allocationEmission[2]).not.toContain('responders');
  });
});
