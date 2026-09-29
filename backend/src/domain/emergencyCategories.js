// Canonical emergency-category source shared by responder readiness and
// server-side matching. Values align with Prisma's EmergencyCategory enum.
const HELP_TYPES = Object.freeze([
  Object.freeze({ value: 'FIRE', label: 'Fire' }),
  Object.freeze({ value: 'MEDICAL', label: 'Medical' }),
  Object.freeze({ value: 'ACCIDENT', label: 'Accident' }),
  Object.freeze({ value: 'FLOOD', label: 'Flood' }),
  Object.freeze({ value: 'RESCUE', label: 'Rescue' }),
  Object.freeze({ value: 'OTHER', label: 'Other' }),
]);
const HELP_TYPE_VALUES = new Set(HELP_TYPES.map((item) => item.value));

function normalizeHelpType(value) {
  if (typeof value !== 'string') return null;
  const normalized = value.trim().toUpperCase();
  return HELP_TYPE_VALUES.has(normalized) ? normalized : null;
}

// EmergencyRequest.emergencyType remains a string for backward compatibility
// and custom "Other" descriptions. Every non-canonical value maps to OTHER.
function categoryForEmergencyType(emergencyType) {
  return normalizeHelpType(emergencyType) || 'OTHER';
}

module.exports = {
  HELP_TYPES,
  HELP_TYPE_VALUES,
  categoryForEmergencyType,
  normalizeHelpType,
};
