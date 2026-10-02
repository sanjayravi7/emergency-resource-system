// Server-side request validation for every authentication endpoint.
//
// The Flutter client performs the same checks for instant feedback, but nothing
// here relies on that: malformed input is rejected (or normalized) again on the
// server before it reaches PostgreSQL. Messages are intentionally format-only
// ("Enter a valid email address"), never account-existence hints.

const { isValidEmail, normalizeEmail } = require('../domain/emailValidation');

// Mirror of the service-level allowlist: public registration may only choose
// REQUESTER or RESPONDER. ADMIN and any other value are rejected here with a
// user-facing message; authService.registerUser enforces the same rule as the
// actual security boundary.
const PUBLIC_REGISTRATION_ROLES = ['REQUESTER', 'RESPONDER'];

const MAX_NAME_LENGTH = 120;
const MAX_PHONE_LENGTH = 20;
const MIN_PASSWORD_LENGTH = 6;
const MAX_PASSWORD_LENGTH = 128;
const MAX_ID_TOKEN_LENGTH = 8192;
const CODE_PATTERN = /^\d{6}$/;

function validateRegister(data) {
  if (!data || typeof data !== 'object') {
    return 'Request body is required';
  }

  const { name, email, password, phone, role } = data;

  const normalizedRole =
    typeof role === 'string' ? role.trim() : '';

  if (!normalizedRole) {
    return 'Choose how you want to use ERAS';
  }

  if (!PUBLIC_REGISTRATION_ROLES.includes(normalizedRole)) {
    return 'Invalid role selection';
  }

  if (!name || typeof name !== 'string' || !name.trim()) {
    return 'Name is required';
  }

  if (name.trim().length > MAX_NAME_LENGTH) {
    return 'Name is too long';
  }

  if (!email || typeof email !== 'string' || !email.trim()) {
    return 'Email is required';
  }

  if (!isValidEmail(email)) {
    return 'Enter a valid email address';
  }

  if (!password || typeof password !== 'string') {
    return 'Password is required';
  }

  if (password.length < MIN_PASSWORD_LENGTH) {
    return `Password must be at least ${MIN_PASSWORD_LENGTH} characters`;
  }

  if (password.length > MAX_PASSWORD_LENGTH) {
    return 'Password is too long';
  }

  if (phone !== undefined && phone !== null) {
    if (typeof phone !== 'string' || phone.trim().length > MAX_PHONE_LENGTH) {
      return 'Invalid phone number';
    }
  }

  return null;
}

function validateLogin(data) {
  if (!data || typeof data !== 'object') {
    return 'Request body is required';
  }

  const { email, password } = data;

  if (!email || typeof email !== 'string' || !email.trim()) {
    return 'Email is required';
  }

  if (!isValidEmail(email)) {
    return 'Enter a valid email address';
  }

  if (!password || typeof password !== 'string') {
    return 'Password is required';
  }

  return null;
}

/**
 * Google sign-in payload. The ID token is opaque to this layer (it is verified
 * cryptographically later); only its presence/shape is checked here.
 */
function validateGoogleSignIn(data) {
  if (!data || typeof data !== 'object') {
    return 'Request body is required';
  }

  const { idToken, role } = data;

  if (!idToken || typeof idToken !== 'string' || !idToken.trim()) {
    return 'Google sign-in token is required';
  }

  if (idToken.length > MAX_ID_TOKEN_LENGTH) {
    return 'Google sign-in token is invalid';
  }

  if (role !== undefined && role !== null && role !== '') {
    const normalized = typeof role === 'string' ? role.trim() : '';
    if (!PUBLIC_REGISTRATION_ROLES.includes(normalized)) {
      return 'Invalid role selection';
    }
  }

  return null;
}

/** Email-only requests (resend verification, password reset request). */
function validateVerificationRequest(data) {
  if (!data || typeof data !== 'object') {
    return 'Request body is required';
  }

  const email = typeof data.email === 'string' ? data.email : '';
  if (!email.trim()) return 'Email is required';
  if (!isValidEmail(email)) return 'Enter a valid email address';

  return null;
}

/** A 6-digit code, optionally with the email it belongs to. */
function validateCodeSubmission(data, { requireEmail = false } = {}) {
  if (!data || typeof data !== 'object') {
    return 'Request body is required';
  }

  if (requireEmail) {
    const emailError = validateVerificationRequest(data);
    if (emailError) return emailError;
  }

  const code = data.code ?? data.resetCode ?? data.verificationCode;
  if (code === undefined || code === null || String(code).trim() === '') {
    return 'Enter the 6-digit code';
  }

  if (!CODE_PATTERN.test(String(code).trim())) {
    return 'Enter the 6-digit code';
  }

  return null;
}

/** Full password reset submission (email + code + new password). */
function validatePasswordReset(data) {
  if (!data || typeof data !== 'object') {
    return 'Request body is required';
  }

  const codeError = validateCodeSubmission(data, { requireEmail: true });
  if (codeError) return codeError;

  const { password, confirmPassword } = data;

  if (!password || typeof password !== 'string') {
    return 'Password is required';
  }
  if (password.length < MIN_PASSWORD_LENGTH) {
    return `Password must be at least ${MIN_PASSWORD_LENGTH} characters`;
  }
  if (password.length > MAX_PASSWORD_LENGTH) {
    return 'Password is too long';
  }
  if (confirmPassword === undefined || confirmPassword === null || confirmPassword === '') {
    return 'Confirm your new password';
  }
  if (password !== confirmPassword) {
    return 'Passwords do not match';
  }

  return null;
}

module.exports = {
  PUBLIC_REGISTRATION_ROLES,
  MAX_NAME_LENGTH,
  MAX_PHONE_LENGTH,
  MIN_PASSWORD_LENGTH,
  MAX_PASSWORD_LENGTH,
  validateRegister,
  validateLogin,
  validateGoogleSignIn,
  validateVerificationRequest,
  validateCodeSubmission,
  validatePasswordReset,
  // Re-exported so services/tests share one normalization implementation.
  normalizeEmail,
};
