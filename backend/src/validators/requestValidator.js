const VALID_PRIORITIES = ["LOW", "MEDIUM", "HIGH", "CRITICAL"];

const MAX_QUANTITY_PER_RESOURCE = 1000;

function isPositiveInteger(value) {
  return Number.isInteger(value) && value > 0;
}

/**
 * Validates the scalar fields of an emergency request payload.
 * Returns an error message, or null when the payload is valid.
 */
function validateEmergencyRequestInput(data) {
  if (!data || typeof data !== "object") {
    return "Request body is required";
  }

  const { emergencyType, location, priority, latitude, longitude } = data;

  if (!emergencyType || !String(emergencyType).trim()) {
    return "Emergency type is required";
  }

  if (!location || !String(location).trim()) {
    return "Location is required";
  }

  if (priority !== undefined && priority !== null) {
    if (!VALID_PRIORITIES.includes(String(priority))) {
      return "Invalid priority";
    }
  }

  if (latitude !== undefined && latitude !== null) {
    if (typeof latitude !== "number" || Number.isNaN(latitude)) {
      return "Latitude must be a number";
    }

    if (latitude < -90 || latitude > 90) {
      return "Latitude must be between -90 and 90";
    }
  }

  if (longitude !== undefined && longitude !== null) {
    if (typeof longitude !== "number" || Number.isNaN(longitude)) {
      return "Longitude must be a number";
    }

    if (longitude < -180 || longitude > 180) {
      return "Longitude must be between -180 and 180";
    }
  }

  // A precise location must be a complete pair. Storing half of a coordinate
  // would either be meaningless or invite the client to fabricate the other
  // half later; the human readable location text is never converted into
  // coordinates on the server.
  const hasLatitude = latitude !== undefined && latitude !== null;
  const hasLongitude = longitude !== undefined && longitude !== null;

  if (hasLatitude !== hasLongitude) {
    return "Latitude and longitude must be provided together";
  }

  return null;
}

/**
 * Normalizes and validates the requiredResources array of a request payload.
 *
 * Accepts: [{ resourceId, quantity }]
 * Returns: [{ resourceId: Int, quantity: Int }]
 *
 * Throws an Error (message is surfaced to the client) when the payload
 * is not usable. The database remains the final authority: this only
 * rejects structurally invalid input before touching PostgreSQL.
 */
function normalizeRequiredResources(requiredResources) {
  if (!Array.isArray(requiredResources) || requiredResources.length === 0) {
    throw new Error("At least one required resource must be provided");
  }

  const normalized = [];
  const seen = new Set();

  for (const entry of requiredResources) {
    if (!entry || typeof entry !== "object") {
      throw new Error("Each required resource must be an object");
    }

    const resourceId = Number(entry.resourceId);
    const quantity = Number(entry.quantity);

    if (!isPositiveInteger(resourceId)) {
      throw new Error("Each required resource needs a valid resourceId");
    }

    if (!isPositiveInteger(quantity)) {
      throw new Error("Quantity must be a positive whole number");
    }

    if (quantity > MAX_QUANTITY_PER_RESOURCE) {
      throw new Error(
        `Quantity cannot exceed ${MAX_QUANTITY_PER_RESOURCE} per resource`
      );
    }

    if (seen.has(resourceId)) {
      throw new Error("Duplicate resource in required resources");
    }

    seen.add(resourceId);

    normalized.push({
      resourceId,
      quantity,
    });
  }

  return normalized;
}

module.exports = {
  VALID_PRIORITIES,
  MAX_QUANTITY_PER_RESOURCE,
  validateEmergencyRequestInput,
  normalizeRequiredResources,
};
