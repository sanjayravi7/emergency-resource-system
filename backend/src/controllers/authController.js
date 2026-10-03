const {
  registerUser,
  loginUser,
  getCurrentUser,
  createTokenForUser,
} = require("../services/authService");

const {
  validateRegister,
  validateLogin,
  validateGoogleSignIn,
  validateVerificationRequest,
  validateCodeSubmission,
  validatePasswordReset,
} = require("../validators/authValidator");

const googleAuthService = require("../services/googleAuthService");
const firebaseTokenService = require("../services/firebaseTokenService");
const emailVerificationService = require("../services/emailVerificationService");
const passwordResetService = require("../services/passwordResetService");
const auditLogService = require("../services/auditLogService");

async function register(req, res, next) {
  try {
    const validationError = validateRegister(req.body);

    if (validationError) {
      return res.status(400).json({
        success: false,
        message: validationError,
      });
    }

    const result = await registerUser(req.body);

    await auditLogService.recordForRequest(req, "USER_REGISTERED", {
      actorId: result.user.id,
      actorRole: result.user.role,
      targetType: "User",
      targetId: result.user.id,
      metadata: { authProvider: "PASSWORD" },
    });

    const message =
      result.emailDelivered === false
        ? "Your account was created, but we couldn't deliver the verification email. You can resend the code."
        : "Registration successful. Check your email to verify your account.";

    return res.status(201).json({
      success: true,
      message,
      data: result,
    });
  } catch (error) {
    if (error.message === "EMAIL_ALREADY_EXISTS") {
      return res.status(409).json({
        success: false,
        message: "Email already registered",
      });
    }

    if (error.message === "INVALID_EMAIL") {
      return res.status(400).json({
        success: false,
        message: "Enter a valid email address",
      });
    }

    if (error.message === "NAME_REQUIRED" || error.message === "INVALID_NAME") {
      return res.status(400).json({
        success: false,
        message: "Enter a valid name",
      });
    }

    if (error.message === "INVALID_PHONE") {
      return res.status(400).json({
        success: false,
        message: "Invalid phone number",
      });
    }

    // Public registration must be able to create REQUESTER/RESPONDER only.
    // ADMIN, empty, and unknown role values are rejected with a 400 before
    // any user record is written.
    if (error.message === "REGISTRATION_ROLE_REQUIRED") {
      return res.status(400).json({
        success: false,
        message: "Choose how you want to use ERAS",
      });
    }

    if (error.message === "INVALID_REGISTRATION_ROLE") {
      return res.status(400).json({
        success: false,
        message: "Invalid role selection",
      });
    }

    next(error);
  }
}

async function login(req, res, next) {
  try {
    const validationError = validateLogin(req.body);

    if (validationError) {
      return res.status(400).json({
        success: false,
        message: validationError,
      });
    }

    const result = await loginUser(req.body);

    await auditLogService.recordForRequest(req, "USER_LOGIN", {
      actorId: result.user.id,
      actorRole: result.user.role,
      targetType: "User",
      targetId: result.user.id,
      metadata: { method: "PASSWORD" },
    });

    return res.status(200).json({
      success: true,
      message: "Login successful",
      data: result,
    });
  } catch (error) {
    if (error.message === "INVALID_CREDENTIALS") {
      // Safe, generic message: it never reveals whether the address exists.
      await auditLogService.recordForRequest(req, "USER_LOGIN_FAILED", {
        metadata: { reason: "INVALID_CREDENTIALS" },
      });
      return res.status(401).json({
        success: false,
        message: "Invalid email or password",
      });
    }

    if (error.message === "ACCOUNT_INACTIVE") {
      await auditLogService.recordForRequest(req, "USER_LOGIN_FAILED", {
        metadata: { reason: "ACCOUNT_INACTIVE" },
      });
      return res.status(403).json({
        success: false,
        message: "Account is inactive",
      });
    }

    next(error);
  }
}

