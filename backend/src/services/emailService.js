// ---------------------------------------------------------------------------
// ERAS EMAIL DELIVERY (provider abstraction)
//
// ERAS-branded transactional email for email verification and password reset.
// Nothing here impersonates Firebase or Google: the sender name, subject and
// body are clearly ERAS, and the recipient's ERAS action is described
// explicitly (the email only ever contains an ERAS one-time code).
//
// Transports (first configured one wins):
//   1. RESEND_API_KEY  -> Resend HTTPS API (no extra dependency; global fetch)
//   2. SMTP_URL + nodemailer (only when the optional package is installed)
//   3. unconfigured    -> logged no-op
//
// Secrets are never hardcoded and never logged. When no transport is
// configured, delivery is reported as `{ delivered: false }`; the caller still
// returns a generic response so no account/email enumeration is possible.
// ---------------------------------------------------------------------------

const env = require('../config/env');
const logger = require('../config/logger');

const FROM_NAME = 'ERAS (Emergency Resource Allocation System)';
const DEFAULT_FROM_ADDRESS = 'no-reply@eras.local';

function fromAddress() {
  return (process.env.ERAS_MAIL_FROM || DEFAULT_FROM_ADDRESS).trim();
}

function brandedHtml({ title, intro, code, footer }) {
  // Pure ERAS branding. All interpolated values are server-generated: the code
  // is 6 digits and the texts are static, so there is no user-supplied HTML
  // here (no injection surface).
  return `<!doctype html>
<html>
  <body style="margin:0;padding:24px;background:#0b1220;font-family:Segoe UI,Roboto,Helvetica,Arial,sans-serif;">
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0">
      <tr><td align="center">
        <table role="presentation" width="520" cellpadding="0" cellspacing="0"
               style="background:#111a2e;border:1px solid #1f2b45;border-radius:14px;padding:28px;">
          <tr><td>
            <div style="font-size:13px;letter-spacing:2px;color:#39d0c8;font-weight:700;">ERAS</div>
            <h1 style="margin:10px 0 6px;font-size:20px;color:#eaf0ff;">${title}</h1>
            <p style="margin:0 0 18px;font-size:14px;line-height:1.5;color:#a9b6d3;">${intro}</p>
            <div style="font-size:34px;letter-spacing:10px;font-weight:800;color:#eaf0ff;
                        background:#0b1220;border:1px solid #1f2b45;border-radius:10px;
                        padding:16px 20px;text-align:center;">${code}</div>
            <p style="margin:18px 0 0;font-size:13px;line-height:1.5;color:#8c9ab8;">${footer}</p>
            <p style="margin:18px 0 0;font-size:12px;color:#67748f;">
              ERAS will never ask you for this code by phone, chat or email.
            </p>
          </td></tr>
        </table>
      </td></tr>
    </table>
  </body>
</html>`;
}

function verificationEmail(code) {
  return {
    subject: 'ERAS: confirm your email address',
    text:
      `Welcome to ERAS (Emergency Resource Allocation System).\n\n` +
      `Your ERAS email verification code is ${code}.\n` +
      `It expires in a few minutes and can be used once.\n\n` +
      `If you did not create an ERAS account you can ignore this email.`,
    html: brandedHtml({
      title: 'Confirm your ERAS email address',
      intro: 'Use this one-time code to finish creating your ERAS account:',
      code,
      footer: 'The code expires shortly and works once. You can request a new code from ERAS if it expires.',
    }),
  };
}

function passwordResetEmail(code) {
  return {
    subject: 'ERAS: your password reset code',
    text:
      `A password reset was requested for your ERAS account.\n\n` +
      `Your ERAS password reset code is ${code}.\n` +
      `It expires in 10 minutes and can be used once.\n\n` +
      `If you did not request this, ignore this email - your password stays unchanged.`,
    html: brandedHtml({
      title: 'Reset your ERAS password',
      intro: 'Enter this one-time code in ERAS to choose a new password:',
      code,
      footer: 'The code expires in 10 minutes and works once. If you did not request a reset, no action is needed.',
    }),
  };
}

async function sendWithResend({ to, subject, text, html }) {
  const response = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      // Read from the environment only - never logged, never hardcoded.
      Authorization: `Bearer ${env.RESEND_API_KEY}`,
    },
    body: JSON.stringify({
      from: `${FROM_NAME} <${fromAddress()}>`,
      to: [to],
      subject,
      text,
      html,
    }),
  });

  if (!response.ok) {
    // The provider body can contain the address; keep only the status.
    throw new Error(`resend responded with ${response.status}`);
  }
  return { delivered: true, transport: 'resend' };
}

async function sendWithSmtp({ to, subject, text, html }) {
  let nodemailer;
  try {
    // Optional dependency: ERAS runs unchanged when it is not installed.
    // eslint-disable-next-line global-require, import/no-unresolved
    nodemailer = require('nodemailer');
  } catch {
    throw new Error('nodemailer is not installed');
  }

  const transport = nodemailer.createTransport(env.SMTP_URL);
  await transport.sendMail({
    from: `${FROM_NAME} <${fromAddress()}>`,
    to,
    subject,
    text,
    html,
  });
  return { delivered: true, transport: 'smtp' };
}

/**
 * Send one transactional ERAS email. Never throws: delivery failures are logged
 * without the address or the code, and reported to the caller as
 * `{ delivered: false }`.
 */
async function send({ to, subject, text, html }) {
  try {
    if (env.RESEND_API_KEY) {
      return await sendWithResend({ to, subject, text, html });
    }
    if (env.SMTP_URL) {
      return await sendWithSmtp({ to, subject, text, html });
    }

    // No transport configured. The code is NEVER logged; only the fact that a
    // message could not be delivered.
    logger.warn('email.transport_unconfigured', { subject });
    return { delivered: false, transport: 'unconfigured' };
  } catch (error) {
    logger.error('email.delivery_failed', { subject, message: error?.message });
    return { delivered: false, transport: 'failed' };
  }
}

function sendVerificationCode(to, code) {
  return send({ to, ...verificationEmail(code) });
}

function sendPasswordResetCode(to, code) {
  return send({ to, ...passwordResetEmail(code) });
}

module.exports = {
  FROM_NAME,
  verificationEmail,
  passwordResetEmail,
  send,
  sendVerificationCode,
  sendPasswordResetCode,
};
