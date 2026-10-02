const env = require('../config/env');

const RESEND_ENDPOINT = 'https://api.resend.com/emails';
const testCodes = new Map();

function isConfigured() {
  return env.IS_TEST || Boolean(env.RESEND_API_KEY && env.EMAIL_FROM);
}

function purposeLabel(purpose) {
  return purpose === 'EMAIL_VERIFICATION' ? 'email verification' : 'password reset';
}

/**
 * Deliver a six-digit one-time code without ever logging or returning it to an
 * API caller. Production uses Resend's HTTPS API so the backend needs no SMTP
 * sockets or extra package. Tests retain codes only in process memory.
 */
async function sendAuthCode({ to, purpose, code }) {
  if (env.IS_TEST) {
    testCodes.set(`${String(to).toLowerCase()}:${purpose}`, code);
    return;
  }

  if (!isConfigured()) {
    const error = new Error('AUTH_EMAIL_NOT_CONFIGURED');
    error.code = 'AUTH_EMAIL_NOT_CONFIGURED';
    throw error;
  }

  const label = purposeLabel(purpose);
  const ttl = env.AUTH_OTP_TTL_MINUTES;
  const text =
    `Your ERAS ${label} code is ${code}. ` +
    `It expires in ${ttl} minutes. If you did not request this code, ignore this email.`;
  const html =
    `<p>Your ERAS ${label} code is:</p>` +
    `<p style="font-size:28px;font-weight:700;letter-spacing:8px">${code}</p>` +
    `<p>This code expires in ${ttl} minutes. If you did not request it, ignore this email.</p>`;

  let response;
  try {
    response = await fetch(RESEND_ENDPOINT, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${env.RESEND_API_KEY}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        from: env.EMAIL_FROM,
        to: [String(to).trim()],
        subject: `ERAS ${label} code`,
        text,
        html,
      }),
      signal: AbortSignal.timeout(env.AUTH_EMAIL_SEND_TIMEOUT_MS),
    });
  } catch (_) {
    const error = new Error('AUTH_EMAIL_DELIVERY_FAILED');
    error.code = 'AUTH_EMAIL_DELIVERY_FAILED';
    throw error;
  }

  if (!response.ok) {
    // Do not include provider response bodies: they can contain addresses or
    // configuration detail. The caller returns a stable generic response.
    const error = new Error('AUTH_EMAIL_DELIVERY_FAILED');
    error.code = 'AUTH_EMAIL_DELIVERY_FAILED';
    throw error;
  }
}

function getTestCodeForTests(email, purpose) {
  if (!env.IS_TEST) return null;
  return testCodes.get(`${String(email).trim().toLowerCase()}:${purpose}`) || null;
}

function clearTestCodesForTests() {
  testCodes.clear();
}

module.exports = {
  isConfigured,
  sendAuthCode,
  getTestCodeForTests,
  clearTestCodesForTests,
};
