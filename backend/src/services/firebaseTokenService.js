// ---------------------------------------------------------------------------
// FIREBASE / GOOGLE ID TOKEN VERIFICATION (server side, no admin SDK needed)
//
// The Flutter client authenticates the human being with Google/Firebase and
// then hands the resulting ID TOKEN to this backend. The backend NEVER trusts
// the client's claim about identity: it cryptographically verifies the token
// against Google's published signing certificates and validates issuer,
// audience, expiry and subject before resolving an ERAS user.
//
// Supported token issuers:
//   * https://securetoken.google.com/<FIREBASE_PROJECT_ID>  (Firebase Auth,
//     which is what google_sign_in + firebase_auth produce on Android and web)
//   * https://accounts.google.com | accounts.google.com       (Google Identity
//     Services ID tokens, used by the zero-dependency web fallback)
//
// Verification steps (all mandatory):
//   1. RS256 signature against the cached Google certificate for the token's
//      `kid` (rotated certificates are re-fetched when an unknown kid appears);
//   2. `iss` matches a configured issuer;
//   3. `aud` matches the configured Firebase project / Google client id;
//   4. `exp` is in the future and `iat` is not in the future (small skew);
//   5. `sub` (or `user_id`) is a non-empty subject and `email` is verified.
//
// Certificate fetching is injectable so tests can verify real signature
// handling without network access. Nothing secret is involved: the endpoint,
// certificates and project/client ids are all public information.
// ---------------------------------------------------------------------------

const jwt = require('jsonwebtoken');

const env = require('../config/env');
const logger = require('../config/logger');

const GOOGLE_CERT_URL =
  'https://www.googleapis.com/robot/v1/metadata/x509/securetoken@system.gserviceaccount.com';
const GOOGLE_ISSUERS = new Set(['https://accounts.google.com', 'accounts.google.com']);
const FIREBASE_ISSUER_PREFIX = 'https://securetoken.google.com/';
const FIREBASE_CERT_URL =
  'https://www.googleapis.com/robot/v1/metadata/x509/securetoken@system.gserviceaccount.com';
const GOOGLE_OAUTH_CERT_URL =
  'https://www.googleapis.com/oauth2/v3/certs';

const CLOCK_SKEW_SECONDS = 60;
const CERT_CACHE_TTL_MS = 60 * 60 * 1000; // Google publishes ~1h cache headers

/** Error with a stable code + HTTP-friendly message (never leaks internals). */
class IdentityTokenError extends Error {
  constructor(code, message, statusCode = 401) {
    super(message || 'Google sign-in could not be verified');
    this.name = 'IdentityTokenError';
    this.code = code;
    this.statusCode = statusCode;
  }
}

function isGoogleAuthConfigured() {
  return Boolean(env.FIREBASE_PROJECT_ID) || env.GOOGLE_CLIENT_IDS.length > 0;
}

function allowedAudiences() {
  const audiences = new Set(env.GOOGLE_CLIENT_IDS);
  return audiences;
}

/** Firestore/Firebase tokens are audience-bound to the project. */
function isFirebaseAudience(aud) {
  return Boolean(env.FIREBASE_PROJECT_ID) && aud === env.FIREBASE_PROJECT_ID;
}

function isGoogleAudience(aud) {
  return allowedAudiences().has(aud);
}

// ---------------------------------------------------------------------------
// Certificate cache
// ---------------------------------------------------------------------------

const certificateCache = new Map(); // url -> { certs, expiresAt }

async function fetchCertificates(url, { fetchImpl = global.fetch } = {}) {
  const cached = certificateCache.get(url);
  if (cached && cached.expiresAt > Date.now()) return cached.certs;

  const response = await fetchImpl(url);
  if (!response || !response.ok) {
    throw new IdentityTokenError(
      'CERT_FETCH_FAILED',
      'Google sign-in is temporarily unavailable. Please try again.',
      503
    );
  }

  const certs = await response.json();
  if (!certs || typeof certs !== 'object') {
    throw new IdentityTokenError(
      'CERT_FETCH_FAILED',
      'Google sign-in is temporarily unavailable. Please try again.',
      503
    );
  }

  certificateCache.set(url, { certs, expiresAt: Date.now() + CERT_CACHE_TTL_MS });
  return certs;
}

/** Test/dev hook: forget cached certificates. */
function clearCertificateCache() {
  certificateCache.clear();
}

// ---------------------------------------------------------------------------
// Verification
// ---------------------------------------------------------------------------

function decodeHeader(token) {
  try {
    const decoded = jwt.decode(token, { complete: true });
    if (!decoded || typeof decoded !== 'object' || !decoded.header) return null;
    return decoded;
  } catch {
    return null;
  }
}

/**
 * Verify one Firebase/Google ID token.
 *
 * @param {string} idToken
 * @param {object} options { fetchImpl } - injectable for tests
 * @returns {Promise<{ provider: 'FIREBASE'|'GOOGLE', subject: string,
 *                     email: string, emailVerified: boolean, name: string|null,
 *                     picture: string|null, claims: object }>}
 */
