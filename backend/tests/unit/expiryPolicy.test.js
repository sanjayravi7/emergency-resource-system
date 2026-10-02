// Backend-authoritative expiry policy: classification windows, configuration
// overrides and the "unattended only" predicate.
//
// These are pure-function tests: no database, no network.

const {
  EXPIRY_CLASSES,
  DEFAULT_WINDOWS_MINUTES,
  classifyExpiryClass,
  resolveExpiresAt,
  isExpiredUnattended,
  expiryWindowsMinutes,
} = require('../../src/domain/expiryPolicy');

describe('expiry policy classification', () => {
  test('medical / fire / accident / rescue emergencies use the ~30 minute window', () => {
    for (const emergencyType of ['Medical', 'Fire', 'Accident', 'Rescue', 'MEDICAL', 'fire']) {
      expect(classifyExpiryClass({ emergencyType })).toBe(EXPIRY_CLASSES.URGENT);
      expect(expiryWindowsMinutes()[EXPIRY_CLASSES.URGENT]).toBe(30);
    }
  });

  test('a flood emergency is treated as an urgent rescue-type emergency', () => {
    expect(classifyExpiryClass({ emergencyType: 'Flood' })).toBe(EXPIRY_CLASSES.URGENT);
  });

  test('an unrelated emergency uses the 1 hour general window', () => {
    expect(classifyExpiryClass({ emergencyType: 'Other' })).toBe(EXPIRY_CLASSES.GENERAL);
    expect(classifyExpiryClass({ emergencyType: 'Power outage' })).toBe(EXPIRY_CLASSES.GENERAL);
  });

  test('CRITICAL priority escalates a general request to the urgent window', () => {
    expect(classifyExpiryClass({ emergencyType: 'Other', priority: 'CRITICAL' })).toBe(
      EXPIRY_CLASSES.URGENT
    );
  });

  test('food / water / relief / inventory supply requests use the ~4 hour window', () => {
    const supplyTypes = [
      'Food',
      'Water',
      'Drinking Water',
      'Relief material',
      'Relief supplies',
      'Food packets',
      'Blankets',
      'Medical supplies',
      'Oxygen cylinder',
      'Inventory restock',
    ];
    for (const emergencyType of supplyTypes) {
      expect(classifyExpiryClass({ emergencyType })).toBe(EXPIRY_CLASSES.SUPPLY);
    }
    expect(expiryWindowsMinutes()[EXPIRY_CLASSES.SUPPLY]).toBe(240);
  });

  test('a supply request stays SUPPLY even at CRITICAL priority (never a rescue)', () => {
    expect(
      classifyExpiryClass({ emergencyType: 'Water', priority: 'CRITICAL' })
    ).toBe(EXPIRY_CLASSES.SUPPLY);
  });

  test('description text participates in supply detection', () => {
    expect(
      classifyExpiryClass({ emergencyType: 'Other', description: 'need drinking water for 40 people' })
    ).toBe(EXPIRY_CLASSES.SUPPLY);
  });

  test('defaults are the documented values and are configurable in one place', () => {
    expect(DEFAULT_WINDOWS_MINUTES).toMatchObject({ URGENT: 30, GENERAL: 60, SUPPLY: 240 });
  });
});

describe('resolveExpiresAt', () => {
  const now = new Date('2026-01-01T10:00:00.000Z');

  test('urgent emergencies expire 30 minutes after creation', () => {
    const { expiresAt, expiryClass, minutes } = resolveExpiresAt({
      emergencyType: 'Medical',
      now,
    });
    expect(expiryClass).toBe(EXPIRY_CLASSES.URGENT);
    expect(minutes).toBe(30);
    expect(expiresAt.toISOString()).toBe('2026-01-01T10:30:00.000Z');
  });

  test('supply emergencies expire 4 hours after creation', () => {
    const { expiresAt } = resolveExpiresAt({ emergencyType: 'Food', now });
    expect(expiresAt.toISOString()).toBe('2026-01-01T14:00:00.000Z');
  });

  test('environment overrides are honoured and clamped to sane bounds', () => {
    const previous = process.env.EXPIRY_URGENT_MINUTES;
    process.env.EXPIRY_URGENT_MINUTES = '45';
    expect(expiryWindowsMinutes().URGENT).toBe(45);

    process.env.EXPIRY_URGENT_MINUTES = '0';
    expect(expiryWindowsMinutes().URGENT).toBe(1);

    process.env.EXPIRY_URGENT_MINUTES = '999999';
    expect(expiryWindowsMinutes().URGENT).toBe(1440);

    process.env.EXPIRY_URGENT_MINUTES = previous;
  });

  test('explicit overrides win over the environment (used by tests/policies)', () => {
    expect(expiryWindowsMinutes({ URGENT: 12 }).URGENT).toBe(12);
  });
});

describe('isExpiredUnattended (only unattended emergencies may expire)', () => {
  const now = new Date('2026-01-01T12:00:00.000Z');
  const past = new Date('2026-01-01T11:00:00.000Z');

  const base = {
    status: 'PENDING',
    expiresAt: past,
    acceptedById: null,
    acceptedAt: null,
    assignments: [],
    allocations: [],
  };

  test('an unattended PENDING request past its deadline expires', () => {
    expect(isExpiredUnattended(base, now)).toBe(true);
  });

  test('a request whose window has not passed does not expire', () => {
    expect(
      isExpiredUnattended({ ...base, expiresAt: new Date('2026-01-01T13:00:00.000Z') }, now)
    ).toBe(false);
  });

  test('a request without a deadline never expires', () => {
    expect(isExpiredUnattended({ ...base, expiresAt: null }, now)).toBe(false);
  });

  test('an ACCEPTED request never expires (assignment prevents expiry)', () => {
    expect(
      isExpiredUnattended(
        { ...base, status: 'ACCEPTED', acceptedById: 7, acceptedAt: past },
        now
      )
    ).toBe(false);
  });

  test('a request with an ACTIVE assignment never expires', () => {
    expect(
      isExpiredUnattended({ ...base, assignments: [{ status: 'ACTIVE' }] }, now)
    ).toBe(false);
  });

  test('a request with an unfinished allocation never expires', () => {
    for (const status of ['RESERVED', 'DISPATCHED']) {
      expect(isExpiredUnattended({ ...base, allocations: [{ status }] }, now)).toBe(false);
    }
  });

  test('an IN_PROGRESS request never expires', () => {
    expect(isExpiredUnattended({ ...base, status: 'IN_PROGRESS' }, now)).toBe(false);
  });

  test('a COMPLETED request never expires', () => {
    expect(isExpiredUnattended({ ...base, status: 'COMPLETED' }, now)).toBe(false);
  });

  test('a CANCELLED request never expires (idempotent)', () => {
    expect(isExpiredUnattended({ ...base, status: 'CANCELLED' }, now)).toBe(false);
  });

  test('null/undefined input is handled safely', () => {
    expect(isExpiredUnattended(null, now)).toBe(false);
    expect(isExpiredUnattended(undefined, now)).toBe(false);
  });
});
