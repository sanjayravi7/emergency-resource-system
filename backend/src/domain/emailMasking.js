// ---------------------------------------------------------------------------
// EMAIL MASKING (shared display privacy helper)
//
// ERAS never shows another person's complete email address on a shared
// screen: the local part is reduced to its first character followed by masked
// characters, while the domain is preserved so a reader can still tell which
// service the address belongs to.
//
//   athulkrishna4155@gmail.com  ->  a***************@gmail.com
//   sanjayravit7@gmail.com      ->  s***********@gmail.com
//   lonelyoneindarkness@x.com   ->  l****************@x.com
//
// Rules enforced here (and mirrored by lib/services/email_privacy.dart in
// Flutter so the client never renders a value the server would not send):
//
//   * never throws: null, empty and malformed input yield `null`, never an
//     exception, never a partially leaked address;
//   * the domain is preserved verbatim (case included);
//   * only the first character of the local part survives;
//   * the number of mask characters is bounded, so a hostile or absurd local
//     part cannot blow up a layout or a log line.
//
// This module is deliberately dependency free and side-effect free so it can
// be unit tested without PostgreSQL and reused by every serializer.
// ---------------------------------------------------------------------------

/** Upper bound on the number of `*` characters emitted for one local part. */
const MAX_MASK_CHARACTERS = 16;

/** Longest address ERAS will attempt to mask (RFC 5321 practical limit). */
const MAX_EMAIL_LENGTH = 254;

/**
 * Mask one email address for display on a shared screen.
 *
 * @param {unknown} value
 * @returns {string|null} the masked address, or null when there is nothing
 *   maskable (null, empty, or not an `a@b.c` shaped address).
 */
function maskEmail(value) {
  if (typeof value !== 'string') return null;

  const trimmed = value.trim();
  if (!trimmed || trimmed.length > MAX_EMAIL_LENGTH) return null;

  const separator = trimmed.lastIndexOf('@');
  if (separator <= 0 || separator === trimmed.length - 1) return null;

  const local = trimmed.slice(0, separator);
  const domain = trimmed.slice(separator + 1);

  // A domain without a dot is not a usable mail domain: refuse instead of
  // rendering something that looks like a complete address.
  if (!local || !domain || !domain.includes('.') || domain.startsWith('.')) {
    return null;
  }

  const hidden = Math.min(Math.max(local.length - 1, 1), MAX_MASK_CHARACTERS);
  return `${local.slice(0, 1)}${'*'.repeat(hidden)}@${domain}`;
}

/**
 * Mask one email address, falling back to [fallback] when there is nothing
 * maskable. Serializers use this so a masked payload always carries a string.
 */
function maskEmailOrFallback(value, fallback = '***') {
  return maskEmail(value) ?? fallback;
}

/**
 * True when [value] looks like an address ERAS would mask (i.e. it is
 * maskable). Used by callers that want to keep an unmaskable value untouched
 * instead of replacing it with a fallback.
 */
function isMaskableEmail(value) {
  return maskEmail(value) !== null;
}

module.exports = {
  MAX_MASK_CHARACTERS,
  MAX_EMAIL_LENGTH,
  maskEmail,
  maskEmailOrFallback,
  isMaskableEmail,
};
