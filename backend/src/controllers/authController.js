const {
  registerUser,
  loginUser,
  googleLoginUser,
  resendEmailVerification,
  verifyEmail,
  requestPasswordReset,
  completePasswordReset,
  getCurrentUser,
} = require('../services/authService');

const {
  validateRegister,
  validateLogin,
  validateGoogle,
  validateEmailCode,
  validateEmailOnly,
  validatePasswordReset,
} = require('../validators/authValidator');

function respondForAuthError(error, res, next) {
  const code = error?.code || error?.message;
  const known = {
    EMAIL_ALREADY_EXISTS: [409, 'Email already registered'],
    REGISTRATION_ROLE_REQUIRED: [400, 'Choose how you want to use ERAS'],
    INVALID_REGISTRATION_ROLE: [400, 'Invalid role selection'],
    INVALID_CREDENTIALS: [401, 'Invalid email or password'],
    ACCOUNT_INACTIVE: [403, 'Account is inactive'],
    EMAIL_NOT_VERIFIED: [403, 'Please verify your email before signing in'],
    INVALID_GOOGLE_INTENT: [400, 'Choose Google login or registration'],
    GOOGLE_ACCOUNT_NOT_REGISTERED: [404, 'No ERAS account found. Register with Google first'],
    GOOGLE_ACCOUNT_NOT_LINKED: [409, 'This email already has an ERAS password account. Sign in with email and password'],
    GOOGLE_ACCOUNT_CONFLICT: [409, 'This Google account is linked to a different ERAS account'],
    INVALID_GOOGLE_CREDENTIAL: [401, 'Google sign-in could not be verified'],
    AUTH_CODE_INVALID: [400, 'The code is invalid or expired. Request a new code and try again'],
    AUTH_CODE_RATE_LIMITED: [429, 'Too many codes requested. Try again later'],
    AUTH_EMAIL_NOT_CONFIGURED: [503, 'Email verification and password reset are temporarily unavailable'],
    AUTH_EMAIL_DELIVERY_FAILED: [503, 'The email could not be sent. Please try again later'],
    FIREBASE_AUTH_NOT_CONFIGURED: [503, 'Google sign-in is not configured for this ERAS deployment'],
    FIREBASE_PROJECT_MISMATCH: [503, 'Google sign-in is not configured for this ERAS deployment'],
    FIREBASE_SERVICE_ACCOUNT_UNREADABLE: [503, 'Google sign-in is not configured for this ERAS deployment'],
    FIREBASE_SERVICE_ACCOUNT_INVALID: [503, 'Google sign-in is not configured for this ERAS deployment'],
  };
  const response = known[code];
  if (response) {
    return res.status(response[0]).json({ success: false, message: response[1] });
  }
  return next(error);
}

async function register(req, res, next) {
  try {
    const input = req.body || {};
    const validationError = validateRegister(input);
    if (validationError) {
      return res.status(400).json({ success: false, message: validationError });
    }

    const result = await registerUser(input);
    return res.status(201).json({
      success: true,
      message: 'Account created. Check your email for the 6-digit verification code.',
      data: result,
    });
  } catch (error) {
    return respondForAuthError(error, res, next);
  }
}

async function login(req, res, next) {
  try {
    const input = req.body || {};
    const validationError = validateLogin(input);
    if (validationError) {
      return res.status(400).json({ success: false, message: validationError });
    }

    const result = await loginUser(input);
    return res.status(200).json({
      success: true,
      message: 'Login successful',
      data: result,
    });
  } catch (error) {
    return respondForAuthError(error, res, next);
  }
}

async function google(req, res, next) {
  try {
    const input = req.body || {};
    const validationError = validateGoogle(input);
    if (validationError) {
      return res.status(400).json({ success: false, message: validationError });
    }

    const result = await googleLoginUser(input);
    const isRegistration = input.intent === 'register';
    return res.status(isRegistration ? 201 : 200).json({
      success: true,
      message: isRegistration ? 'Google registration successful' : 'Google login successful',
      data: result,
    });
  } catch (error) {
    return respondForAuthError(error, res, next);
  }
}

async function verifyEmailCode(req, res, next) {
  try {
    const input = req.body || {};
    const validationError = validateEmailCode(input);
    if (validationError) {
      return res.status(400).json({ success: false, message: validationError });
    }
    await verifyEmail(input);
    return res.status(200).json({
      success: true,
      message: 'Email verified. You can now sign in.',
      data: { emailVerified: true },
    });
  } catch (error) {
    return respondForAuthError(error, res, next);
  }
}

async function resendVerificationCode(req, res, next) {
  try {
    const input = req.body || {};
    const validationError = validateEmailOnly(input);
    if (validationError) {
      return res.status(400).json({ success: false, message: validationError });
    }
    await resendEmailVerification(input.email);
    return res.status(200).json({
      success: true,
      message: 'If the account needs verification, a new code has been sent.',
    });
  } catch (error) {
    return respondForAuthError(error, res, next);
  }
}

async function requestPasswordResetCode(req, res, next) {
  try {
    const input = req.body || {};
    const validationError = validateEmailOnly(input);
    if (validationError) {
      return res.status(400).json({ success: false, message: validationError });
    }
    await requestPasswordReset(input.email);
    return res.status(200).json({
      success: true,
      message: 'If the account is eligible, a 6-digit reset code has been sent.',
    });
  } catch (error) {
    return respondForAuthError(error, res, next);
  }
}

async function resetPassword(req, res, next) {
  try {
    const input = req.body || {};
    const validationError = validatePasswordReset(input);
    if (validationError) {
      return res.status(400).json({ success: false, message: validationError });
    }
    await completePasswordReset(input);
    return res.status(200).json({
      success: true,
      message: 'Password reset successfully. Sign in with your new password.',
    });
  } catch (error) {
    return respondForAuthError(error, res, next);
  }
}

async function me(req, res, next) {
  try {
    const user = await getCurrentUser(req.user.userId);
    if (!user) {
      return res.status(404).json({ success: false, message: 'User not found' });
    }
    return res.status(200).json({ success: true, data: { user } });
  } catch (error) {
    return next(error);
  }
}

module.exports = {
  register,
  login,
  google,
  verifyEmailCode,
  resendVerificationCode,
  requestPasswordResetCode,
  resetPassword,
  me,
};
