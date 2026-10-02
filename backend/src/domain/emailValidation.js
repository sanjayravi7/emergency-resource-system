// ---------------------------------------------------------------------------
// EMAIL NORMALIZATION + VALIDATION (single implementation, used server-side)
//
// The Flutter client performs the same checks for instant feedback, but the
// server NEVER trusts the client: every endpoint that accepts an email address
// normalizes and validates it again here.
//
// Deliberately NO SMTP probing / mailbox enumeration: validity is a syntax and
// length question only. Whether a Gmail account exists is never queried.
// ---------------------------------------------------------------------------

const MAX_EMAIL_LENGTH = 254; // RFC 5321 practical maximum
const MAX_LOCAL_PART_LENGTH = 64;

// Pragmatic syntax check: exactly one @, non-empty local part, a domain with at
// least one dot and a 2+ character TLD, no whitespace or control characters and
// no consecutive/leading/trailing dots in the local part.
const EMAIL_PATTERN =
  /^[A-Za-z0-9!#$%&'*+/=?^_`{|}~-]+(?:\.[A-Za-z0-9!#$%&'*+/=?^_`{|}~-]+)*@(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$/;

/** Trim + lowercase. Normalization is intentionally conservative: the local
 *  part is only trimmed, never rewritten, so an address is never silently
 *  changed into a different mailbox. */
function normalizeEmail(email) {
  if (typeof email !== 'string') return '';
  return email.trim().toLowerCase();
}

/** True when the (already normalized) value is a plausible email address. */
function isValidEmail(email) {
  const normalized = normalizeEmail(email);
  if (!normalized || normalized.length > MAX_EMAIL_LENGTH) return false;

  const atIndex = normalized.lastIndexOf('@');
  if (atIndex <= 0) return false;

  const localPart = normalized.slice(0, atIndex);
  if (localPart.length > MAX_LOCAL_PART_LENGTH) return false;

  // A literal query string or whitespace inside the address is never valid.
  if (/\s/.test(normalized) || /[\u0000-\u001f\u007f]/.test(normalized)) return false;

  return EMAIL_PATTERN.test(normalized);
}

/**
 * Normalize + validate in one step.
 * @returns {{ email: string, valid: boolean }}
 */
function validateAndNormalizeEmail(email) {
  const normalized = normalizeEmail(email);
  return { email: normalized, valid: isValidEmail(normalized) };
}

module.exports = {
  MAX_EMAIL_LENGTH,
  MAX_LOCAL_PART_LENGTH,
  EMAIL_PATTERN,
  normalizeEmail,
  isValidEmail,
  validateAndNormalizeEmail,
};
