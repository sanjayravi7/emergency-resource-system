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
      acceptedById: 20,
    });

    const socket = { user: user(10, 'REQUESTER') };
    await expect(canSubscribe(socket, 55)).resolves.toBe(true);

    prisma.emergencyRequest.findUnique.mockResolvedValue({
      requesterId: 99,
      acceptedById: 20,
    });
    await expect(canSubscribe(socket, 56)).resolves.toBe(false);
  });

  test('a responder can subscribe only to an emergency assigned to them', async () => {
    prisma.user.findUnique.mockResolvedValue(user(20, 'RESPONDER'));
    prisma.emergencyRequest.findUnique.mockResolvedValue({
      requesterId: 10,
      acceptedById: 20,
    });

    const socket = { user: user(20, 'RESPONDER') };
    await expect(canSubscribe(socket, 55)).resolves.toBe(true);

    prisma.emergencyRequest.findUnique.mockResolvedValue({
      requesterId: 10,
      acceptedById: 21,
    });
    await expect(canSubscribe(socket, 57)).resolves.toBe(false);
  });

  test('location authorization requires the authenticated responder assignment and an active emergency', async () => {
    prisma.emergencyRequest.findFirst.mockResolvedValue({
      id: 55,
      requesterId: 10,
      acceptedById: 20,
      status: 'IN_PROGRESS',
    });

    await expect(requestForResponder(55, 20)).resolves.toEqual(
      expect.objectContaining({ id: 55, acceptedById: 20 })
    );

    prisma.emergencyRequest.findFirst.mockResolvedValue(null);
    await expect(requestForResponder(55, 21)).resolves.toBeNull();
  });
});
