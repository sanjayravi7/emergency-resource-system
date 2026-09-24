/**
 * Validation helpers for the Resource catalog (admin managed).
 * These are pure functions so they can be unit tested without a database.
 */

function isNonNegativeInteger(value) {
  return Number.isInteger(value) && value >= 0;
}

function toOptionalString(value) {
  if (value === undefined || value === null) {
    return undefined;
  }

  const text = String(value).trim();

  return text.length ? text : null;
}

/**
 * Validates a resource payload.
 *
 * @param {object} data     incoming body
 * @param {object} options  { partial: true } for PATCH updates
 * @param {object} existing current DB row (used for partial updates)
 * @returns {string|null}   error message or null
 */
function validateResourceInput(data, options = {}, existing = null) {
  const partial = options.partial === true;

  if (!data || typeof data !== "object") {
    return "Resource body is required";
  }

  if (!partial || data.name !== undefined) {
    if (!data.name || !String(data.name).trim()) {
      return "Resource name is required";
    }
  }

  if (!partial || data.type !== undefined) {
    if (!data.type || !String(data.type).trim()) {
      return "Resource type is required";
    }
  }

  const totalQuantity =
    data.totalQuantity !== undefined
      ? Number(data.totalQuantity)
      : existing
        ? existing.totalQuantity
        : 0;

  const availableQuantity =
    data.availableQuantity !== undefined
      ? Number(data.availableQuantity)
      : existing
        ? existing.availableQuantity
        : // On create an unspecified availability defaults to the total.
          totalQuantity;

  if (!isNonNegativeInteger(totalQuantity)) {
    return "Total quantity must be a whole number >= 0";
  }

  if (!isNonNegativeInteger(availableQuantity)) {
    return "Available quantity must be a whole number >= 0";
  }

  if (availableQuantity > totalQuantity) {
    return "Available quantity cannot exceed total quantity";
  }

  if (data.lowStockThreshold !== undefined) {
    const threshold = Number(data.lowStockThreshold);

    if (!isNonNegativeInteger(threshold)) {
      return "Low stock threshold must be a whole number >= 0";
    }
  }

  if (data.isActive !== undefined && typeof data.isActive !== "boolean") {
    return "isActive must be a boolean";
  }

  return null;
}

/**
 * Builds a Prisma-safe data object from a resource payload.
 * Unknown keys are dropped so clients cannot write arbitrary columns.
 */
function normalizeResourceInput(data, options = {}) {
  const partial = options.partial === true;
  const normalized = {};

  if (data.name !== undefined) {
    normalized.name = String(data.name).trim();
  }

  if (data.type !== undefined) {
    normalized.type = String(data.type).trim();
  }

  if (data.totalQuantity !== undefined) {
    normalized.totalQuantity = Number(data.totalQuantity);
  } else if (!partial) {
    normalized.totalQuantity = 0;
  }

  if (data.availableQuantity !== undefined) {
    normalized.availableQuantity = Number(data.availableQuantity);
  } else if (!partial) {
    normalized.availableQuantity =
      normalized.totalQuantity !== undefined ? normalized.totalQuantity : 0;
  }

  const unit = toOptionalString(data.unit);
  if (unit !== undefined) {
    normalized.unit = unit;
  }

  const location = toOptionalString(data.location);
  if (location !== undefined) {
    normalized.location = location;
  }

  if (data.lowStockThreshold !== undefined) {
    normalized.lowStockThreshold = Number(data.lowStockThreshold);
  }

  if (data.isActive !== undefined) {
    normalized.isActive = Boolean(data.isActive);
  }

  return normalized;
}

module.exports = {
  validateResourceInput,
  normalizeResourceInput,
};