/**
 * GOOGLE REGISTRATION / LOGIN
 *
 * The client performs Firebase/Google authentication and posts the resulting
 * ID token here. The backend verifies the token cryptographically against
 * Google's published certificates, resolves (or safely links/creates) the ERAS
 * user, and only then issues the SAME ERAS JWT used by password login. RBAC,
 * isActive and role always come from PostgreSQL - a Firebase token never grants
 * privileges by itself.
 */
async function googleSignIn(req, res, next) {
  try {
    const validationError = validateGoogleSignIn(req.body);
    if (validationError) {
      return res.status(400).json({ success: false, message: validationError });
    }

    if (!firebaseTokenService.isGoogleAuthConfigured()) {
      return res.status(503).json({
        success: false,
        message: "Google sign-in is not configured on this server",
      });
    }

    let identity;
    try {
      identity = await firebaseTokenService.verifyIdentityToken(req.body.idToken);
    } catch (error) {
      if (error instanceof firebaseTokenService.IdentityTokenError) {
        return res.status(error.statusCode).json({ success: false, message: error.message });
      }
      throw error;
    }

    let resolved;
    try {
      resolved = await googleAuthService.resolveUserFromGoogleIdentity(identity, {
        role: req.body.role,
        name: req.body.name,
        phone: req.body.phone,
      });
    } catch (error) {
      if (error instanceof googleAuthService.GoogleAuthError) {
        return res.status(error.statusCode).json({
          success: false,
          code: error.code,
          message: error.message,
        });
      }
      throw error;
    }

    const token = createTokenForUser(resolved.user);
    const user = googleAuthService.publicUser(resolved.user);

    await auditLogService.recordForRequest(req, resolved.created ? "GOOGLE_REGISTERED" : "GOOGLE_LOGIN", {
      actorId: user.id,
      actorRole: user.role,
      targetType: "User",
      targetId: user.id,
      metadata: {
        provider: identity.provider,
        linkedExistingAccount: resolved.linked,
      },
    });

    return res.status(200).json({
      success: true,
      message: resolved.created ? "Google registration successful" : "Google login successful",
      data: {
        user,
        token,
        created: resolved.created,
        linked: resolved.linked,
        // Google identities are verified by Google: no ERAS verification email
        // is required for them.
        verificationRequired: false,
      },
    });
  } catch (error) {
    next(error);
  }
}

/**
 * Confirm the ERAS email verification code (email/password accounts).
 * Requires authentication so the code always belongs to a known session.
 */
async function verifyEmail(req, res, next) {
  try {
    const validationError = validateCodeSubmission(req.body);
    if (validationError) {
      return res.status(400).json({ success: false, message: validationError });
    }

    const result = await emailVerificationService.confirmVerification(
      req.user.id,
      req.body.code
    );

    if (!result.ok) {
      await auditLogService.recordForRequest(req, "EMAIL_VERIFICATION_FAILED", {
        metadata: { reason: result.reason },
      });
      return res.status(400).json({
        success: false,
        message: "That verification code is invalid or has expired",
      });
    }

    await auditLogService.recordForRequest(req, "EMAIL_VERIFIED", {
      metadata: { alreadyVerified: Boolean(result.alreadyVerified) },
    });

    const user = await getCurrentUser(req.user.id);
    return res.status(200).json({ success: true, data: { user } });
  } catch (error) {
    next(error);
  }
}

/**
 * Resend the verification email. The response is deliberately identical for
 * registered and unknown addresses (no account enumeration) and the per-user
 * cooldown / rate limit are enforced by authCodeService.
 */
async function resendVerification(req, res, next) {
  try {
    const validationError = validateVerificationRequest(req.body);
    if (validationError) {
      return res.status(400).json({ success: false, message: validationError });
    }

    const result = await emailVerificationService.resendVerificationForEmail(req.body.email);

    if (result.sent) {
      await auditLogService.recordForRequest(req, "EMAIL_VERIFICATION_RESENT", {
        targetType: "User",
      });
    }

    return res.status(200).json({
      success: true,
      // Generic message: identical for every outcome.
      message:
        "If an ERAS account exists for that email address, a verification email has been sent.",
      retryAfterSeconds: result.retryAfterSeconds || null,
    });
  } catch (error) {
    next(error);
  }
}

