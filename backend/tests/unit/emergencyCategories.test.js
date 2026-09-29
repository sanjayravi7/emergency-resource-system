const {
  HELP_TYPES,
  categoryForEmergencyType,
  normalizeHelpType,
} = require('../../src/domain/emergencyCategories');

describe('canonical emergency categories', () => {
  test('exposes the established application emergency types', () => {
    expect(HELP_TYPES.map((item) => item.value)).toEqual([
      'FIRE',
      'MEDICAL',
      'ACCIDENT',
      'FLOOD',
      'RESCUE',
      'OTHER',
    ]);
  });

  test('normalizes known labels without depending on Resource rows', () => {
    expect(normalizeHelpType(' Fire ')).toBe('FIRE');
    expect(normalizeHelpType('rescue')).toBe('RESCUE');
    expect(normalizeHelpType('ambulance')).toBeNull();
  });

  test('maps custom emergency descriptions to OTHER', () => {
    expect(categoryForEmergencyType('Other')).toBe('OTHER');
    expect(categoryForEmergencyType('Tree fallen on road')).toBe('OTHER');
  });
});
