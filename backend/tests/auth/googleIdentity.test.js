// Google/Firebase ID token verification.
//
// Real RS256 tokens are signed with a locally generated key pair and verified
// against an injected certificate set, so the signature, issuer, audience,
// expiry and email-verification rules are exercised without any network access
// or Google credentials.

const crypto = require('crypto');
const jwt = require('jsonwebtoken');

const {
  verifyIdentityToken,
  clearCertificateCache,
  IdentityTokenError,
  isGoogleAuthConfigured,
} = require('../../src/services/firebaseTokenService');
const env = require('../../src/config/env');

describe('Google/Firebase identity verification', () => {
  const { privateKey, publicKey } = crypto.generateKeyPairSync('rsa', {
    modulusLength: 2048,
    publicKeyEncoding: { type: 'spki', format: 'pem' },
    privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
  });

  const KEY_ID = 'test-key-1';
  const PROJECT_ID = 'eras-test-project';
  const GOOGLE_CLIENT_ID = 'eras-web.apps.googleusercontent.com';
  const FIREBASE_ISSUER = `https://securetoken.google.com/${PROJECT_ID}`;

  const originalEnv = {
    FIREBASE_PROJECT_ID: env.FIREBASE_PROJECT_ID,
    GOOGLE_CLIENT_IDS: env.GOOGLE_CLIENT_IDS,
  };

  // A fetch stand-in that serves the local public key as a Google certificate.
  const fakeFetch = async () => ({
    ok: true,
    json: async () => ({ [KEY_ID]: publicKey }),
  });

  const failingFetch = async () => ({ ok: false, status: 500, json: async () => ({}) });

  beforeAll(() => {
    env.FIREBASE_PROJECT_ID = PROJECT_ID;
    env.GOOGLE_CLIENT_IDS = [GOOGLE_CLIENT_ID];
  });

  afterAll(() => {
    env.FIREBASE_PROJECT_ID = originalEnv.FIREBASE_PROJECT_ID;
    env.GOOGLE_CLIENT_IDS = originalEnv.GOOGLE_CLIENT_IDS;
  });

  beforeEach(() => clearCertificateCache());

  function firebaseToken(overrides = {}, { expiresIn = '1h', key = privateKey } = {}) {
    const payload = {
      iss: FIREBASE_ISSUER,
      aud: PROJECT_ID,
      sub: 'firebase-uid-123',
      email: 'user@example.com',
      email_verified: true,
      name: 'ERAS User',
      ...overrides,
    };
    return jwt.sign(payload, key, {
      algorithm: 'RS256',
      keyid: KEY_ID,
      expiresIn,
    });
  }

  function googleToken(overrides = {}, { expiresIn = '1h' } = {}) {
    const payload = {
      iss: 'https://accounts.google.com',
      aud: GOOGLE_CLIENT_ID,
      sub: 'google-sub-456',
      email: 'person@gmail.com',
      email_verified: true,
      ...overrides,
    };
    return jwt.sign(payload, privateKey, { algorithm: 'RS256', keyid: KEY_ID, expiresIn });
  }

  test('google sign-in is reported as unconfigured when no project/client id is set', () => {
    const saved = { project: env.FIREBASE_PROJECT_ID, clients: env.GOOGLE_CLIENT_IDS };
    env.FIREBASE_PROJECT_ID = null;
    env.GOOGLE_CLIENT_IDS = [];
    expect(isGoogleAuthConfigured()).toBe(false);
    env.FIREBASE_PROJECT_ID = saved.project;
    env.GOOGLE_CLIENT_IDS = saved.clients;
    expect(isGoogleAuthConfigured()).toBe(true);
  });

  test('verifies a well-formed Firebase ID token', async () => {
    const identity = await verifyIdentityToken(firebaseToken(), { fetchImpl: fakeFetch });
    expect(identity).toMatchObject({
      provider: 'FIREBASE',
      subject: 'firebase-uid-123',
      email: 'user@example.com',
      emailVerified: true,
    });
  });

  test('verifies a Google Identity Services ID token', async () => {
    const identity = await verifyIdentityToken(googleToken(), { fetchImpl: fakeFetch });
    expect(identity.provider).toBe('GOOGLE');
    expect(identity.subject).toBe('google-sub-456');
  });

  test('rejects a token signed by a different key', async () => {
    const { privateKey: attackerKey } = crypto.generateKeyPairSync('rsa', {
      modulusLength: 2048,
      publicKeyEncoding: { type: 'spki', format: 'pem' },
      privateKeyEncoding: { type: 'pkcs8', format: 'pem' },
    });
    await expect(
      verifyIdentityToken(firebaseToken({}, { key: attackerKey }), { fetchImpl: fakeFetch })
    ).rejects.toBeInstanceOf(IdentityTokenError);
  });

  test('rejects an expired token', async () => {
    await expect(
      verifyIdentityToken(firebaseToken({}, { expiresIn: '-1h' }), { fetchImpl: fakeFetch })
    ).rejects.toBeInstanceOf(IdentityTokenError);
  });

  test('rejects an unexpected issuer (e.g. a self-signed "google" claim)', async () => {
    await expect(
      verifyIdentityToken(firebaseToken({ iss: 'https://evil.example.com' }), {
        fetchImpl: fakeFetch,
      })
    ).rejects.toBeInstanceOf(IdentityTokenError);
  });

  test('rejects a token for a different Firebase project (audience binding)', async () => {
    await expect(
      verifyIdentityToken(firebaseToken({ aud: 'someone-elses-project' }), {
        fetchImpl: fakeFetch,
      })
    ).rejects.toBeInstanceOf(IdentityTokenError);
  });

  test('rejects an unknown signing key (rotated/untrusted kid)', async () => {
    const token = jwt.sign(
      { iss: FIREBASE_ISSUER, aud: PROJECT_ID, sub: 'x', email: 'a@b.com' },
      privateKey,
      { algorithm: 'RS256', keyid: 'unknown-kid' }
    );
    await expect(verifyIdentityToken(token, { fetchImpl: fakeFetch })).rejects.toBeInstanceOf(
      IdentityTokenError
    );
  });

  test('fails safely (503) when Google certificates cannot be fetched', async () => {
    await expect(
      verifyIdentityToken(firebaseToken(), { fetchImpl: failingFetch })
    ).rejects.toMatchObject({ statusCode: 503 });
  });

  test('rejects malformed / oversized / non-JWT input', async () => {
    await expect(verifyIdentityToken('not-a-jwt', { fetchImpl: fakeFetch })).rejects.toBeInstanceOf(
      IdentityTokenError
    );
    await expect(verifyIdentityToken('', { fetchImpl: fakeFetch })).rejects.toBeInstanceOf(
      IdentityTokenError
    );
    await expect(
      verifyIdentityToken('x'.repeat(9000), { fetchImpl: fakeFetch })
    ).rejects.toBeInstanceOf(IdentityTokenError);
  });

  test('reports an unverified Firebase email so the caller can refuse the sign-in', async () => {
    const identity = await verifyIdentityToken(firebaseToken({ email_verified: false }), {
      fetchImpl: fakeFetch,
    });
    expect(identity.emailVerified).toBe(false);
  });

  test('certificates are cached between verifications (no fetch per login)', async () => {
    let calls = 0;
    const countingFetch = async () => {
      calls += 1;
      return { ok: true, json: async () => ({ [KEY_ID]: publicKey }) };
    };
    await verifyIdentityToken(firebaseToken(), { fetchImpl: countingFetch });
    await verifyIdentityToken(firebaseToken({ sub: 'another' }), { fetchImpl: countingFetch });
    expect(calls).toBe(1);
  });
});
