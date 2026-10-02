/// Client-side email validation that mirrors the backend rules
/// (`backend/src/domain/emailValidation.js`) so the user gets instant feedback
/// while the server stays the single authority.
///
/// Deliberately NO mailbox probing / SMTP checks: validity is a syntax and
/// length question only. The client never asks whether an address exists.
library;

const int maxEmailLength = 254;
const int maxLocalPartLength = 64;

/// Pragmatic syntax check: exactly one @, non-empty local part without leading,
/// trailing or doubled dots, a domain with at least one dot and an alphabetic
/// TLD of 2+ characters. Same shape as the server-side pattern.
final RegExp _emailPattern = RegExp(
  r"^[A-Za-z0-9!#$%&'*+/=?^_`{|}~-]+(?:\.[A-Za-z0-9!#$%&'*+/=?^_`{|}~-]+)*"
  r'@(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$',
);

/// Trim + lowercase, exactly like the server-side normalization.
String normalizeEmail(String? email) => (email ?? '').trim().toLowerCase();

/// Full server-parity validation for an already or not-yet normalized address.
bool isValidEmail(String? email) {
  final normalized = normalizeEmail(email);
  if (normalized.isEmpty || normalized.length > maxEmailLength) return false;

  final atIndex = normalized.lastIndexOf('@');
  if (atIndex <= 0) return false;

  final localPart = normalized.substring(0, atIndex);
  if (localPart.length > maxLocalPartLength) return false;

  // Whitespace, control characters and a literal query string are never valid.
  if (RegExp(r'\s').hasMatch(normalized)) return false;
  if (RegExp(r'[\u0000-\u001f\u007f]').hasMatch(normalized)) return false;

  return _emailPattern.hasMatch(normalized);
}
