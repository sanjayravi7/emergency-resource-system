// ---------------------------------------------------------------------------
// ERAS EMAIL DELIVERY (provider abstraction)
//
// ERAS-branded transactional email for email verification, post-verification
// welcome confirmation, and password reset.
// Nothing here impersonates Firebase or Google: the sender name, subject and
// body are clearly ERAS, and the recipient's ERAS action is described
// explicitly.
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

function resendApiKey() {
  const raw = env.RESEND_API_KEY || process.env.RESEND_API_KEY || '';
  return String(raw).trim() || null;
}

function smtpUrl() {
  const raw = env.SMTP_URL || process.env.SMTP_URL || '';
  return String(raw).trim() || null;
}

function configuredFromAddress() {
  const raw = process.env.ERAS_MAIL_FROM || env.ERAS_MAIL_FROM || '';
  return String(raw).trim() || null;
}

function fromAddress() {
  return configuredFromAddress() || DEFAULT_FROM_ADDRESS;
}

/**
 * Safe, non-sensitive diagnostics for email transport configuration.
 * Never exposes API keys, SMTP credentials, sender addresses, or OTP codes.
 */
function getTransportDiagnostics() {
  const hasResend = Boolean(resendApiKey());
  const hasSmtp = Boolean(smtpUrl());
  const configured = hasResend || hasSmtp;

  let provider = 'unconfigured';
  let transport = 'unconfigured';
  if (hasResend) {
    provider = 'Resend';
    transport = 'resend';
  } else if (hasSmtp) {
    provider = 'SMTP';
    transport = 'smtp';
  }

  return {
    configured,
    transportConfigured: configured ? 'yes' : 'no',
    provider,
    transport,
    fromConfigured: configuredFromAddress() ? 'yes' : 'no',
  };
}

