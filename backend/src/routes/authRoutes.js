const express = require('express');

const authController = require('../controllers/authController');
const authMiddleware = require('../middleware/authMiddleware');

const router = express.Router();

router.post('/register', authController.register);
router.post('/login', authController.login);
router.post('/google', authController.google);
router.post('/verify-email', authController.verifyEmailCode);
router.post('/verification/resend', authController.resendVerificationCode);
router.post('/password-reset/request', authController.requestPasswordResetCode);
router.post('/password-reset/confirm', authController.resetPassword);
router.get('/me', authMiddleware, authController.me);

module.exports = router;
