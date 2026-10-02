// ---------------------------------------------------------------------------
// EMERGENCY REQUEST EXPIRY POLICY (single source of truth)
//
// One place decides how long an UNATTENDED emergency stays open before the
// backend expires it. Controllers, services and tests must never hardcode a
// timeout value: they call resolveExpiresAt()/classifyExpiryClass() here.
//
// Classification reuses the EXISTING ERAS emergency-category semantics
// (domain/emergencyCategories.js maps a free-text emergencyType onto the
// canonical EmergencyCategory enum) plus a small, explicit keyword list for
// SUPPLY-style requests, which are filed through the "Other" type in the UI.
//
//   URGENT  : medical / fire / accident / rescue-type  -> ~30 minutes
//   GENERAL : any other emergency                      -> ~1 hour
//   SUPPLY  : food / water / relief / inventory supply -> ~4 hours
//
// CRITICAL priority escalates a GENERAL request to the URGENT window (a
// critical emergency must not sit unattended for an hour). SUPPLY keywords
// win over priority: a water delivery is not a rescue.
//
// All three windows are configurable through environment variables and are
// clamped to a sane range; they are read once per call so a redeploy with new
// values takes effect immediately.
// ---------------------------------------------------------------------------

const { categoryForEmergencyType } = require('./emergencyCategories');

const EXPIRY_CLASSES = Object.freeze({
  URGENT: 'URGENT',
  GENERAL: 'GENERAL',
  SUPPLY: 'SUPPLY',
});

// Suggested production defaults (minutes).
const DEFAULT_WINDOWS_MINUTES = Object.freeze({
  [EXPIRY_CLASSES.URGENT]: 30,
  [EXPIRY_CLASSES.GENERAL]: 60,
  [EXPIRY_CLASSES.SUPPLY]: 240,
});

// Safety clamp: never allow a policy value that could expire an emergency
// almost instantly (or keep it open forever) because of a typo in env config.
const MIN_WINDOW_MINUTES = 1;
const MAX_WINDOW_MINUTES = 24 * 60;

const ENV_KEYS = Object.freeze({
  [EXPIRY_CLASSES.URGENT]: 'EXPIRY_URGENT_MINUTES',
  [EXPIRY_CLASSES.GENERAL]: 'EXPIRY_GENERAL_MINUTES',
  [EXPIRY_CLASSES.SUPPLY]: 'EXPIRY_SUPPLY_MINUTES',
});

// Emergency categories (canonical ERAS enum values) that always use the
// urgent window because someone's life or property is at immediate risk.
const URGENT_CATEGORIES = new Set(['MEDICAL', 'FIRE', 'ACCIDENT', 'RESCUE', 'FLOOD']);

// Supply/relief keywords. Matching is deliberately conservative: the keyword
// must appear as a whole word in the emergency type or description.
const SUPPLY_KEYWORDS = Object.freeze([
  'food',
  'foods',
  'water',
  'drinking water',
  'relief',
  'relief material',
  'relief materials',
  'supply',
  'supplies',
  'ration',
  'rations',
  'groceries',
  'blanket',
  'blankets',
  'clothing',
  'clothes',
  'shelter',
  'medicine',
  'medicines',
  'medical supply',
  'medical supplies',
  'oxygen',
  'inventory',
  'kit',
  'kits',
  'provisions',
]);

function readWindowMinutes(expiryClass, overrides) {
  const override = overrides ? overrides[expiryClass] : undefined;
  if (Number.isFinite(override)) {
    return clampMinutes(override);
  }

  const raw = process.env[ENV_KEYS[expiryClass]];
  if (raw === undefined || raw === null || String(raw).trim() === '') {
    return DEFAULT_WINDOWS_MINUTES[expiryClass];
  }

  const parsed = Number(raw);
  if (!Number.isFinite(parsed)) return DEFAULT_WINDOWS_MINUTES[expiryClass];
  return clampMinutes(parsed);
}

function clampMinutes(minutes) {
  const rounded = Math.round(minutes);
  if (!Number.isFinite(rounded)) return MIN_WINDOW_MINUTES;
  return Math.min(MAX_WINDOW_MINUTES, Math.max(MIN_WINDOW_MINUTES, rounded));
}

