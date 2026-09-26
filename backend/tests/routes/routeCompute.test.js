/**
 * POST /api/routes/compute — Google Routes API (Compute Routes) proxy.
 *
 * These tests never reach Google: `global.fetch` is mocked, so they assert the
 * exact upstream contract (URL, headers, field mask, request body) and the
 * exact response contract returned to Flutter Web.
 *
 * Prisma is mocked the same way the realtime tests do it, so the suite runs
 * without a database or a generated Prisma client.
 */

const jwt = require('jsonwebtoken');

jest.mock('../../src/config/prisma', () => ({
  user: {
    findUnique: jest.fn(),
  },
}));

process.env.DATABASE_URL =
  process.env.DATABASE_URL || 'postgresql://routes-test/routes';
process.env.JWT_SECRET = process.env.JWT_SECRET || 'routes-test-secret';
// A fake server key: the tests assert it never leaves the backend.
process.env.GOOGLE_ROUTES_API_KEY = 'AIzaTESTSERVERROUTESKEY0000000000000000';

const request = require('supertest');
const app = require('../../src/app');
const prisma = require('../../src/config/prisma');
const env = require('../../src/config/env');
const routesService = require('../../src/services/routesService');

const SERVER_KEY = env.GOOGLE_ROUTES_API_KEY;

const RESPONDER_ORIGIN = { latitude: 10.00846, longitude: 76.45163 };
const EMERGENCY_DESTINATION = { latitude: 10.05276, longitude: 76.35211 };

/** A realistic Compute Routes reply for the requested field mask. */
const GOOGLE_ROUTE_RESPONSE = {
  routes: [
    {
      distanceMeters: 7412,
      duration: '1080s',
      polyline: {
        encodedPolyline: 'ipkcFfichVnP@j@BLoFVwM{E?',
      },
    },
  ],
};

function authToken(overrides = {}) {
  return jwt.sign(
    { userId: 21, role: 'REQUESTER', ...overrides },
    process.env.JWT_SECRET,
    { expiresIn: '1h' }
  );
}

function mockGoogleResponse(body, { ok = true, status = 200 } = {}) {
  const fetchMock = jest.fn().mockResolvedValue({
    ok,
    status,
    json: async () => body,
  });
  global.fetch = fetchMock;
  return fetchMock;
}

function postRoute(body, { token = authToken() } = {}) {
  const call = request(app).post('/api/routes/compute');
  if (token) call.set('Authorization', `Bearer ${token}`);
  return call.send(body);
}

const validBody = {
  origin: RESPONDER_ORIGIN,
  destination: EMERGENCY_DESTINATION,
};

