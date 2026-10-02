const fs = require('fs');
const { cert, getApps, initializeApp } = require('firebase-admin/app');
const { getAuth } = require('firebase-admin/auth');
const env = require('./env');

const APP_NAME = 'eras-firebase-auth';
let cachedAuth = null;
let testVerifier = null;

function configurationError(code) {
  const error = new Error(code);
  error.code = code;
  return error;
}

function readServiceAccount() {
  let raw = env.FIREBASE_SERVICE_ACCOUNT;
  if (!raw && env.FIREBASE_SERVICE_ACCOUNT_FILE) {
    try {
      raw = fs.readFileSync(env.FIREBASE_SERVICE_ACCOUNT_FILE, 'utf8');
    } catch (_) {
      throw configurationError('FIREBASE_SERVICE_ACCOUNT_UNREADABLE');
    }
  }
  if (!raw) return null;

  let account;
  try {
    account = JSON.parse(raw);
  } catch (_) {
    throw configurationError('FIREBASE_SERVICE_ACCOUNT_INVALID');
  }

  if (
    !account ||
    typeof account.project_id !== 'string' ||
    !account.project_id ||
    typeof account.client_email !== 'string' ||
    !account.client_email ||
    typeof account.private_key !== 'string' ||
    !account.private_key
  ) {
    throw configurationError('FIREBASE_SERVICE_ACCOUNT_INVALID');
  }

  return {
    projectId: account.project_id,
    clientEmail: account.client_email,
    privateKey: account.private_key.replace(/\\n/g, '\n'),
  };
}

function getFirebaseAuth() {
  if (testVerifier) return { verifyIdToken: testVerifier };
  if (cachedAuth) return cachedAuth;

  const account = readServiceAccount();
  const projectId = env.FIREBASE_PROJECT_ID || account?.projectId;
  if (!account || !projectId) {
    throw configurationError('FIREBASE_AUTH_NOT_CONFIGURED');
  }
  if (account.projectId !== projectId) {
    throw configurationError('FIREBASE_PROJECT_MISMATCH');
  }

  let app = getApps().find((candidate) => candidate.name === APP_NAME);
  if (!app) {
    app = initializeApp(
      {
        credential: cert({
          projectId: account.projectId,
          clientEmail: account.clientEmail,
          privateKey: account.privateKey,
        }),
        projectId,
      },
      APP_NAME
    );
  }

  cachedAuth = getAuth(app);
  return cachedAuth;
}

/** Verify the Firebase-signed ID token, then require a verified Google identity. */
async function verifyGoogleIdToken(idToken) {
  if (typeof idToken !== 'string' || idToken.length < 20 || idToken.length > 12000) {
    throw configurationError('INVALID_GOOGLE_CREDENTIAL');
  }

  let auth;
  try {
    auth = getFirebaseAuth();
  } catch (error) {
    if (error?.code?.startsWith('FIREBASE_')) throw error;
    throw configurationError('FIREBASE_AUTH_NOT_CONFIGURED');
  }

  let decoded;
  try {
    decoded = await auth.verifyIdToken(idToken);
  } catch (_) {
    throw configurationError('INVALID_GOOGLE_CREDENTIAL');
  }

  const provider = decoded?.firebase?.sign_in_provider;
  const email = typeof decoded?.email === 'string' ? decoded.email.trim().toLowerCase() : '';
  if (
    !decoded?.uid ||
    provider !== 'google.com' ||
    decoded.email_verified !== true ||
    !email
  ) {
    throw configurationError('INVALID_GOOGLE_CREDENTIAL');
  }

  return {
    uid: String(decoded.uid),
    email,
    name: typeof decoded.name === 'string' ? decoded.name.trim() : '',
  };
}

function setGoogleTokenVerifierForTests(verifier) {
  testVerifier = verifier || null;
}

function resetFirebaseAdminForTests() {
  cachedAuth = null;
  testVerifier = null;
}

module.exports = {
  verifyGoogleIdToken,
  setGoogleTokenVerifierForTests,
  resetFirebaseAdminForTests,
};
