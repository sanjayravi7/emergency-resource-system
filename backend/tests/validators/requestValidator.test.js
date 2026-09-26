const {
  validateEmergencyRequestInput,
  normalizeRequiredResources,
} = require("../../src/validators/requestValidator");

describe("Emergency request validation", () => {
  const validBody = {
    emergencyType: "Fire",
    description: "Building fire on the 3rd floor",
    location: "Thrissur Round, Kerala",
    priority: "CRITICAL",
    latitude: 10.5276,
    longitude: 76.2144,
  };

  test("✅ accepts a valid payload", () => {
    expect(validateEmergencyRequestInput(validBody)).toBeNull();
  });

  test("✅ accepts a payload without coordinates", () => {
    const { latitude, longitude, ...body } = validBody;
    expect(validateEmergencyRequestInput(body)).toBeNull();
  });

  test("❌ rejects latitude without longitude (incomplete precise location)", () => {
    const { longitude, ...body } = validBody;
    expect(validateEmergencyRequestInput(body)).toMatch(
      /Latitude and longitude must be provided together/i
    );
  });

  test("❌ rejects longitude without latitude (incomplete precise location)", () => {
    const { latitude, ...body } = validBody;
    expect(validateEmergencyRequestInput(body)).toMatch(
      /Latitude and longitude must be provided together/i
    );
  });

  test("❌ rejects a missing emergency type", () => {
    expect(
      validateEmergencyRequestInput({ ...validBody, emergencyType: "  " })
    ).toMatch(/Emergency type/i);
  });

  test("✅ accepts missing, null, empty, and whitespace-only descriptions", () => {
    const { description, ...withoutDescription } = validBody;

    expect(validateEmergencyRequestInput(withoutDescription)).toBeNull();
    expect(
      validateEmergencyRequestInput({ ...validBody, description: null })
    ).toBeNull();
    expect(
      validateEmergencyRequestInput({ ...validBody, description: "" })
    ).toBeNull();
    expect(
      validateEmergencyRequestInput({ ...validBody, description: "   	  " })
    ).toBeNull();
  });

  test("❌ rejects a missing location", () => {
    expect(
      validateEmergencyRequestInput({ ...validBody, location: undefined })
    ).toMatch(/Location/i);
  });

  test("❌ rejects an invalid priority", () => {
    expect(
      validateEmergencyRequestInput({ ...validBody, priority: "URGENT" })
    ).toMatch(/priority/i);
  });

  test("❌ rejects out of range coordinates", () => {
    expect(
      validateEmergencyRequestInput({ ...validBody, latitude: 120 })
    ).toMatch(/Latitude/i);

    expect(
      validateEmergencyRequestInput({ ...validBody, longitude: -200 })
    ).toMatch(/Longitude/i);
  });
});

describe("Required resources normalization", () => {
  test("✅ normalizes several resources", () => {
    const result = normalizeRequiredResources([
      { resourceId: "7", quantity: "2" },
      { resourceId: 9, quantity: 3 },
    ]);

    expect(result).toEqual([
      { resourceId: 7, quantity: 2 },
      { resourceId: 9, quantity: 3 },
    ]);
  });

  test("❌ rejects an empty list", () => {
    expect(() => normalizeRequiredResources([])).toThrow(
      /At least one required resource/i
    );

    expect(() => normalizeRequiredResources(undefined)).toThrow(
      /At least one required resource/i
    );
  });

  test("❌ rejects duplicate resources", () => {
    expect(() =>
      normalizeRequiredResources([
        { resourceId: 4, quantity: 1 },
        { resourceId: 4, quantity: 2 },
      ])
    ).toThrow(/Duplicate resource/i);
  });

  test("❌ rejects quantities that are zero, negative or fractional", () => {
    for (const quantity of [0, -3, 1.5]) {
      expect(() =>
        normalizeRequiredResources([{ resourceId: 4, quantity }])
      ).toThrow(/Quantity must be a positive whole number/i);
    }
  });

  test("❌ rejects invalid resource ids", () => {
    for (const resourceId of [0, -1, "abc", null]) {
      expect(() =>
        normalizeRequiredResources([{ resourceId, quantity: 1 }])
      ).toThrow(/valid resourceId/i);
    }
  });
});
