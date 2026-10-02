// ---------------------------------------------------------------------------
// HTTP SECURITY HEADERS
//
// Built from the resources ERAS actually uses, so nothing here breaks Firebase
// Auth, Google Sign-In, Google Maps, Socket.IO or the Flutter clients.
//
// Important: the Flutter web bundle is served by FIREBASE HOSTING, not by this
// Express app (see PRODUCTION_DEPLOYMENT.md). A Content-Security-Policy on an
// API response only governs documents served BY THIS ORIGIN, so the strict API
// policy below cannot break the hosted Flutter page - and the API never returns
// HTML. If ERAS ever serves the Flutter bundle from this same Express app, the
// policy must be widened with the Flutter/Google sources listed in
// FLUTTER_WEB_CSP_SOURCES (documented, opt-in through CSP_POLICY).
//
// Sources deliberately allow-listed (only needed if a document is ever served
// from this origin):
//   * https://apis.google.com, https://www.gstatic.com - Firebase JS SDK /
//     Google Identity Services / GIS button
//   * https://maps.googleapis.com, https://maps.gstatic.com - Maps JS API
//   * https://securetoken.googleapis.com, https://identitytoolkit.googleapis.com,
//     https://firestore.googleapis.com - Firebase Auth REST endpoints
// No unsafe-eval / unsafe-inline is granted anywhere.
// ---------------------------------------------------------------------------

const env = require('../config/env');

const GOOGLE_FIREBASE_SOURCES = [
  'https://apis.google.com',
  'https://www.gstatic.com',
  'https://maps.googleapis.com',
  'https://maps.gstatic.com',
];

const GOOGLE_FIREBASE_CONNECT_SOURCES = [
  'https://securetoken.googleapis.com',
  'https://identitytoolkit.googleapis.com',
  'https://firestore.googleapis.com',
  'https://www.googleapis.com',
  'https://maps.googleapis.com',
  'wss:',
];

/**
 * Default policy. `default-src 'none'` is correct for a JSON API: any response
 * this origin serves may not load or execute anything at all.
 */
const DEFAULT_API_CSP = [
  "default-src 'none'",
  "base-uri 'self'",
  "frame-ancestors 'self'",
  "form-action 'self'",
  "object-src 'none'",
].join('; ');

/** Wider policy, used only when a deployment explicitly serves HTML here. */
const FLUTTER_WEB_CSP_SOURCES = [
  "default-src 'self'",
  "base-uri 'self'",
  "object-src 'none'",
  `script-src 'self' ${GOOGLE_FIREBASE_SOURCES.join(' ')}`,
  "style-src 'self' 'unsafe-inline'",
  "img-src 'self' data: blob: https:",
  "font-src 'self' data:",
  `connect-src 'self' https: ${GOOGLE_FIREBASE_CONNECT_SOURCES.join(' ')}`,
  `frame-src 'self' ${GOOGLE_FIREBASE_SOURCES.join(' ')}`,
  "frame-ancestors 'self'",
].join('; ');

function cspPolicy() {
  // Explicit override wins (documented escape hatch for unusual deployments).
  const configured = (process.env.CSP_POLICY || '').trim();
  if (configured) return configured;
  // Serving the Flutter bundle from this origin is opt-in; the strict API
  // policy is the default.
  return env.SERVE_FLUTTER_WEB_FROM_API ? FLUTTER_WEB_CSP_SOURCES : DEFAULT_API_CSP;
}

/**
 * Explicit header set (helmet already covers most of these; they are set here
 * as well so the contract is visible, testable and stable even if helmet
 * defaults change between versions).
 */
function securityHeaders(req, res, next) {
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('X-Frame-Options', 'DENY');
  res.setHeader('Referrer-Policy', 'no-referrer');
  // No browser feature is required by the API. (The Flutter web page served by
  // Firebase Hosting sets its own policy; geolocation is used there, not here.)
  res.setHeader(
    'Permissions-Policy',
    'camera=(), microphone=(), geolocation=(self), payment=(), usb=(), magnetometer=(), gyroscope=()'
  );
  res.setHeader('Cross-Origin-Resource-Policy', 'same-site');
  res.setHeader('X-Permitted-Cross-Domain-Policies', 'none');
  res.setHeader('Content-Security-Policy', cspPolicy());

  // HSTS only over HTTPS (behind Render's proxy this is always the case) and
  // only in production so local http development is never pinned.
  if (env.IS_PRODUCTION) {
    res.setHeader('Strict-Transport-Security', 'max-age=15552000; includeSubDomains');
  }

  // The API must never be cached by shared caches: every response is
  // authenticated or user specific.
  res.setHeader('Cache-Control', 'no-store');

  next();
}

module.exports = {
  securityHeaders,
  cspPolicy,
  DEFAULT_API_CSP,
  FLUTTER_WEB_CSP_SOURCES,
  GOOGLE_FIREBASE_SOURCES,
  GOOGLE_FIREBASE_CONNECT_SOURCES,
};
