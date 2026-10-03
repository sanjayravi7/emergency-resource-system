const express = require('express');
const cors = require('cors');
const helmet = require('helmet');

const env = require('./config/env');
const emailService = require('./services/emailService');
const authRoutes = require('./routes/authRoutes');
const requestRoutes = require('./routes/requestRoutes');
const resourceRoutes = require('./routes/resourceRoutes');
const responderRoutes = require('./routes/responderRoutes');
const allocationRoutes = require('./routes/allocationRoutes');
const responderResourceRoutes = require('./routes/responderResourceRoutes');
const adminRoutes = require('./routes/adminRoutes');
const userRoutes = require('./routes/userRoutes');
const locationRoutes = require('./routes/locationRoutes');
const errorMiddleware = require('./middleware/errorMiddleware');
const { securityHeaders } = require('./middleware/securityHeaders');
const { authLimiter, apiLimiter } = require('./middleware/rateLimiters');

const app = express();

// Trust the reverse proxy / load balancer in production so express-rate-limit
// and req.ip see the real client address, not the proxy hop. Configurable via
// TRUST_PROXY; defaults to a single hop in production, off in local dev.
app.set('trust proxy', env.TRUST_PROXY);

// Never advertise the framework. Helmet also removes this, kept explicit.
app.disable('x-powered-by');

// Security headers. helmet provides the standard set; securityHeaders adds the
// explicit CSP/HSTS/nosniff/frame/referrer/permissions contract that ERAS
// depends on (see middleware/securityHeaders.js for the exact policy and the
// Google/Firebase/Maps sources it deliberately permits). Strict by default for
// an API: this app returns JSON, while the Flutter web bundle is served by
// Firebase Hosting. helmet is attached to the Express app only and does not
// affect the Socket.IO handshake, which is served by the raw HTTP server.
app.use(helmet());
app.use(securityHeaders);

// CORS. Default reflects any origin (historical Flutter web + native client
// behaviour); a CORS_ORIGINS allowlist locks it down in production.
app.use(
  cors({
    origin: env.CORS_ORIGIN,
    credentials: true,
  })
);

// Lightweight, unauthenticated liveness probe for the hosting platform. This
// intentionally does not query PostgreSQL: dependency checks belong in
// deployment smoke tests, not in a high-frequency health check.
app.get('/health', (req, res) => {
  res.status(200).json({ success: true, status: 'ok' });
});

// Safe email transport diagnostics (never exposes API keys, SMTP URLs, sender
// addresses, or verification codes).
app.get('/health/email', (req, res) => {
  const diagnostics =
    typeof emailService.getTransportDiagnostics === 'function'
      ? emailService.getTransportDiagnostics()
      : {
          configured: false,
          transportConfigured: 'no',
          provider: 'unconfigured',
          transport: 'unconfigured',
          fromConfigured: 'no',
        };
  res.status(200).json({
    success: true,
    status: 'ok',
    email: {
      transportConfigured: diagnostics.transportConfigured,
      provider: diagnostics.provider,
      fromConfigured: diagnostics.fromConfigured,
    },
  });
});

// Bounded JSON body parsing. Oversized bodies are rejected by body-parser with
// a 413 (surfaced by errorMiddleware) before any controller runs.
app.use(express.json({ limit: env.JSON_BODY_LIMIT }));

// Generous catch-all limiter for abusive traffic. GPS / heartbeat paths are
// skipped inside the limiter so emergency location streaming is never throttled.
app.use('/api', apiLimiter);

// Strict limiter for credential endpoints only.
app.use('/api/auth/login', authLimiter);
app.use('/api/auth/register', authLimiter);

app.use('/api/auth', authRoutes);
app.use('/api/requests', requestRoutes);
app.use('/api/resources', resourceRoutes);
app.use('/api/responders', responderRoutes);
app.use('/api/allocations', allocationRoutes);
app.use('/api/responder-resources', responderResourceRoutes);
app.use('/api/admin', adminRoutes);
app.use('/api/users', userRoutes);
app.use('/api/location', locationRoutes);

// Unknown routes get a JSON 404 rather than the default HTML body, so clients
// always receive a consistent, non-leaky envelope.
app.use((req, res) => {
  res.status(404).json({ success: false, message: 'Not found' });
});

app.use(errorMiddleware);

module.exports = app;
