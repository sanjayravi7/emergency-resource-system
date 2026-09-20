const VALID_RESPONDER_STATUSES = [
  "AVAILABLE",
  "BUSY",
  "OFFLINE",
];

function validateResponderStatus(data) {
  const { status } = data;

  if (!status) {
    return "Status is required";
  }

  if (!VALID_RESPONDER_STATUSES.includes(status)) {
    return "Invalid responder status";
  }

  return null;
}

function validateResponderLocation(data) {
  const { location, latitude, longitude } = data;

  if (!location || !location.trim()) {
    return "Location is required";
  }

  if (latitude !== undefined && typeof latitude !== "number") {
    return "Latitude must be a number";
  }

  if (longitude !== undefined && typeof longitude !== "number") {
    return "Longitude must be a number";
  }

  if (
    typeof latitude === "number" &&
    (latitude < -90 || latitude > 90)
  ) {
    return "Latitude must be between -90 and 90";
  }

  if (
    typeof longitude === "number" &&
    (longitude < -180 || longitude > 180)
  ) {
    return "Longitude must be between -180 and 180";
  }

  return null;
}

module.exports = {
  validateResponderStatus,
  validateResponderLocation,
};