function escapeHtml(value) {
  return String(value ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

function extractFirstName(nameOrUser) {
  const rawName =
    nameOrUser && typeof nameOrUser === 'object' ? nameOrUser.name : nameOrUser;
  if (typeof rawName !== 'string') return 'there';
  const trimmed = rawName.trim();
  if (!trimmed) return 'there';
  return trimmed.split(/\s+/)[0];
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

function brandedMessageHtml({ title, paragraphs, footer }) {
  const bodyParagraphs = (paragraphs || [])
    .map(
      (p) =>
        `<p style="margin:0 0 14px;font-size:14px;line-height:1.6;color:#a9b6d3;">${p}</p>`
    )
    .join('\n            ');

  return `<!doctype html>
<html>
  <body style="margin:0;padding:24px;background:#0b1220;font-family:Segoe UI,Roboto,Helvetica,Arial,sans-serif;">
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0">
      <tr><td align="center">
        <table role="presentation" width="520" cellpadding="0" cellspacing="0"
               style="background:#111a2e;border:1px solid #1f2b45;border-radius:14px;padding:28px;">
          <tr><td>
            <div style="font-size:13px;letter-spacing:2px;color:#39d0c8;font-weight:700;">ERAS</div>
            <h1 style="margin:10px 0 12px;font-size:20px;color:#eaf0ff;">${title}</h1>
            ${bodyParagraphs}
            <p style="margin:18px 0 0;font-size:12px;line-height:1.5;color:#67748f;">${footer}</p>
          </td></tr>
        </table>
      </td></tr>
    </table>
  </body>
</html>`;
}

function verificationEmail(code) {
  const ttlMinutes = env.EMAIL_VERIFICATION_TTL_MINUTES || 30;
  return {
    subject: 'ERAS: confirm your email address',
    text:
      `Welcome to ERAS (Emergency Resource Allocation System).\n\n` +
      `Your 6-digit ERAS email verification code is ${code}.\n` +
      `Enter this code in ERAS to verify your email address and finish creating your account.\n` +
      `It expires in ${ttlMinutes} minutes and can be used once.\n\n` +
      `If you did not create an ERAS account you can ignore this email.`,
    html: brandedHtml({
      title: 'Welcome to ERAS — confirm your email address',
      intro:
        'Welcome to ERAS (Emergency Resource Allocation System). Enter this one-time 6-digit verification code in ERAS to finish creating your account:',
      code,
      footer: `The code expires in ${ttlMinutes} minutes and works once. You can request a new code from ERAS if it expires.`,
    }),
  };
}

function welcomeEmail(nameOrUser) {
  const firstName = extractFirstName(nameOrUser);
  const safeFirstName = escapeHtml(firstName);

  return {
    subject: 'Welcome to ERAS — your account is verified',
    text:
      `Welcome to ERAS, ${firstName}.\n\n` +
      `Your email address has been verified and your ERAS account is now ready to use.\n\n` +
      `Thank you for joining ERAS, the Emergency Resource Allocation System.`,
    html: brandedMessageHtml({
      title: `Welcome to ERAS, ${safeFirstName}.`,
      paragraphs: [
        'Your email address has been verified and your ERAS account is now ready to use.',
        'Thank you for joining ERAS, the Emergency Resource Allocation System.',
      ],
      footer: 'ERAS (Emergency Resource Allocation System)',
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

function sanitizeDeliveryError(message, { to } = {}) {
  if (!message || typeof message !== 'string') return 'Unknown delivery error';
  let sanitized = message;
  const key = resendApiKey();
  const smtp = smtpUrl();
  if (key) sanitized = sanitized.split(key).join('[REDACTED]');
  if (smtp) sanitized = sanitized.split(smtp).join('[REDACTED]');
  if (to && typeof to === 'string') sanitized = sanitized.split(to).join('[REDACTED]');
  sanitized = sanitized.replace(/smtps?:\/\/[^\s]+/gi, '[REDACTED_SMTP_URL]');
  sanitized = sanitized.replace(/\bre_[A-Za-z0-9_]+\b/g, '[REDACTED_API_KEY]');
  return sanitized;
}

async function sendWithResend({ to, subject, text, html }) {
  const apiKey = resendApiKey();
  const response = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      // Read from the environment only - never logged, never hardcoded.
      Authorization: `Bearer ${apiKey}`,
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
  return {
    delivered: true,
    deliveryResult: 'success',
    transport: 'resend',
    provider: 'Resend',
    transportConfigured: 'yes',
  };
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

  const transport = nodemailer.createTransport(smtpUrl());
  await transport.sendMail({
    from: `${FROM_NAME} <${fromAddress()}>`,
    to,
    subject,
    text,
    html,
  });
  return {
    delivered: true,
    deliveryResult: 'success',
    transport: 'smtp',
    provider: 'SMTP',
    transportConfigured: 'yes',
  };
}

/**
 * Send one transactional ERAS email. Never throws: delivery failures are logged
 * without the address, secret, or code, and reported to the caller as
 * `{ delivered: false, deliveryResult: 'failure', ... }`.
 */
async function send({ to, subject, text, html }) {
  const diagnostics = getTransportDiagnostics();
  try {
    if (resendApiKey()) {
      return await sendWithResend({ to, subject, text, html });
    }
    if (smtpUrl()) {
      return await sendWithSmtp({ to, subject, text, html });
    }

    // No transport configured. The code is NEVER logged; only the fact that a
    // message could not be delivered.
    logger.warn('email.transport_unconfigured', {
      subject,
      transportConfigured: 'no',
      provider: 'unconfigured',
      deliveryResult: 'failure',
    });
    return {
      delivered: false,
      deliveryResult: 'failure',
      transport: 'unconfigured',
      provider: 'unconfigured',
      transportConfigured: 'no',
    };
  } catch (error) {
    logger.error('email.delivery_failed', {
      subject,
      transportConfigured: diagnostics.transportConfigured,
      provider: diagnostics.provider,
      deliveryResult: 'failure',
      message: sanitizeDeliveryError(error?.message, { to }),
    });
    return {
      delivered: false,
      deliveryResult: 'failure',
      transport: 'failed',
      provider: diagnostics.provider,
      transportConfigured: diagnostics.transportConfigured,
    };
  }
}

function sendVerificationCode(to, code) {
  return emailService.send({ to, ...verificationEmail(code) });
}

function sendWelcomeEmail(toOrUser, nameOrUser) {
  if (toOrUser && typeof toOrUser === 'object') {
    return emailService.send({
      to: toOrUser.email,
      ...welcomeEmail(toOrUser),
    });
  }
  return emailService.send({
    to: toOrUser,
    ...welcomeEmail(nameOrUser),
  });
}

function sendPasswordResetCode(to, code) {
  return emailService.send({ to, ...passwordResetEmail(code) });
}

const emailService = {
  FROM_NAME,
  extractFirstName,
  getTransportDiagnostics,
  verificationEmail,
  welcomeEmail,
  passwordResetEmail,
  send,
  sendVerificationCode,
  sendWelcomeEmail,
  sendPasswordResetCode,
};

module.exports = emailService;
