const jwt = require('jsonwebtoken');

jest.mock('../../src/config/prisma', () => ({
  user: {
    findUnique: jest.fn(),
  },
}));

process.env.DATABASE_URL = process.env.DATABASE_URL || 'postgresql://socket-test/socket';
process.env.JWT_SECRET = process.env.JWT_SECRET || 'socket-test-secret';

const prisma = require('../../src/config/prisma');
const { authenticateSocket } = require('../../src/realtime/socketAuth');

function socketWithAuth(token) {
  return {
    handshake: {
      auth: token ? { token } : {},
      headers: {},
    },
  };
}

describe('Socket JWT authentication', () => {
  beforeEach(() => jest.clearAllMocks());

  test('rejects a missing or invalid JWT', async () => {
    const next = jest.fn();
    await authenticateSocket(socketWithAuth('not-a-token'), next);

    expect(next).toHaveBeenCalledTimes(1);
    expect(next.mock.calls[0][0]).toBeInstanceOf(Error);
    expect(prisma.user.findUnique).not.toHaveBeenCalled();
  });

  test('derives the current role from the authenticated database identity', async () => {
    const token = jwt.sign(
      { userId: 42, role: 'REQUESTER' },
      process.env.JWT_SECRET,
      { expiresIn: '1h' }
    );
    prisma.user.findUnique.mockResolvedValue({
      id: 42,
      name: 'Responder 42',
      role: 'RESPONDER',
      isActive: true,
      responderStatus: 'AVAILABLE',
    });

    const socket = socketWithAuth(token);
    const next = jest.fn();
    await authenticateSocket(socket, next);

    expect(next).toHaveBeenCalledWith();
    expect(socket.user).toEqual({
      id: 42,
      name: 'Responder 42',
      role: 'RESPONDER',
      responderStatus: 'AVAILABLE',
    });
  });

  test('rejects an inactive database identity even with a valid JWT', async () => {
    const token = jwt.sign({ userId: 7, role: 'RESPONDER' }, process.env.JWT_SECRET);
    prisma.user.findUnique.mockResolvedValue({
      id: 7,
      name: 'Inactive responder',
      role: 'RESPONDER',
      isActive: false,
      responderStatus: 'OFFLINE',
    });

    const next = jest.fn();
    await authenticateSocket(socketWithAuth(token), next);

    expect(next.mock.calls[0][0]).toEqual(expect.any(Error));
    expect(next.mock.calls[0][0].message).toContain('inactive');
  });
});