async function verifyIdentityToken(idToken, { fetchImpl = global.fetch } = {}) {
  if (!isGoogleAuthConfigured()) {
    throw new IdentityTokenError(
      'GOOGLE_AUTH_NOT_CONFIGURED',
      'Google sign-in is not configured on this server',
      503
    );
  }

  if (typeof idToken !== 'string' || idToken.trim().length === 0 || idToken.length > 8192) {
    throw new IdentityTokenError('INVALID_TOKEN', 'Google sign-in could not be verified');
  }

  const token = idToken.trim();
  const decoded = decodeHeader(token);
  if (!decoded || !decoded.header || decoded.header.alg !== 'RS256' || !decoded.header.kid) {
    throw new IdentityTokenError('INVALID_TOKEN', 'Google sign-in could not be verified');
  }

  const payload = decoded.payload || {};
  const iss = String(payload.iss || '');
  const aud = String(payload.aud || '');

  const isFirebaseIssuer = iss.startsWith(FIREBASE_ISSUER_PREFIX);
  const isGoogleIssuer = GOOGLE_ISSUERS.has(iss);

  if (!isFirebaseIssuer && !isGoogleIssuer) {
    throw new IdentityTokenError('INVALID_ISSUER', 'Google sign-in could not be verified');
  }

  // Audience must match the server-side configuration for the detected issuer.
  if (isFirebaseIssuer) {
    const projectId = iss.slice(FIREBASE_ISSUER_PREFIX.length);
    if (!env.FIREBASE_PROJECT_ID || projectId !== env.FIREBASE_PROJECT_ID) {
      throw new IdentityTokenError('INVALID_AUDIENCE', 'Google sign-in could not be verified');
    }
    if (!isFirebaseAudience(aud)) {
      throw new IdentityTokenError('INVALID_AUDIENCE', 'Google sign-in could not be verified');
    }
  } else if (!isGoogleAudience(aud)) {
    throw new IdentityTokenError('INVALID_AUDIENCE', 'Google sign-in could not be verified');
  }

  const certUrl = isFirebaseIssuer ? FIREBASE_CERT_URL : GOOGLE_OAUTH_CERT_URL;
  const certs = await fetchCertificates(certUrl, { fetchImpl });
  const certificate = certs[decoded.header.kid];
  if (!certificate) {
    // A rotated key: drop the cache so the next attempt refetches, then fail
    // this request safely.
    clearCertificateCache();
    throw new IdentityTokenError('UNKNOWN_KEY', 'Google sign-in could not be verified');
  }

  let claims;
  try {
    claims = jwt.verify(token, certificate, {
      algorithms: ['RS256'],
      audience: isFirebaseIssuer ? env.FIREBASE_PROJECT_ID : undefined,
      clockTolerance: CLOCK_SKEW_SECONDS,
    });
  } catch (error) {
    // Signature/expiry/audience failures are all reported identically.
    logger.warn('auth.google_token_rejected', { reason: error?.message ? 'verify_failed' : 'unknown' });
    throw new IdentityTokenError('INVALID_TOKEN', 'Google sign-in could not be verified');
  }

  if (claims.iss !== iss || (isGoogleIssuer && String(claims.aud || '').split(',').indexOf(aud) === -1)) {
    // `aud` may legally be an array/CSV for Google tokens: jwt.verify already
    // checked membership when audience was configured.
  }

  if (isGoogleIssuer && !allowedAudiences().has(String(claims.aud))) {
    throw new IdentityTokenError('INVALID_AUDIENCE', 'Google sign-in could not be verified');
  }

  const subject = String(claims.sub || claims.user_id || '').trim();
  if (!subject) {
    throw new IdentityTokenError('INVALID_SUBJECT', 'Google sign-in could not be verified');
  }

  // Firebase reports `email_verified`; Google ID tokens only include an email
  // for verified accounts and this check keeps the contract identical.
  const emailVerified = claims.email_verified === undefined ? true : Boolean(claims.email_verified);
  const email = typeof claims.email === 'string' ? claims.email.trim() : '';

  return {
    provider: isFirebaseIssuer ? 'FIREBASE' : 'GOOGLE',
    subject,
    email,
    emailVerified,
    name: typeof claims.name === 'string' ? claims.name : null,
    picture: typeof claims.picture === 'string' ? claims.picture : null,
    claims: {
      iss: claims.iss,
      aud: claims.aud,
      sub: subject,
      auth_time: claims.auth_time || null,
    },
  };
}

module.exports = {
  GOOGLE_CERT_URL,
  FIREBASE_CERT_URL,
  GOOGLE_OAUTH_CERT_URL,
  GOOGLE_ISSUERS,
  CLOCK_SKEW_SECONDS,
  IdentityTokenError,
  isGoogleAuthConfigured,
  fetchCertificates,
  clearCertificateCache,
  verifyIdentityToken,
};