/** Step 1 of the password reset flow: request a 6-digit code by email. */
async function requestPasswordReset(req, res, next) {
  try {
    const validationError = validateVerificationRequest(req.body);
    if (validationError) {
      return res.status(400).json({ success: false, message: validationError });
    }

    const result = await passwordResetService.requestPasswordReset(req.body.email);

    await auditLogService.recordForRequest(req, "PASSWORD_RESET_REQUESTED", {
      metadata: { delivered: Boolean(result.sent) },
    });

    return res.status(200).json({
      success: true,
      message: result.message,
      retryAfterSeconds: result.retryAfterSeconds ?? null,
    });
  } catch (error) {
    next(error);
  }
}

/** Step 2: verify the 6-digit code (without consuming it) for instant feedback. */
async function verifyPasswordResetCode(req, res, next) {
  try {
    const validationError = validateCodeSubmission(req.body, { requireEmail: true });
    if (validationError) {
      return res.status(400).json({ success: false, message: validationError });
    }

    await passwordResetService.verifyResetCode(req.body.email, req.body.code);

    return res.status(200).json({ success: true, message: "Code verified" });
  } catch (error) {
    if (error instanceof passwordResetService.PasswordResetError) {
      await auditLogService.recordForRequest(req, "PASSWORD_RESET_CODE_REJECTED", {
        metadata: { reason: error.code },
      });
      return res.status(error.statusCode).json({ success: false, message: error.message });
    }
    next(error);
  }
}

/** Step 3: set the new password (consumes the code, invalidates old sessions). */
async function resetPassword(req, res, next) {
  try {
    const validationError = validatePasswordReset(req.body);
    if (validationError) {
      return res.status(400).json({ success: false, message: validationError });
    }

    const result = await passwordResetService.resetPassword({
      email: req.body.email,
      code: req.body.code,
      password: req.body.password,
      confirmPassword: req.body.confirmPassword,
    });

    await auditLogService.recordForRequest(req, "PASSWORD_RESET_COMPLETED", {
      actorId: result.userId,
      targetType: "User",
      targetId: result.userId,
    });

    return res.status(200).json({
      success: true,
      message: "Your password has been updated. Please sign in.",
    });
  } catch (error) {
    if (error instanceof passwordResetService.PasswordResetError) {
      if (error.code === 'INVALID_CODE' || error.code === 'TOO_MANY_ATTEMPTS') {
        await auditLogService.recordForRequest(req, "PASSWORD_RESET_CODE_REJECTED", {
          metadata: { reason: error.code },
        });
      }
      return res.status(error.statusCode).json({ success: false, message: error.message });
    }
    next(error);
  }
}

/** Explicit logout audit (the JWT itself is stateless and dropped client-side). */
async function logout(req, res, next) {
  try {
    await auditLogService.recordForRequest(req, "USER_LOGOUT", {
      targetType: "User",
      targetId: req.user?.id ?? null,
    });
    return res.status(200).json({ success: true, message: "Signed out" });
  } catch (error) {
    next(error);
  }
}

async function me(req, res, next) {
  try {
    const user = await getCurrentUser(req.user.userId);

    if (!user) {
      return res.status(404).json({
        success: false,
        message: "User not found",
      });
    }

    return res.status(200).json({
      success: true,
      data: {
        user,
      },
    });
  } catch (error) {
    next(error);
  }
}

module.exports = {
  register,
  login,
  googleSignIn,
  verifyEmail,
  resendVerification,
  requestPasswordReset,
  verifyPasswordResetCode,
  resetPassword,
  logout,
  me,
};
