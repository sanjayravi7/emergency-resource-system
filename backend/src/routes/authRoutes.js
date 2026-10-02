const express = require("express");

const authController = require("../controllers/authController");
const authMiddleware = require("../middleware/authMiddleware");
const {
  authLimiter,
  googleAuthLimiter,
  passwordResetLimiter,
  emailResendLimiter,
} = require("../middleware/rateLimiters");

const router = express.Router();

// Public registration (email/password) and login: strict credential limiter.
router.post("/register", authLimiter, authController.register);

router.post("/login", authLimiter, authController.login);

// Google/Firebase identity exchange. The client has already authenticated the
// user with Google; this endpoint verifies the ID token and issues the ERAS
// session. It gets its own limiter so a slow/limited login path can never be
// used to brute force anything else.
router.post("/google", googleAuthLimiter, authController.googleSignIn);

// Email verification (email/password accounts). Confirming requires the
// authenticated session the user just obtained; resending is public but
// strictly rate limited and answers generically (no account enumeration).
router.post("/verify-email", authMiddleware, emailResendLimiter, authController.verifyEmail);

router.post("/resend-verification", emailResendLimiter, authController.resendVerification);

// Forgot-password flow: request code -> verify code -> set new password.
router.post("/password/forgot", passwordResetLimiter, authController.requestPasswordReset);

router.post("/password/verify-code", passwordResetLimiter, authController.verifyPasswordResetCode);

router.post("/password/reset", passwordResetLimiter, authController.resetPassword);

// Explicit logout audit; the client drops its token in all cases.
router.post("/logout", authMiddleware, authController.logout);

router.get("/me", authMiddleware, authController.me);

module.exports = router;
