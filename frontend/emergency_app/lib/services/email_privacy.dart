/// Shared email masking for ERAS surfaces.
///
/// ERAS never shows another person's complete email address: the local part is
/// reduced to its first character followed by masked characters, while the
/// domain is preserved so a reader can still see which provider the address
/// belongs to.
///
///   athulkrishna4155@gmail.com  ->  a***************@gmail.com
///   sanjayravit7@gmail.com      ->  s***********@gmail.com
///   lonelyoneindarkness@x.com   ->  l****************@x.com
///
/// The helper mirrors `backend/src/domain/emailMasking.js`, which applies the
/// same rule at the API serialization boundary. Client-side masking is the
/// second layer: it keeps a widget from rendering an address that a future
/// payload (or a direct widget test) might still carry in full.
///
/// Hard rules:
///   * never throws - null, empty and malformed input produce an empty string;
///   * the domain is preserved verbatim;
///   * only the first character of the local part survives;
///   * the number of mask characters is bounded, so a hostile local part
///     cannot blow up a layout.
library;

import 'dart:math' as math;

/// Upper bound on the number of `*` characters emitted for one local part.
const int erasMaxMaskCharacters = 16;

/// Longest address ERAS will attempt to mask (RFC 5321 practical limit).
const int _maxEmailLength = 254;

String _repeat(String value, int count) =>
    count <= 0 ? '' : List<String>.filled(count, value).join();

/// Masks one email address for display.
///
/// Returns an empty string when there is nothing maskable: null, blank, or not
/// an `a@b.c` shaped address. Nothing that looks like a usable address is ever
/// returned unmasked.
String maskEmail(String? email) {
  final trimmed = email?.trim() ?? '';
  if (trimmed.isEmpty || trimmed.length > _maxEmailLength) return '';

  final separator = trimmed.lastIndexOf('@');
  if (separator <= 0 || separator == trimmed.length - 1) return '';

  final local = trimmed.substring(0, separator);
  final domain = trimmed.substring(separator + 1);
  if (domain.isEmpty || !domain.contains('.') || domain.startsWith('.')) {
    return '';
  }

  final hidden =
      math.min(math.max(local.length - 1, 1), erasMaxMaskCharacters);
  return '${local.substring(0, 1)}${_repeat('*', hidden)}@$domain';
}

/// The email value a screen may render for one ERAS account.
///
/// [isOwnAccount] keeps the signed-in user's own address readable (their own
/// profile, their own emergency); every other account is masked. [fallback] is
/// used when there is nothing to show, so callers never render an empty row.
///
/// Authentication is unaffected: login, OTP and account recovery use the real
/// address from the API/auth layer, never this display helper.
String displayEmailForOthers(
  String? email, {
  bool isOwnAccount = false,
  String fallback = '',
}) {
  final trimmed = email?.trim() ?? '';
  if (trimmed.isEmpty) return fallback;
  if (isOwnAccount) return trimmed;

  final masked = maskEmail(trimmed);
  return masked.isEmpty ? fallback : masked;
}
