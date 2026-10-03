// ---------------------------------------------------------------------------
// ERAS EMAIL DELIVERY (provider abstraction)
//
// ERAS-branded transactional email for email verification, post-verification
// welcome confirmation, and password reset.
// Nothing here impersonates Firebase or Google: the sender name, subject and
// body are clearly ERAS, and the recipient's ERAS action is described
// explicitly.
//
// Transports (in order):
//   1. RESEND_API_KEY -> Resend HTTPS API
//   2. SMTP_URL       -> SMTP fallback if Resend is absent or rejects the request
//   3. unconfigured   -> logged safe failure
//
// ERAS_MAIL_FROM must be a bare syntactically valid sender address. There is no
// invented default sender: Resend rejects local/example senders, so missing or
// malformed configuration is surfaced before a provider call. Provider 2xx
// means request accepted, not confirmed inbox delivery. Secrets, OTPs, sender
// addresses and recipient addresses are never included in logs.
// ---------------------------------------------------------------------------

const env = require('../config/env');
const logger = require('../config/logger');
const { isValidEmail } = require('../domain/emailValidation');

const FROM_NAME = 'ERAS (Emergency Resource Allocation System)';

function environmentValue(name) {
  const raw = Object.prototype.hasOwnProperty.call(process.env, name)
    ? process.env[name]
    : env[name];
  if (typeof raw !== 'string') return null;
  return raw.trim() || null;
}

function resendApiKey() {
  return environmentValue('RESEND_API_KEY');
}

function smtpUrl() {
  return environmentValue('SMTP_URL');
}

function configuredFromAddress() {
  return environmentValue('ERAS_MAIL_FROM');
}

function senderIsValid(address = configuredFromAddress()) {
  return Boolean(address && isValidEmail(address));
}

function safeProviderValue(value) {
  if (typeof value !== 'string') return null;
  const normalized = value.trim();
  if (!normalized || normalized.length > 100) return null;
  if (!/^[A-Za-z0-9_.:-]+$/.test(normalized)) return null;
  if (/^\d{6}$/.test(normalized) || /@/.test(normalized)) return null;
  return normalized;
}

function configuredTransports() {
  const transports = [];
  if (resendApiKey()) transports.push({ name: 'Resend', transport: 'resend' });
  if (smtpUrl()) transports.push({ name: 'SMTP', transport: 'smtp' });
  return transports;
}

/**
 * Safe, non-sensitive diagnostics for email transport configuration.
 * Never exposes API keys, SMTP credentials, sender addresses, or OTP codes.
 */
