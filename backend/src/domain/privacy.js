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

const { maskEmail } = require('./emailMasking');

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
 * The email address of one ERAS account as a viewer may receive it.
 *
 * An address is only ever sent in full to the account that owns it and to an
 * ADMIN (the existing authorized-admin exception). Every other viewer gets the
 * masked form from `emailMasking`, so a shared screen - the dispatch board, a
 * request detail, an assignment - can never expose a complete personal
 * address, even though the field stays present for operational context.
 *
 * Masking happens here, at the serialization boundary, and not only in the
 * Flutter widgets: a client that renders a payload directly (a future screen,
 * a log, a screenshot) therefore inherits the same privacy.
 *
 * @param {unknown} email
 * @param {object} viewer { role, userId }
 * @param {number|string|null|undefined} ownerId id of the account [email] belongs to
 * @returns {string|null}
 */
function emailForViewer(email, viewer = {}, ownerId = null) {
  if (typeof email !== 'string' || email.trim() === '') return email ?? null;

  // ADMIN keeps the authorized contact visibility of the existing model.
  if (canViewResponderContact(viewer.role)) return email;

  const viewerUserId = viewer.userId;
  if (
    viewerUserId !== null &&
    viewerUserId !== undefined &&
    ownerId !== null &&
    ownerId !== undefined &&
    Number(viewerUserId) === Number(ownerId)
  ) {
    return email; // Own account: nothing to hide from its owner.
  }

  return maskEmail(email) ?? '';
}

/** Copy one requester object with the viewer-scoped email. */
function withMaskedRequesterEmail(requester, viewer) {
  if (!isPlainObject(requester) || !('email' in requester)) return requester;
  return {
    ...requester,
    email: emailForViewer(requester.email, viewer, requester.id),
  };
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
 * Serialize an emergency request for one viewer.
 *
 * Responder contact fields stay role-gated. The REQUESTER's email address is
 * additionally masked for every viewer who is not that requester (and not an
 * ADMIN): dispatch does not need a complete personal address, and the board
 * and the request detail dialog are shared surfaces.
 *
 * @param {object|null} request
 * @param {string} viewerRole
 * @param {number|string|null} [viewerUserId] id of the account receiving the
 *   payload; when supplied, their own address is never masked for them.
 */
function sanitizeRequestForViewer(request, viewerRole, viewerUserId = null) {
  if (!isPlainObject(request)) return request ?? null;

  const viewer = { role: viewerRole, userId: viewerUserId };

  // ADMIN keeps the full operational payload (existing authorized exception),
  // including the requester's complete address: nothing is rewritten here.
  if (canViewResponderContact(viewerRole)) return request;

  const out = { ...request };

  if (isPlainObject(out.requester)) {
    out.requester = withMaskedRequesterEmail(out.requester, viewer);
  }

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

function sanitizeRequestsForViewer(requests, viewerRole, viewerUserId = null) {
  if (!Array.isArray(requests)) return [];
  return requests.map((request) =>
    sanitizeRequestForViewer(request, viewerRole, viewerUserId)
  );
}

module.exports = {
  RESPONDER_CONTACT_FIELDS,
  RESPONDER_OPERATIONAL_FIELDS,
  canViewResponderContact,
  emailForViewer,
  sanitizeResponder,
  sanitizeResponderList,
  sanitizeRequestForViewer,
  sanitizeRequestsForViewer,
};
