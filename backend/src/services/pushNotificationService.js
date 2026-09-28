/**
 * Firebase Cloud Messaging (FCM) push notifications for responders.
 *
 * Design contract (see the offline-responder requirements):
 *
 * 1. Socket.IO remains the realtime channel for connected/foreground apps.
 *    FCM only covers responders who are backgrounded or whose app is not
 *    currently maintaining a Socket.IO connection.
 * 2. The EmergencyRequest row in PostgreSQL is the source of truth. Pushes
 *    are fire-and-forget: every public function here resolves (never throws),
 *    so a notification failure can NEVER fail or roll back a successfully
 *    created emergency request. When a responder opens/reconnects, the
 *    compatible pending-request API (GET /api/requests/compatible) returns
 *    everything a missed push would have carried.
 * 3. Pushes go only to responders the compatibility engine already selected
 *    - never to unrelated responders.
 * 4. With no service account configured, sending is a logged no-op. This
 *    keeps local development, the test suite, and deployments without FCM
 *    fully functional.
 *
 * Implementation note: the FCM HTTP v1 API is called directly with OAuth2
 * service-account credentials (JWT assertion signed with the existing
 * `jsonwebtoken` dependency + Node's global fetch). No extra npm dependency
 * and no long-lived server key are required.
 */

const fs = require('fs');
const jwt = require('jsonwebtoken');
const env = require('../config/env');
const prisma = require('../config/prisma');

const FCM_TOKEN_ENDPOINT = 'https://oauth2.googleapis.com/token';
const FCM_SEND_ENDPOINT = 'https://fcm.googleapis.com/v1/projects';
const FCM_SCOPE = 'https://www.googleapis.com/auth/firebase.messaging';

// Access tokens live ~1h. Refresh well before expiry.
const ACCESS_TOKEN_SAFETY_MS = 5 * 60 * 1000;

let cachedServiceAccount = null;
let cachedAccessToken = null; // { token, expiresAt }

function logger() {
  // eslint-disable-next-line no-console
  return console;
}

/** Parse (and cache) the service account from the environment. */
function loadServiceAccount() {
  if (cachedServiceAccount !== null) return cachedServiceAccount;

  let raw = null;
  if (env.FCM_SERVICE_ACCOUNT) {
    raw = env.FCM_SERVICE_ACCOUNT.trim();
  } else if (env.FCM_SERVICE_ACCOUNT_FILE) {
    try {
      raw = fs.readFileSync(env.FCM_SERVICE_ACCOUNT_FILE, 'utf8').trim();
    } catch (error) {
      logger().error(
        `[fcm] could not read FCM_SERVICE_ACCOUNT_FILE ${env.FCM_SERVICE_ACCOUNT_FILE}: ${error.message}`
      );
      raw = null;
    }
  }

  if (!raw) {
    cachedServiceAccount = false;
    return cachedServiceAccount;
  }

  try {
    const account = JSON.parse(raw);
    if (
      !account ||
      typeof account.client_email !== 'string' ||
      !account.client_email ||
      typeof account.private_key !== 'string' ||
      !account.private_key ||
      !account.project_id
    ) {
      throw new Error(
        'service account JSON must contain client_email, private_key and project_id'
      );
    }
    cachedServiceAccount = {
      clientEmail: account.client_email,
      privateKey: account.private_key.replace(/\\n/g, '\n'),
      projectId: String(account.project_id),
    };
  } catch (error) {
    logger().error(`[fcm] invalid FCM service account configuration: ${error.message}`);
    cachedServiceAccount = false;
  }
  return cachedServiceAccount;
}

/** Forget the parsed account + cached token (used by tests). */
function resetFcmStateForTests() {
  cachedServiceAccount = null;
  cachedAccessToken = null;
}

/**
 * Test hook: force the parsed service-account state without touching real
 * environment files. Pass an object shaped like loadServiceAccount()'s result
 * (or false to simulate "not configured").
 */
function setServiceAccountForTests(account) {
  cachedServiceAccount = account || false;
  cachedAccessToken = null;
}

function isFcmConfigured() {
  return Boolean(loadServiceAccount());
}

/**
 * Exchange the service account for a short-lived OAuth2 access token.
 * Returns null on any failure (callers treat push as best-effort).
 */
async function getAccessToken() {
  const account = loadServiceAccount();
  if (!account) return null;

  if (
    cachedAccessToken &&
    cachedAccessToken.expiresAt - ACCESS_TOKEN_SAFETY_MS > Date.now()
  ) {
    return cachedAccessToken.token;
  }

  try {
    const issuedAt = Math.floor(Date.now() / 1000);
    const assertion = jwt.sign(
      {
        iss: account.clientEmail,
        scope: FCM_SCOPE,
        aud: FCM_TOKEN_ENDPOINT,
        iat: issuedAt,
        exp: issuedAt + 3600,
      },
      account.privateKey,
      { algorithm: 'RS256' }
    );

    const response = await fetch(FCM_TOKEN_ENDPOINT, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
        assertion,
      }),
      signal: AbortSignal.timeout(env.FCM_SEND_TIMEOUT_MS),
    });

    if (!response.ok) {
      const detail = await response.text().catch(() => '');
      throw new Error(`token endpoint responded ${response.status}: ${detail.slice(0, 200)}`);
    }

    const body = await response.json();
    if (!body || typeof body.access_token !== 'string') {
      throw new Error('token endpoint response contained no access_token');
    }

    cachedAccessToken = {
      token: body.access_token,
      expiresAt: Date.now() + (Number(body.expires_in) || 3600) * 1000,
    };
    return cachedAccessToken.token;
  } catch (error) {
    cachedAccessToken = null;
    logger().error(`[fcm] could not obtain an access token: ${error.message}`);
    return null;
  }
}

