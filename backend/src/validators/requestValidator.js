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
 * Accepts: undefined | null | [] | [{ resourceId, quantity }]
 * Returns: [{ resourceId: Int, quantity: Int }] (possibly empty)
 *
 * Resource information is OPTIONAL on an emergency request. An emergency must
 * always be fileable even when the requester names zero resources, the
 * catalog is empty, or nothing is currently allocatable - the EmergencyRequest
 * row (0..N RequestResource) is the source of truth and matching happens
 * afterwards. This function therefore never rejects an absent or empty list;
 * it only validates the structure of any resource lines that ARE supplied.
 *
 * Throws an Error (message is surfaced to the client) when a supplied line is
 * structurally invalid. The database remains the final authority: this only
 * rejects malformed input before touching PostgreSQL.
 */
function normalizeRequiredResources(requiredResources) {
  if (requiredResources === undefined || requiredResources === null) {
    return [];
  }

  if (!Array.isArray(requiredResources)) {
    throw new Error("Required resources must be an array");
  }

  if (requiredResources.length === 0) {
    return [];
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
