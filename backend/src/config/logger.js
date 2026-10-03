const env = require('./env');

/**
 * Minimal structured logger for operational observability.
 *
 * Goals (Phase I, Part 11):
 *  - Key lifecycle + security events are diagnosable via stable event names.
 *  - Secrets are never logged. Any field whose key looks sensitive (token,
 *    password, secret, authorization, DATABASE_URL, ...) is redacted, so a
 *    careless caller cannot accidentally leak credentials into the log stream.
 *  - Prefer stable identifiers (requestId, userId, responderId, allocationId)
 *    over free-form personal data.
 *
 * Output is single-line JSON in production (log-aggregator friendly) and a
 * compact human string in development. Tests stay quiet unless LOG_IN_TEST is
 * set, so the suite output is not polluted.
 */

const SENSITIVE_KEY =
  /(pass(word)?|secret|token|authorization|auth|cookie|jwt|database_url|smtp_url|connection|credential|apikey|api_key|private_key|verification_?code|reset_?code|auth_?code|code_?hash|otp|email)/i;

function isSensitiveKeyOrValue(key, val) {
  if (SENSITIVE_KEY.test(key)) return true;
  if (/^code$/i.test(key) && typeof val === 'string' && /^\d{6}$/.test(val.trim())) {
    return true;
  }
  return false;
}

function redact(value, depth = 0) {
  if (value === null || value === undefined) return value;
  if (depth > 4) return '[Truncated]';

  if (Array.isArray(value)) {
    return value.slice(0, 50).map((item) => redact(item, depth + 1));
  }

  if (typeof value === 'object') {
    const out = {};
    for (const [key, val] of Object.entries(value)) {
      if (isSensitiveKeyOrValue(key, val)) {
        out[key] = '[REDACTED]';
      } else {
        out[key] = redact(val, depth + 1);
      }
    }
    return out;
  }

  if (typeof value === 'string' && value.length > 500) {
    return `${value.slice(0, 500)}…`;
  }

  return value;
}

function emit(level, event, meta) {
  if (env.IS_TEST && !process.env.LOG_IN_TEST) return;

  const record = {
    level,
    event,
    time: new Date().toISOString(),
    ...(meta ? redact(meta) : {}),
  };

  const line = env.IS_PRODUCTION
    ? JSON.stringify(record)
    : `[${record.level}] ${record.event} ${meta ? JSON.stringify(redact(meta)) : ''}`.trim();

  if (level === 'error') {
    // eslint-disable-next-line no-console
    console.error(line);
  } else if (level === 'warn') {
    // eslint-disable-next-line no-console
    console.warn(line);
  } else {
    // eslint-disable-next-line no-console
    console.log(line);
  }
}

module.exports = {
  redact,
  info: (event, meta) => emit('info', event, meta),
  warn: (event, meta) => emit('warn', event, meta),
  error: (event, meta) => emit('error', event, meta),
};
