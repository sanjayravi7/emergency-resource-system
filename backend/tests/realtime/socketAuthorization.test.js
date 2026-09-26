process.env.DATABASE_URL = process.env.DATABASE_URL || 'postgresql://socket-test/socket';
process.env.JWT_SECRET = process.env.JWT_SECRET || 'socket-test-secret';

jest.mock('../../src/config/prisma', () => ({
  user: { findUnique: jest.fn() },
  emergencyRequest: { findUnique: jest.fn(), findFirst: jest.fn() },
}));

const prisma = require('../../src/config/prisma');
const {
  canSubscribe,
  requestForResponder,
  responderParticipationWhere,
} = require('../../src/realtime/socketServer');

const user = (id, role) => ({
  id,
  name: `User ${id}`,
  role,
  isActive: true,
  responderStatus: role === 'RESPONDER' ? 'AVAILABLE' : 'OFFLINE',
});

beforeEach(() => jest.clearAllMocks());

describe('Socket room and location authorization', () => {
  test('a requester can subscribe only to their own emergency', async () => {
    prisma.user.findUnique.mockResolvedValue(user(10, 'REQUESTER'));
    prisma.emergencyRequest.findUnique.mockResolvedValue({
      requesterId: 10,
    });

    const socket = { user: user(10, 'REQUESTER') };
    await expect(canSubscribe(socket, 55)).resolves.toBe(true);

    prisma.emergencyRequest.findUnique.mockResolvedValue({
      requesterId: 99,
    });
    await expect(canSubscribe(socket, 56)).resolves.toBe(false);
  });

  test('a responder can subscribe only to an emergency they participate in (assignment, allocation, or legacy lead)', async () => {
    prisma.user.findUnique.mockResolvedValue(user(20, 'RESPONDER'));
    const socket = { user: user(20, 'RESPONDER') };

    // The database decides participation; a hit authorizes the subscription.
    prisma.emergencyRequest.findFirst.mockResolvedValue({ id: 55 });
    await expect(canSubscribe(socket, 55)).resolves.toBe(true);

    // The participation query is assignment-aware (Part 3): exactly the
    // ACTIVE-assignment / unfinished-allocation / legacy-lead OR legs, with
    // no terminal-status restriction (responders keep read access to
    // requests they worked on).
    const where = prisma.emergencyRequest.findFirst.mock.calls[0][0].where;
    expect(where.id).toBe(55);
    expect(where.status).toBeUndefined();
    expect(where.OR).toEqual([
      { assignments: { some: { responderId: 20, status: 'ACTIVE' } } },
      {
        allocations: {
          some: { responderId: 20, status: { in: ['RESERVED', 'DISPATCHED'] } },
        },
      },
      {
        acceptedById: 20,
        assignments: { none: { responderId: 20 } },
      },
    ]);

    // A responder the database does not list as a participant is denied.
    prisma.emergencyRequest.findFirst.mockResolvedValue(null);
    await expect(canSubscribe(socket, 57)).resolves.toBe(false);

    // acceptedById pointing at a DIFFERENT responder never authorizes: it
    // only ever appears inside the responder's own legacy leg above.
    const legacyLeg = where.OR[2];
    expect(legacyLeg.acceptedById).toBe(20);
  });

  test('participation legs: an ENDED assignment pair is authoritative and blocks the legacy lead fallback', async () => {
    // The where-builder encodes the Phase C compatibility rule: once a pair
    // has any assignment row (ACTIVE or ENDED), the table alone decides for
    // that pair, so acceptedById can no longer re-authorize it.
    const legs = responderParticipationWhere(20).OR;
    expect(legs[0]).toEqual({
      assignments: { some: { responderId: 20, status: 'ACTIVE' } },
    });
    expect(legs[2]).toEqual({
      acceptedById: 20,
      assignments: { none: { responderId: 20 } },
    });
  });

  test('location authorization requires the authenticated responder assignment and an active emergency', async () => {
    prisma.emergencyRequest.findFirst.mockResolvedValue({
      id: 55,
      requesterId: 10,
      acceptedById: 20,
      status: 'IN_PROGRESS',
    });

    await expect(requestForResponder(55, 20)).resolves.toEqual(
      expect.objectContaining({ id: 55 })
    );

    // Live location requires an ACTIVE (non-terminal) emergency.
    const where = prisma.emergencyRequest.findFirst.mock.calls[0][0].where;
    expect(where.status).toEqual({ notIn: ['COMPLETED', 'CANCELLED'] });
    expect(where.OR).toHaveLength(3);

    prisma.emergencyRequest.findFirst.mockResolvedValue(null);
    await expect(requestForResponder(55, 21)).resolves.toBeNull();
  });

  test('an inactive database user invalidates an already-connected socket before protected actions', async () => {
    prisma.user.findUnique.mockResolvedValue({
      ...user(20, 'RESPONDER'),
      isActive: false,
    });

    const socket = {
      user: user(20, 'RESPONDER'),
      emit: jest.fn(),
      disconnect: jest.fn(),
      data: {},
    };

    await expect(canSubscribe(socket, 55)).resolves.toBe(false);
    expect(socket.emit).toHaveBeenCalledWith(
      'socket.invalidated',
      expect.objectContaining({ code: 'USER_INACTIVE' })
    );
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(socket.disconnect).toHaveBeenCalledWith(true);
    expect(prisma.emergencyRequest.findFirst).not.toHaveBeenCalled();
    expect(prisma.emergencyRequest.findUnique).not.toHaveBeenCalled();
  });
});
