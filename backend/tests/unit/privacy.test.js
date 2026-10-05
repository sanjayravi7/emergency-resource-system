// RESPONDER PRIVACY: role-based field visibility is enforced on the server and
// the sensitive keys are OMITTED entirely (not blanked), so no client can
// display or log them by accident.

const {
  canViewResponderContact,
  sanitizeResponder,
  sanitizeResponderList,
  sanitizeRequestForViewer,
  sanitizeRequestsForViewer,
} = require('../../src/domain/privacy');

const responderRow = {
  id: 42,
  name: 'Rahul',
  email: 'rahul@gmail.com',
  phone: '+91 90000 00000',
  responderStatus: 'AVAILABLE',
  location: 'Thrissur',
  latitude: 10.5,
  longitude: 76.2,
  lastActiveAt: new Date('2026-01-01T00:00:00.000Z'),
};

const requestRow = () => ({
  id: 1,
  status: 'ACCEPTED',
  requester: { id: 2, name: 'Meera', email: 'meera@example.com', phone: '9000000001' },
  acceptedBy: { ...responderRow },
  assignments: [
    {
      id: 11,
      responderId: 42,
      status: 'ACTIVE',
      responder: { ...responderRow },
    },
  ],
  allocations: [
    {
      id: 21,
      responderId: 42,
      quantity: 2,
      responder: { id: 42, name: 'Rahul', email: 'rahul@gmail.com', phone: '+91 90000 00000' },
    },
  ],
});

describe('responder contact visibility', () => {
  test('only ADMIN may see responder contact details', () => {
    expect(canViewResponderContact('ADMIN')).toBe(true);
    expect(canViewResponderContact('admin')).toBe(true);
    expect(canViewResponderContact('REQUESTER')).toBe(false);
    expect(canViewResponderContact('RESPONDER')).toBe(false);
    expect(canViewResponderContact(undefined)).toBe(false);
  });

  test('a REQUESTER never receives a responder email or phone', () => {
    const view = sanitizeResponder(responderRow, 'REQUESTER');
    expect(view).not.toHaveProperty('email');
    expect(view).not.toHaveProperty('phone');
    // Operational identity is preserved for dispatch.
    expect(view).toMatchObject({ id: 42, name: 'Rahul', responderStatus: 'AVAILABLE' });
  });

  test('a RESPONDER cannot read another responder email or phone', () => {
    const view = sanitizeResponder(responderRow, 'RESPONDER');
    expect(Object.keys(view)).not.toContain('email');
    expect(Object.keys(view)).not.toContain('phone');
  });

  test('ADMIN keeps the allowed contact information', () => {
    const view = sanitizeResponder(responderRow, 'ADMIN');
    expect(view.email).toBe('rahul@gmail.com');
    expect(view.phone).toBe('+91 90000 00000');
  });

  test('unknown keys are dropped (allow-list, not deny-list)', () => {
    const view = sanitizeResponder({ ...responderRow, password: 'hash', secret: 'x' }, 'ADMIN');
    expect(view).not.toHaveProperty('password');
    expect(view).not.toHaveProperty('secret');
  });

  test('lists are sanitized element-wise', () => {
    const list = sanitizeResponderList([responderRow, responderRow], 'REQUESTER');
    expect(list).toHaveLength(2);
    for (const row of list) expect(row).not.toHaveProperty('email');
  });
});

describe('request payload projection', () => {
  test('REQUESTER payload omits responder contact everywhere', () => {
    const view = sanitizeRequestForViewer(requestRow(), 'REQUESTER');
    expect(view.acceptedBy).not.toHaveProperty('email');
    expect(view.acceptedBy).not.toHaveProperty('phone');
    expect(view.assignments[0].responder).not.toHaveProperty('email');
    expect(view.assignments[0].responder).not.toHaveProperty('phone');
    expect(view.allocations[0].responder).not.toHaveProperty('email');
    expect(view.allocations[0].responder).not.toHaveProperty('phone');
  });

  test('RESPONDER payload omits responder contact everywhere', () => {
    const view = sanitizeRequestForViewer(requestRow(), 'RESPONDER');
    const serialized = JSON.stringify(view);
    expect(serialized).not.toContain('rahul@gmail.com');
    expect(serialized).not.toContain('+91 90000 00000');
  });

  test('ADMIN payload keeps responder contact information', () => {
    const view = sanitizeRequestForViewer(requestRow(), 'ADMIN');
    expect(view.acceptedBy.email).toBe('rahul@gmail.com');
    expect(view.assignments[0].responder.phone).toBe('+91 90000 00000');
  });

  test('a responder receives the requester email MASKED, never in full', () => {
    const view = sanitizeRequestForViewer(requestRow(), 'RESPONDER');
    expect(view.requester.email).toBe('m****@example.com');
    expect(JSON.stringify(view)).not.toContain('meera@example.com');
  });

  test('a requester still receives their OWN email in full', () => {
    const view = sanitizeRequestForViewer(requestRow(), 'REQUESTER', 2);
    expect(view.requester.email).toBe('meera@example.com');
  });

  test('ADMIN keeps the complete requester email (authorized exception)', () => {
    const view = sanitizeRequestForViewer(requestRow(), 'ADMIN');
    expect(view.requester.email).toBe('meera@example.com');
  });

  test('lists honour the same viewer identity', () => {
    const [view] = sanitizeRequestsForViewer([requestRow()], 'RESPONDER', 99);
    expect(view.requester.email).toBe('m****@example.com');
    const [own] = sanitizeRequestsForViewer([requestRow()], 'RESPONDER', 2);
    expect(own.requester.email).toBe('meera@example.com');
  });

  test('the requester phone stays available for dispatch', () => {
    const view = sanitizeRequestForViewer(requestRow(), 'RESPONDER');
    expect(view.requester.phone).toBe('9000000001');
  });

  test('arrays are projected element-wise and non-objects pass through safely', () => {
    const views = sanitizeRequestsForViewer([requestRow()], 'REQUESTER');
    expect(views).toHaveLength(1);
    expect(sanitizeRequestForViewer(null, 'REQUESTER')).toBeNull();
    expect(sanitizeRequestsForViewer(undefined, 'REQUESTER')).toEqual([]);
  });
});