describe('POST /api/routes/compute (Google Routes API Compute Routes)', () => {
  const originalFetch = global.fetch;

  beforeEach(() => {
    prisma.user.findUnique.mockResolvedValue({ id: 21, isActive: true });
  });

  afterEach(() => {
    global.fetch = originalFetch;
  });

  // 1 -------------------------------------------------------------------
  test('✅ a valid route request calls the Routes API and handles the response', async () => {
    const fetchMock = mockGoogleResponse(GOOGLE_ROUTE_RESPONSE);

    const response = await postRoute(validBody);

    expect(response.status).toBe(200);
    expect(response.body.success).toBe(true);
    expect(fetchMock).toHaveBeenCalledTimes(1);

    const [url, init] = fetchMock.mock.calls[0];
    expect(url).toBe('https://routes.googleapis.com/directions/v2:computeRoutes');
    expect(init.method).toBe('POST');
    expect(init.headers['X-Goog-Api-Key']).toBe(SERVER_KEY);
    expect(init.headers['X-Goog-FieldMask']).toBe(
      'routes.duration,routes.distanceMeters,routes.polyline.encodedPolyline'
    );

    const sent = JSON.parse(init.body);
    expect(sent.origin.location.latLng).toEqual(RESPONDER_ORIGIN);
    expect(sent.destination.location.latLng).toEqual(EMERGENCY_DESTINATION);
    expect(sent.travelMode).toBe('DRIVE');
    expect(sent.routingPreference).toBe('TRAFFIC_AWARE');
    expect(sent.computeAlternativeRoutes).toBe(false);
    expect(sent.units).toBe('METRIC');
  });

  // 2 -------------------------------------------------------------------
  test('❌ a missing origin is rejected before any Google request', async () => {
    const fetchMock = mockGoogleResponse(GOOGLE_ROUTE_RESPONSE);

    const response = await postRoute({ destination: EMERGENCY_DESTINATION });

    expect(response.status).toBe(400);
    expect(response.body.success).toBe(false);
    expect(response.body.message).toMatch(/origin/i);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  // 3 -------------------------------------------------------------------
  test('❌ a missing destination is rejected before any Google request', async () => {
    const fetchMock = mockGoogleResponse(GOOGLE_ROUTE_RESPONSE);

    const response = await postRoute({ origin: RESPONDER_ORIGIN });

    expect(response.status).toBe(400);
    expect(response.body.success).toBe(false);
    expect(response.body.message).toMatch(/destination/i);
    expect(fetchMock).not.toHaveBeenCalled();
  });

  // 4 -------------------------------------------------------------------
  test('❌ invalid coordinates are rejected (out of range, NaN, wrong type, half a pair)', async () => {
    const fetchMock = mockGoogleResponse(GOOGLE_ROUTE_RESPONSE);

    const invalidBodies = [
      { origin: { latitude: 120, longitude: 76.45 }, destination: EMERGENCY_DESTINATION },
      { origin: { latitude: 10.0, longitude: 220 }, destination: EMERGENCY_DESTINATION },
      { origin: RESPONDER_ORIGIN, destination: { latitude: -91, longitude: 76.35 } },
      { origin: { latitude: '10.0', longitude: 76.45 }, destination: EMERGENCY_DESTINATION },
      { origin: { latitude: 10.0 }, destination: EMERGENCY_DESTINATION },
      { origin: RESPONDER_ORIGIN, destination: { longitude: 76.35 } },
    ];

    for (const body of invalidBodies) {
      const response = await postRoute(body);
      expect(response.status).toBe(400);
      expect(response.body.success).toBe(false);
      expect(typeof response.body.message).toBe('string');
    }

    expect(fetchMock).not.toHaveBeenCalled();
  });

  // 5 -------------------------------------------------------------------
  test('✅ the Google distance is mapped correctly', async () => {
    mockGoogleResponse(GOOGLE_ROUTE_RESPONSE);

    const response = await postRoute(validBody);

    expect(response.status).toBe(200);
    expect(response.body.data.distanceMeters).toBe(7412);
    // Optional localized readout, derived from Google's own metres.
    expect(response.body.data.distanceText).toBe('7.4 km');
  });

  // 6 -------------------------------------------------------------------
  test('✅ the Google duration is mapped correctly (no distance/speed estimate)', async () => {
    mockGoogleResponse(GOOGLE_ROUTE_RESPONSE);

    const response = await postRoute(validBody);

    expect(response.status).toBe(200);
    expect(response.body.data.duration).toBe('1080s');
    expect(response.body.data.durationSeconds).toBe(1080);
    expect(response.body.data.durationText).toBe('18 min');
  });

  // 7 -------------------------------------------------------------------
  test('✅ the encoded polyline is returned unchanged', async () => {
    mockGoogleResponse(GOOGLE_ROUTE_RESPONSE);

    const response = await postRoute(validBody);

    expect(response.status).toBe(200);
    expect(response.body.data.encodedPolyline).toBe('ipkcFfichVnP@j@BLoFVwM{E?');
  });

  // 8 -------------------------------------------------------------------
  describe('upstream failures are handled gracefully', () => {
    test('❌ a Google error response becomes a 502 with a safe message', async () => {
      mockGoogleResponse(
        {
          error: {
            code: 403,
            message: 'Routes API has not been used in project 1234 before or it is disabled.',
            status: 'PERMISSION_DENIED',
          },
        },
        { ok: false, status: 403 }
      );

      const response = await postRoute(validBody);

      expect(response.status).toBe(502);
      expect(response.body.success).toBe(false);
      expect(response.body.code).toBe('ROUTES_UPSTREAM_ERROR');
      expect(response.body.message).toMatch(/Routes API/i);
    });

    test('❌ a network failure becomes a 502 instead of crashing the request', async () => {
      global.fetch = jest.fn().mockRejectedValue(new Error('socket hang up'));

      const response = await postRoute(validBody);

      expect(response.status).toBe(502);
      expect(response.body.success).toBe(false);
      expect(response.body.code).toBe('ROUTES_UNREACHABLE');
    });

    test('❌ an empty Google routes array becomes a 404 route-not-found', async () => {
      mockGoogleResponse({ routes: [] });

      const response = await postRoute(validBody);

      expect(response.status).toBe(404);
      expect(response.body.success).toBe(false);
      expect(response.body.code).toBe('ROUTE_NOT_FOUND');
    });
  });

  // 9 -------------------------------------------------------------------
  describe('authentication is mandatory', () => {
    test('❌ an unauthenticated route request is rejected', async () => {
      const fetchMock = mockGoogleResponse(GOOGLE_ROUTE_RESPONSE);

      const response = await postRoute(validBody, { token: null });

      expect(response.status).toBe(401);
      expect(response.body.success).toBe(false);
      expect(fetchMock).not.toHaveBeenCalled();
    });

    test('❌ an invalid token is rejected before Google is called', async () => {
      const fetchMock = mockGoogleResponse(GOOGLE_ROUTE_RESPONSE);

      const response = await postRoute(validBody, { token: 'not-a-real-token' });

      expect(response.status).toBe(401);
      expect(fetchMock).not.toHaveBeenCalled();
    });
  });

  // 10 ------------------------------------------------------------------
  describe('the server API key never leaves the backend', () => {
    test('✅ a successful response contains no key material', async () => {
      mockGoogleResponse(GOOGLE_ROUTE_RESPONSE);

      const response = await postRoute(validBody);
      const serialized = JSON.stringify(response.body) + JSON.stringify(response.headers);

      expect(response.status).toBe(200);
      expect(serialized).not.toContain(SERVER_KEY);
      expect(serialized).not.toMatch(/AIza/);
      expect(Object.keys(response.body.data).sort()).toEqual(
        [
          'distanceMeters',
          'distanceText',
          'duration',
          'durationSeconds',
          'durationText',
          'encodedPolyline',
        ].sort()
      );
    });

    test('✅ an upstream error that echoes the key is redacted', async () => {
      mockGoogleResponse(
        {
          error: {
            message: `API key not valid: ${SERVER_KEY} (request: ...?key=${SERVER_KEY})`,
          },
        },
        { ok: false, status: 400 }
      );

      const response = await postRoute(validBody);

      expect(response.status).toBe(502);
      expect(response.body.message).not.toContain(SERVER_KEY);
      expect(response.body.message).not.toMatch(/AIza/);
      expect(response.body.message).toContain('[REDACTED]');
    });

    test('✅ redactApiKey strips keys from arbitrary text', () => {
      expect(routesService.redactApiKey(`key=${SERVER_KEY}&x=1`)).not.toContain(
        SERVER_KEY
      );
      expect(routesService.redactApiKey(null)).toBe('');
    });
  });

  // Extra safety net: the service refuses to run without a configured key.
  test('❌ a missing GOOGLE_ROUTES_API_KEY returns 503 and never calls Google', async () => {
    const fetchMock = mockGoogleResponse(GOOGLE_ROUTE_RESPONSE);
    const configuredKey = env.GOOGLE_ROUTES_API_KEY;
    env.GOOGLE_ROUTES_API_KEY = '';

    try {
      const response = await postRoute(validBody);

      expect(response.status).toBe(503);
      expect(response.body.code).toBe('ROUTES_NOT_CONFIGURED');
      expect(fetchMock).not.toHaveBeenCalled();
    } finally {
      env.GOOGLE_ROUTES_API_KEY = configuredKey;
    }
  });
});
