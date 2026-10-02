// ---------------------------------------------------------------------------
// RESPONDER CONTACT PRIVACY (security boundary, not a UI concern)
//
// REQUESTER and RESPONDER accounts must never receive a responder's email
// address or mobile number from the API - not in the responder directory, not
// in request cards, not in assignment payloads, not in allocations and not in
// realtime events. Only ADMIN accounts may see responder contact details.
//
// The fields are OMITTED (not blanked): a non-admin response contains no
// `email`/`phone` key at all, so no client can accidentally display or log
// them. Hiding values in Flutter alone would NOT be sufficient; this module is
// applied on the server for every outbound payload.
//
// Operational fields (id, name, status, location, coordinates, lastActiveAt)
// stay visible to every authenticated role because dispatch depends on them.
// ---------------------------------------------------------------------------

/** Contact fields that only ADMIN may receive for a responder. */
const RESPONDER_CONTACT_FIELDS = Object.freeze(['email', 'phone']);

/** Fields every authenticated role may receive about a responder. */
const RESPONDER_OPERATIONAL_FIELDS = Object.freeze([
  'id',
  'name',
  'role',
  'isActive',
  'responderStatus',
  'location',
  'latitude',
  'longitude',
  'lastActiveAt',
  'createdAt',
  'updatedAt',
]);

/** True when the viewer is allowed to see responder contact details. */
function canViewResponderContact(viewerRole) {
  return String(viewerRole || '').toUpperCase() === 'ADMIN';
}

function isPlainObject(value) {
  return Boolean(value) && typeof value === 'object' && !Array.isArray(value);
}

/**
 * Copy one responder-shaped object, dropping contact fields for non-admins.
 * Unknown keys are dropped as well (allow-list): a future schema addition can
 * never leak through this serializer by accident.
 */
function sanitizeResponder(row, viewerRole) {
  if (!isPlainObject(row)) return row ?? null;

  const allowed = canViewResponderContact(viewerRole)
    ? [...RESPONDER_OPERATIONAL_FIELDS, ...RESPONDER_CONTACT_FIELDS]
    : RESPONDER_OPERATIONAL_FIELDS;

  const out = {};
  for (const field of allowed) {
    if (field in row) out[field] = row[field];
  }
  return out;
}

function sanitizeResponderList(rows, viewerRole) {
  if (!Array.isArray(rows)) return [];
  return rows.map((row) => sanitizeResponder(row, viewerRole));
}

/**
 * Serialize an emergency request for one viewer role.
 *
 * The requester's own contact details are unchanged (they are part of the
 * existing dispatch contract and belong to the person asking for help). Only
 * responder contact fields are role-gated.
 */
function sanitizeRequestForViewer(request, viewerRole) {
  if (!isPlainObject(request)) return request ?? null;
  if (canViewResponderContact(viewerRole)) return request;

  const out = { ...request };

  if (isPlainObject(out.acceptedBy)) {
    out.acceptedBy = sanitizeResponder(out.acceptedBy, viewerRole);
  }

  if (Array.isArray(out.assignments)) {
    out.assignments = out.assignments.map((assignment) => {
      if (!isPlainObject(assignment)) return assignment;
      return {
        ...assignment,
        responder: isPlainObject(assignment.responder)
          ? sanitizeResponder(assignment.responder, viewerRole)
          : assignment.responder ?? null,
      };
    });
  }

  if (Array.isArray(out.allocations)) {
    out.allocations = out.allocations.map((allocation) => {
      if (!isPlainObject(allocation)) return allocation;
      return {
        ...allocation,
        responder: isPlainObject(allocation.responder)
          ? sanitizeResponder(allocation.responder, viewerRole)
          : allocation.responder ?? null,
      };
    });
  }

  return out;
}

function sanitizeRequestsForViewer(requests, viewerRole) {
  if (!Array.isArray(requests)) return [];
  return requests.map((request) => sanitizeRequestForViewer(request, viewerRole));
}

module.exports = {
  RESPONDER_CONTACT_FIELDS,
  RESPONDER_OPERATIONAL_FIELDS,
  canViewResponderContact,
  sanitizeResponder,
  sanitizeResponderList,
  sanitizeRequestForViewer,
  sanitizeRequestsForViewer,
};