function getTransportDiagnostics() {
  const transports = configuredTransports();
  const hasResend = transports.some((item) => item.transport === 'resend');
  const hasSmtp = transports.some((item) => item.transport === 'smtp');
  const from = configuredFromAddress();
  const configured = transports.length > 0;

  return {
    configured,
    transportConfigured: configured ? 'yes' : 'no',
    provider: transports[0]?.name || 'unconfigured',
    transport: transports[0]?.transport || 'unconfigured',
    fromConfigured: from ? 'yes' : 'no',
    senderValid: senderIsValid(from) ? 'yes' : 'no',
    smtpFallbackConfigured: hasResend && hasSmtp ? 'yes' : 'no',
    configurationError: !configured
      ? 'EMAIL_TRANSPORT_UNCONFIGURED'
      : !from
        ? 'ERAS_MAIL_FROM_UNCONFIGURED'
        : !senderIsValid(from)
          ? 'ERAS_MAIL_FROM_INVALID'
          : null,
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

function sanitizeDeliveryError(message) {
  if (!message || typeof message !== 'string') return null;
  let sanitized = message;
  const key = resendApiKey();
  const smtp = smtpUrl();
  if (key) sanitized = sanitized.split(key).join('[REDACTED_PROVIDER_SECRET]');
  if (smtp) sanitized = sanitized.split(smtp).join('[REDACTED_SMTP_URL]');
  sanitized = sanitized.replace(/smtps?:\/\/[^\s]+/gi, '[REDACTED_SMTP_URL]');
  sanitized = sanitized.replace(/\bre_[A-Za-z0-9_-]+\b/gi, '[REDACTED_PROVIDER_SECRET]');
  sanitized = sanitized.replace(/\bBearer\s+\S+/gi, 'Bearer [REDACTED]');
  sanitized = sanitized.replace(
    /\b(?:password|passwd|pass|username|user|authorization|api[_-]?key|secret)\s*[:=]\s*[^\s,;]+/gi,
    '[REDACTED_CREDENTIAL]',
  );
  sanitized = sanitized.replace(
    /[A-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Z0-9](?:[A-Z0-9-]{0,61}[A-Z0-9])?(?:\.[A-Z0-9](?:[A-Z0-9-]{0,61}[A-Z0-9])?)+/gi,
    '[REDACTED_EMAIL]',
  );
  sanitized = sanitized.replace(/\b\d{6}\b/g, '[REDACTED_CODE]');
  sanitized = sanitized.replace(
    /\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b/g,
    '[REDACTED_TOKEN]',
  );
  sanitized = sanitized.replace(/[\x00-\x1F\x7F]/g, ' ').replace(/\s+/g, ' ').trim();
  return sanitized ? sanitized.slice(0, 300) : null;
}

function responsePayloadError(payload) {
  if (!payload || typeof payload !== 'object') return {};
  const nested = payload.error && typeof payload.error === 'object'
    ? payload.error
    : payload;
  return {
    providerErrorCode:
      safeProviderValue(nested.code) ||
      safeProviderValue(nested.errorCode) ||
      safeProviderValue(nested.name),
    providerErrorType: safeProviderValue(nested.type),
    providerErrorMessage: sanitizeDeliveryError(
      typeof nested.message === 'string' ? nested.message : null,
    ),
  };
}

function responseMessageId(payload) {
  if (!payload || typeof payload !== 'object') return null;
  const id = payload.id ?? payload.messageId;
  // Message identifiers are useful for provider-side support and contain no
  // recipient address. Reject unexpected formats instead of logging them.
  if (typeof id !== 'string' || id.length > 128) return null;
  return /^[A-Za-z0-9_.:-]+$/.test(id) ? id : null;
}

async function parseResponseJson(response) {
  try {
    return typeof response.json === 'function' ? await response.json() : null;
  } catch {
    return null;
  }
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
      from: `${FROM_NAME} <${configuredFromAddress()}>`,
      to: [to],
      subject,
      text,
      html,
    }),
  });
  const payload = await parseResponseJson(response);

  if (!response.ok) {
    const providerError = responsePayloadError(payload);
    const error = new Error('Provider rejected the email request');
    error.provider = 'Resend';
    error.transport = 'resend';
    error.providerResponseStatus = Number(response.status) || null;
    error.providerErrorCode = providerError.providerErrorCode;
    error.providerErrorType = providerError.providerErrorType;
    error.providerErrorMessage = providerError.providerErrorMessage;
    throw error;
  }

  return {
    deliveryAccepted: true,
    accepted: true,
    delivered: null,
    deliveryConfirmed: false,
    deliveryResult: 'accepted',
    transport: 'resend',
    provider: 'Resend',
    transportConfigured: 'yes',
    providerResponseStatus: Number(response.status) || null,
    messageId: responseMessageId(payload),
  };
}

async function sendWithSmtp({ to, subject, text, html }) {
  // Nodemailer is a regular backend dependency so an explicitly configured
  // SMTP fallback always exists in the deployed build.
  // eslint-disable-next-line global-require
  const nodemailer = require('nodemailer');
  const transport = nodemailer.createTransport(smtpUrl());
  const info = await transport.sendMail({
    from: `${FROM_NAME} <${configuredFromAddress()}>`,
    to,
    subject,
    text,
    html,
  });

  if (Array.isArray(info?.accepted) && info.accepted.length === 0) {
    const error = new Error('SMTP did not accept the recipient');
    error.provider = 'SMTP';
    error.transport = 'smtp';
    error.providerErrorCode = 'SMTP_RECIPIENT_REJECTED';
    error.providerResponseStatus = Number(info?.responseCode) || null;
    throw error;
  }

  const responseText = typeof info?.response === 'string' ? info.response : '';
  const statusMatch = responseText.match(/\b([1-5]\d\d)\b/);
  const responseStatus = Number(info?.responseCode || statusMatch?.[1]) || null;
  const rawMessageId = typeof info?.messageId === 'string' ? info.messageId : null;

  return {
    deliveryAccepted: true,
    accepted: true,
    delivered: null,
    deliveryConfirmed: false,
    deliveryResult: 'accepted',
    transport: 'smtp',
    provider: 'SMTP',
    transportConfigured: 'yes',
    providerResponseStatus: responseStatus,
    messageId: rawMessageId && /^[A-Za-z0-9_.:-]+$/.test(rawMessageId)
      ? rawMessageId
      : null,
  };
}

function failedDelivery({
  provider = 'unconfigured',
  transport = 'unconfigured',
  transportConfigured = 'no',
  deliveryResult = 'failed',
  providerResponseStatus = null,
  providerErrorCode = null,
  providerErrorType = null,
  fallbackUsed = false,
} = {}) {
  return {
    deliveryAccepted: false,
    accepted: false,
    delivered: null,
    deliveryConfirmed: false,
    deliveryResult,
    transport,
    provider,
    transportConfigured,
    providerResponseStatus,
    providerErrorCode: safeProviderValue(providerErrorCode),
    providerErrorType: safeProviderValue(providerErrorType),
    fallbackUsed,
  };
}

