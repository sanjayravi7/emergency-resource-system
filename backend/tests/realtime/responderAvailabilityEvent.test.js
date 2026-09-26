process.env.DATABASE_URL = process.env.DATABASE_URL || 'postgresql://socket-test/socket';
process.env.JWT_SECRET = process.env.JWT_SECRET || 'socket-test-secret';

jest.mock('../../src/config/prisma', () => ({
  user: { findUnique: jest.fn() },
  allocation: { count: jest.fn() },
  emergencyRequest: { count: jest.fn() },
}));

jest.mock('../../src/realtime/socketEvents', () => {
  const rooms = {
    user: (userId) => `user:${Number(userId)}`,
    request: (requestId) => `request:${Number(requestId)}`,
    responders: 'responders',
    admins: 'admins',
  };
  return {
    rooms,
    emitToRooms: jest.fn(),
    emitToRoom: jest.fn(),
    getIO: jest.fn(),
  };
});

const prisma = require('../../src/config/prisma');
const { emitToRooms, getIO, rooms } = require('../../src/realtime/socketEvents');
const { emitResponderAvailability } = require('../../src/realtime/eventEmitters');

function fakeIO() {
  const emitted = [];
  const chain = {
    rooms: [],
    excluded: [],
    to(room) {
      this.rooms.push(room);
      return this;
    },
    except(room) {
      this.excluded.push(room);
      return this;
    },
    emit(eventName, payload) {
      emitted.push({
        eventName,
        payload,
        rooms: [...this.rooms],
        excluded: [...this.excluded],
      });
      this.rooms = [];
      this.excluded = [];
      return true;
    },
  };
  return { io: chain, emitted };
}

beforeEach(() => jest.clearAllMocks());

describe('responder.availability payload', () => {
  test('carries the PostgreSQL workload counts for the responder and admins', async () => {
    prisma.user.findUnique.mockResolvedValue({ id: 7, responderStatus: 'BUSY' });
    prisma.allocation.count
      .mockResolvedValueOnce(1) // RESERVED
      .mockResolvedValueOnce(1); // DISPATCHED
    prisma.emergencyRequest.count.mockResolvedValue(1);

    const { io } = fakeIO();
    getIO.mockReturnValue(io);

    await emitResponderAvailability(7);

    expect(emitToRooms).toHaveBeenCalledTimes(1);
    const [eventName, payload, targetRooms] = emitToRooms.mock.calls[0];

    expect(eventName).toBe('responder.availability');
    expect(payload).toMatchObject({
      responderId: 7,
      responderStatus: 'BUSY',
      currentResponderStatus: 'BUSY',
      reservedAllocations: 1,
      dispatchedAllocations: 1,
      unfinishedAllocations: 2,
      activeRequests: 1,
    });
    expect(targetRooms).toEqual([rooms.user(7), rooms.admins]);
  });

  test('other responders receive the status only, never the workload detail', async () => {
    prisma.user.findUnique.mockResolvedValue({ id: 7, responderStatus: 'BUSY' });
    prisma.allocation.count.mockResolvedValue(2);
    prisma.emergencyRequest.count.mockResolvedValue(1);

    const { io, emitted } = fakeIO();
    getIO.mockReturnValue(io);

    await emitResponderAvailability(7);

    expect(emitted).toHaveLength(1);
    const broadcast = emitted[0];

    expect(broadcast.eventName).toBe('responder.availability');
    expect(broadcast.rooms).toEqual([rooms.responders]);
    expect(broadcast.excluded).toEqual([rooms.user(7)]);
    expect(broadcast.payload).toEqual({
      responderId: 7,
      responderStatus: 'BUSY',
      currentResponderStatus: 'BUSY',
      timestamp: expect.any(String),
    });
    expect(broadcast.payload.unfinishedAllocations).toBeUndefined();
  });

  test('does nothing when the responder no longer exists', async () => {
    prisma.user.findUnique.mockResolvedValue(null);
    const { io, emitted } = fakeIO();
    getIO.mockReturnValue(io);

    await emitResponderAvailability(404);

    expect(emitToRooms).not.toHaveBeenCalled();
    expect(emitted).toHaveLength(0);
  });
});
