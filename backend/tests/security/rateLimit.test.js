/**
 * Phase I, Part 4: rate limiting.
 *
 * Verifies the credential limiter actually blocks after the configured budget,
 * and that GPS-sensitive responder paths are exempt from the general limiter.
 * The limiter module reads its config at import time, so each scenario is loaded
 * in isolation with forced env values.
 */

const express = require('express');
const request = require('supertest');

function loadLimiters(overrides) {
  let mod;
  jest.isolateModules(() => {
    const saved = { ...process.env };
    Object.assign(process.env, {
      DATABASE_URL: 'postgresql://u:p@localhost:5432/db',
      JWT_SECRET: 'S6m2yq0m9k3wq7Zt1v8Xr4Lp6Nc2Bd5Hf8Jk1Mn4Qs7Uw0',
      ...overrides,
    });
    try {
      mod = require('../../src/middleware/rateLimiters');
    } finally {
      for (const key of Object.keys(process.env)) {
        if (!(key in saved)) delete process.env[key];
      }
      Object.assign(process.env, saved);
    }
  });
  return mod;
}

describe('rate limiting', () => {
  test('auth limiter returns 429 after the budget is exceeded', async () => {
    const { authLimiter } = loadLimiters({
      RATE_LIMIT_ENABLED: 'true',
      AUTH_RATE_MAX: '2',
      AUTH_RATE_WINDOW_MS: '60000',
    });

    const app = express();
    app.use(express.json());
    app.post('/api/auth/login', authLimiter, (req, res) => res.json({ ok: true }));

    const hit = () => request(app).post('/api/auth/login').send({});
    expect((await hit()).status).toBe(200);
    expect((await hit()).status).toBe(200);
    const blocked = await hit();
    expect(blocked.status).toBe(429);
    expect(blocked.body.message).toMatch(/too many/i);
  });

  test('general limiter skips GPS-sensitive responder paths', async () => {
    const { apiLimiter } = loadLimiters({
      RATE_LIMIT_ENABLED: 'true',
      API_RATE_MAX: '1',
      API_RATE_WINDOW_MS: '60000',
    });

    const app = express();
    app.use(express.json());
    app.use('/api', apiLimiter);
    app.post('/api/responders/location', (req, res) => res.json({ ok: true }));
    app.get('/api/requests', (req, res) => res.json({ ok: true }));

    // Location updates are never throttled by the general limiter.
    for (let i = 0; i < 5; i += 1) {
      // eslint-disable-next-line no-await-in-loop
      const res = await request(app).post('/api/responders/location').send({});
      expect(res.status).toBe(200);
    }

    // A non-exempt path is limited after the (tiny) budget.
    expect((await request(app).get('/api/requests')).status).toBe(200);
    expect((await request(app).get('/api/requests')).status).toBe(429);
  });

  test('limiter is disabled under NODE_ENV=test by default', async () => {
    const { authLimiter } = loadLimiters({ NODE_ENV: 'test', AUTH_RATE_MAX: '1' });
    const app = express();
    app.post('/api/auth/login', authLimiter, (req, res) => res.json({ ok: true }));
    for (let i = 0; i < 5; i += 1) {
      // eslint-disable-next-line no-await-in-loop
      expect((await request(app).post('/api/auth/login').send({})).status).toBe(200);
    }
  });
});