/**
 * Send one transactional ERAS email. Never throws. `accepted` means the mail
 * transport accepted the request; final inbox delivery is not knowable from a
 * synchronous Resend/SMTP response and would require delivery webhooks.
 */
async function send({ to, subject, text, html }) {
  const diagnostics = getTransportDiagnostics();
  const transports = configuredTransports();

  if (transports.length === 0) {
    logger.warn('email.transport_unconfigured', {
      transportConfigured: 'no',
      fromConfigured: diagnostics.fromConfigured,
      provider: 'unconfigured',
      deliveryResult: 'unconfigured',
      providerErrorCode: 'EMAIL_TRANSPORT_UNCONFIGURED',
    });
    return failedDelivery({
      deliveryResult: 'unconfigured',
      providerErrorCode: 'EMAIL_TRANSPORT_UNCONFIGURED',
    });
  }

  const from = configuredFromAddress();
  if (!from || !senderIsValid(from)) {
    const providerErrorCode = from
      ? 'ERAS_MAIL_FROM_INVALID'
      : 'ERAS_MAIL_FROM_UNCONFIGURED';
    logger.error('email.configuration_invalid', {
      transportConfigured: diagnostics.transportConfigured,
      fromConfigured: diagnostics.fromConfigured,
      senderValid: diagnostics.senderValid,
      provider: diagnostics.provider,
      deliveryResult: 'failed',
      providerErrorCode,
    });
    return failedDelivery({
      provider: diagnostics.provider,
      transport: diagnostics.transport,
      transportConfigured: diagnostics.transportConfigured,
      providerErrorCode,
    });
  }

  if (typeof to !== 'string' || !isValidEmail(to)) {
    logger.warn('email.request_rejected', {
      transportConfigured: diagnostics.transportConfigured,
      provider: diagnostics.provider,
      deliveryResult: 'failed',
      providerErrorCode: 'ERAS_RECIPIENT_INVALID',
    });
    return failedDelivery({
      provider: diagnostics.provider,
      transport: diagnostics.transport,
      transportConfigured: diagnostics.transportConfigured,
      providerErrorCode: 'ERAS_RECIPIENT_INVALID',
    });
  }

  let lastError = null;
  for (let index = 0; index < transports.length; index += 1) {
    const configured = transports[index];
    try {
      const result = configured.transport === 'resend'
        ? await sendWithResend({ to, subject, text, html })
        : await sendWithSmtp({ to, subject, text, html });
      const fallbackUsed = index > 0;
      const acceptedResult = { ...result, fallbackUsed };

      logger.info('email.delivery_accepted', {
        provider: acceptedResult.provider,
        transport: acceptedResult.transport,
        transportConfigured: 'yes',
        deliveryResult: 'accepted',
        providerResponseStatus: acceptedResult.providerResponseStatus,
        messageId: acceptedResult.messageId,
        fallbackUsed,
      });
      return acceptedResult;
    } catch (error) {
      lastError = error;
      const provider = configured.name;
      const providerErrorCode = safeProviderValue(error?.providerErrorCode) ||
        safeProviderValue(error?.code);
      const providerErrorType = safeProviderValue(error?.providerErrorType) ||
        safeProviderValue(error?.name);
      const providerResponseStatus = Number.isInteger(error?.providerResponseStatus) &&
        error.providerResponseStatus >= 100 && error.providerResponseStatus <= 599
        ? error.providerResponseStatus
        : null;
      const providerErrorMessage = sanitizeDeliveryError(
        error?.providerErrorMessage || error?.message,
      );

      logger.warn('email.provider_delivery_failed', {
        provider,
        transport: configured.transport,
        transportConfigured: 'yes',
        deliveryResult: 'failed',
        providerResponseStatus,
        providerErrorCode,
        providerErrorType,
        providerErrorMessage,
        fallbackAvailable: index + 1 < transports.length,
      });
    }
  }

  return failedDelivery({
    provider: lastError?.provider || transports[transports.length - 1].name,
    transport: lastError?.transport || transports[transports.length - 1].transport,
    transportConfigured: 'yes',
    providerResponseStatus: lastError?.providerResponseStatus,
    providerErrorCode: lastError?.providerErrorCode || lastError?.code,
    providerErrorType: lastError?.providerErrorType || lastError?.name,
    fallbackUsed: transports.length > 1,
  });
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