/**
 * Deliver one already-built FCM message
 * (https://fcm.googleapis.com/v1/projects/{project}/messages:send).
 *
 * Exposed separately so tests can observe exactly which messages were
 * produced without performing network I/O.
 *
 * @returns {Promise<{ok: boolean, unregistered: boolean, error?: string}>}
 */
async function deliverFcmMessage(message) {
  const account = loadServiceAccount();
  if (!account) {
    return { ok: false, unregistered: false, error: 'fcm-not-configured' };
  }

  const accessToken = await getAccessToken();
  if (!accessToken) {
    return { ok: false, unregistered: false, error: 'fcm-no-access-token' };
  }

  try {
    const response = await fetch(
      `${FCM_SEND_ENDPOINT}/${encodeURIComponent(account.projectId)}/messages:send`,
      {
        method: 'POST',
        headers: {
          Authorization: `Bearer ${accessToken}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({ message }),
        signal: AbortSignal.timeout(env.FCM_SEND_TIMEOUT_MS),
      }
    );

    if (response.ok) return { ok: true, unregistered: false };

    const detail = await response.text().catch(() => '');
    // 404 UNREGISTERED_NOT_FOUND / 401: the device no longer has this app
    // (or the token was rotated). Callers may safely drop such tokens.
    const unregistered =
      response.status === 404 ||
      /UNREGISTERED|INVALID_ARGUMENT/i.test(detail.slice(0, 400));
    return {
      ok: false,
      unregistered,
      error: `fcm responded ${response.status}: ${detail.slice(0, 200)}`,
    };
  } catch (error) {
    return { ok: false, unregistered: false, error: error.message };
  }
}

function truncateForPush(value, maxLength = 90) {
  const text = String(value ?? '').trim();
  if (text.length <= maxLength) return text;
  return `${text.slice(0, maxLength - 1)}…`;
}

/**
 * Build the FCM message for one device token.
 *
 * `notification` makes the OS display the alert while the app is
 * backgrounded/terminated (no client code needed); `data` carries the
 * machine-readable routing so the app can act when the responder taps it.
 */
function buildNewEmergencyMessage(deviceToken, request) {
  const type = truncateForPush(request.emergencyType);
  const location = truncateForPush(request.location);
  return {
    token: deviceToken,
    notification: {
      title: 'New emergency request',
      body: `${type} at ${location}`.trim(),
    },
    data: {
      kind: 'request.created',
      requestId: String(request.id),
      emergencyType: String(request.emergencyType ?? ''),
      location: String(request.location ?? ''),
      priority: String(request.priority ?? ''),
      status: String(request.status ?? ''),
    },
    android: { priority: 'high' },
  };
}

/**
 * Best-effort push: "a new compatible emergency request was created".
 *
 * NEVER throws. Failures are logged and swallowed; request persistence and
 * the Socket.IO emission happen independently of this function.
 *
 * @param {object} request committed EmergencyRequest row
 * @param {Array<number>} responderIds responders the compatibility engine
 *        already selected (only these may be notified)
 * @param {Set<number>|null} onlineResponderIds responders with a live
 *        Socket.IO connection; they already received the realtime event, so
 *        their devices are skipped when possible
 */
async function notifyRespondersOfNewEmergency(
  request,
  responderIds,
  onlineResponderIds = null
) {
  try {
    if (!request || !Array.isArray(responderIds) || responderIds.length === 0) {
      return;
    }

    const numericResponderIds = [
      ...new Set(responderIds.map(Number).filter((id) => Number.isInteger(id) && id > 0)),
    ];
    if (!numericResponderIds.length) return;

    const tokens = await prisma.pushDeviceToken.findMany({
      where: { userId: { in: numericResponderIds } },
      select: { token: true, userId: true },
    });
    if (!tokens.length) return;

    const targets = onlineResponderIds
      ? tokens.filter((row) => !onlineResponderIds.has(Number(row.userId)))
      : tokens;
    if (!targets.length) return;

    if (!isFcmConfigured()) {
      logger().log(
        `[fcm] ${targets.length} registered device token(s) for ${numericResponderIds.length} compatible responder(s), ` +
          'but FCM is not configured - push skipped (request is already persisted and delivered over Socket.IO).'
      );
      return;
    }

    const unregisteredTokens = [];
    await Promise.all(
      targets.map(async (row) => {
        // Called through module.exports so the seam stays replaceable in
        // tests (module.exports is rebound below; `exports` would not be).
        const result = await module.exports.deliverFcmMessage(
          module.exports.buildNewEmergencyMessage(row.token, request)
        );
        if (!result.ok && result.unregistered) unregisteredTokens.push(row.token);
      })
    );

    // Housekeeping only: a failed delete must never surface as a failure.
    if (unregisteredTokens.length) {
      await prisma.pushDeviceToken
        .deleteMany({ where: { token: { in: unregisteredTokens } } })
        .catch(() => {});
    }
  } catch (error) {
    logger().error(`[fcm] new-emergency push failed (request stays intact): ${error.message}`);
  }
}

module.exports = {
  buildNewEmergencyMessage,
  deliverFcmMessage,
  getAccessToken,
  isFcmConfigured,
  notifyRespondersOfNewEmergency,
  resetFcmStateForTests,
  setServiceAccountForTests,
  truncateForPush,
};