/** Every configured window, in minutes (used by tests/diagnostics). */
function expiryWindowsMinutes(overrides) {
  return {
    [EXPIRY_CLASSES.URGENT]: readWindowMinutes(EXPIRY_CLASSES.URGENT, overrides),
    [EXPIRY_CLASSES.GENERAL]: readWindowMinutes(EXPIRY_CLASSES.GENERAL, overrides),
    [EXPIRY_CLASSES.SUPPLY]: readWindowMinutes(EXPIRY_CLASSES.SUPPLY, overrides),
  };
}

function escapeRegExp(value) {
  return String(value).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

/**
 * True when the free text describes a supply/relief delivery rather than a
 * life-safety emergency. Whole-word matching avoids "firewood" -> "fire"-like
 * accidents in both directions.
 */
function hasSupplyKeyword(text) {
  if (typeof text !== 'string' || text.trim() === '') return false;
  const haystack = text.toLowerCase();
  return SUPPLY_KEYWORDS.some((keyword) =>
    new RegExp(`(^|[^a-z])${escapeRegExp(keyword)}([^a-z]|$)`, 'i').test(haystack)
  );
}

/**
 * Expiry class for one emergency request.
 *
 * @param {object} input { emergencyType, description, priority }
 * @returns {'URGENT'|'GENERAL'|'SUPPLY'}
 */
function classifyExpiryClass({ emergencyType, description, priority } = {}) {
  const supplyText = [emergencyType, description].filter(Boolean).join(' ');
  if (hasSupplyKeyword(supplyText)) return EXPIRY_CLASSES.SUPPLY;

  const category = categoryForEmergencyType(emergencyType);
  if (URGENT_CATEGORIES.has(category)) return EXPIRY_CLASSES.URGENT;

  if (String(priority || '').trim().toUpperCase() === 'CRITICAL') {
    return EXPIRY_CLASSES.URGENT;
  }

  return EXPIRY_CLASSES.GENERAL;
}

/** Server-generated expiry deadline for a newly created request. */
function resolveExpiresAt({ emergencyType, description, priority, now } = {}) {
  const createdAt = now instanceof Date ? now : new Date();
  const expiryClass = classifyExpiryClass({ emergencyType, description, priority });
  const minutes = readWindowMinutes(expiryClass);
  return {
    expiryClass,
    minutes,
    expiresAt: new Date(createdAt.getTime() + minutes * 60 * 1000),
  };
}

/**
 * "Is this request an unattended emergency whose window has passed?"
 *
 * Only a request that is still PENDING - nobody accepted/assigned it and no
 * unfinished allocation holds a claim on it - may expire. IN_PROGRESS,
 * COMPLETED, CANCELLED and accepted/assigned requests are never expired, so
 * this predicate is deliberately conservative: when in doubt it returns false
 * and the emergency stays untouched.
 */
function isExpiredUnattended(request, now = new Date()) {
  if (!request || !request.expiresAt) return false;
  if (request.status !== 'PENDING') return false;
  if (request.acceptedById) return false;
  if (request.acceptedAt) return false;

  const assignments = request.assignments;
  if (Array.isArray(assignments) && assignments.some((row) => row && row.status === 'ACTIVE')) {
    return false;
  }

  const allocations = request.allocations;
  if (
    Array.isArray(allocations) &&
    allocations.some(
      (row) => row && (row.status === 'RESERVED' || row.status === 'DISPATCHED')
    )
  ) {
    return false;
  }

  const deadline = request.expiresAt instanceof Date ? request.expiresAt : new Date(request.expiresAt);
  if (Number.isNaN(deadline.getTime())) return false;
  return deadline.getTime() <= now.getTime();
}

module.exports = {
  EXPIRY_CLASSES,
  DEFAULT_WINDOWS_MINUTES,
  MIN_WINDOW_MINUTES,
  MAX_WINDOW_MINUTES,
  ENV_KEYS,
  URGENT_CATEGORIES,
  SUPPLY_KEYWORDS,
  expiryWindowsMinutes,
  classifyExpiryClass,
  resolveExpiresAt,
  isExpiredUnattended,
  hasSupplyKeyword,
};
