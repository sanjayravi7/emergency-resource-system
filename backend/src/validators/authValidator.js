const PUBLIC_REGISTRATION_ROLES = ['REQUESTER', 'RESPONDER'];
const EMAIL_RE = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;
const CODE_RE = /^\d{6}$/;

function validateEmail(email) {
  if (!email || typeof email !== 'string' || !email.trim()) return 'Email is required';
  if (email.trim().length > 254 || !EMAIL_RE.test(email.trim())) {
    return 'Enter a valid email address';
  }
  return null;
}

function validateRegister(data = {}) {
  const { name, email, password, phone, role } = data;
  const normalizedRole = typeof role === 'string' ? role.trim() : '';

  if (!normalizedRole) return 'Choose how you want to use ERAS';
  if (!PUBLIC_REGISTRATION_ROLES.includes(normalizedRole)) return 'Invalid role selection';
  if (!name || typeof name !== 'string' || !name.trim()) return 'Name is required';
  if (name.trim().length > 120) return 'Name is too long';
  const emailError = validateEmail(email);
  if (emailError) return emailError;
  if (!password || typeof password !== 'string') return 'Password is required';
  if (password.length < 6) return 'Password must be at least 6 characters';
  if (password.length > 72) return 'Password is too long';
  if (phone && (typeof phone !== 'string' || phone.length > 20)) return 'Invalid phone number';
  return null;
}

function validateLogin(data = {}) {
  const emailError = validateEmail(data.email);
  if (emailError) return emailError;
  if (!data.password || typeof data.password !== 'string') return 'Password is required';
  return null;
}

function validateGoogle(data = {}) {
  if (!data.idToken || typeof data.idToken !== 'string' || data.idToken.length > 12000) {
    return 'Google sign-in could not be verified';
  }
  if (data.intent !== 'login' && data.intent !== 'register') {
    return 'Choose Google login or registration';
  }
  if (data.intent === 'register') {
    const role = typeof data.role === 'string' ? data.role.trim() : '';
    if (!role) return 'Choose how you want to use ERAS';
    if (!PUBLIC_REGISTRATION_ROLES.includes(role)) return 'Invalid role selection';
  }
  return null;
}

function validateEmailCode(data = {}) {
  const emailError = validateEmail(data.email);
  if (emailError) return emailError;
  if (!CODE_RE.test(String(data.code || ''))) return 'Enter the 6-digit code';
  return null;
}

function validateEmailOnly(data = {}) {
  return validateEmail(data.email);
}

function validatePasswordReset(data = {}) {
  const emailError = validateEmailCode(data);
  if (emailError) return emailError;
  if (!data.password || typeof data.password !== 'string') return 'Password is required';
  if (data.password.length < 6) return 'Password must be at least 6 characters';
  if (data.password.length > 72) return 'Password is too long';
  return null;
}

module.exports = {
  validateRegister,
  validateLogin,
  validateGoogle,
  validateEmailCode,
  validateEmailOnly,
  validatePasswordReset,
};
