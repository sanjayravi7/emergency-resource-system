const {
  validateResourceInput,
  normalizeResourceInput,
} = require("../../src/validators/resourceValidator");

describe("Resource validation (ADMIN catalog management)", () => {
  test("✅ accepts a minimal create payload", () => {
    expect(
      validateResourceInput(
        { name: "Rescue Boat", type: "RESCUE", unit: "boat" },
        { partial: false }
      )
    ).toBeNull();
  });

  test("✅ accepts a full create payload", () => {
    expect(
      validateResourceInput(
        {
          name: "Oxygen",
          type: "OXYGEN",
          totalQuantity: 20,
          availableQuantity: 20,
          unit: "cylinder",
          location: "Thrissur, Kerala",
          lowStockThreshold: 4,
          isActive: true,
        },
        { partial: false }
      )
    ).toBeNull();
  });

  test("❌ rejects a missing name or type on create", () => {
    expect(validateResourceInput({ type: "FIRE" }, { partial: false })).toMatch(
      /name/i
    );

    expect(
      validateResourceInput({ name: "Fire Resource" }, { partial: false })
    ).toMatch(/type/i);
  });

  test("❌ rejects negative or fractional quantities", () => {
    expect(
      validateResourceInput(
        { name: "X", type: "Y", totalQuantity: -1 },
        { partial: false }
      )
    ).toMatch(/Total quantity/i);

    expect(
      validateResourceInput(
        { name: "X", type: "Y", totalQuantity: 5, availableQuantity: 1.5 },
        { partial: false }
      )
    ).toMatch(/Available quantity/i);
  });

  test("❌ rejects available quantity above total quantity", () => {
    expect(
      validateResourceInput(
        { name: "X", type: "Y", totalQuantity: 5, availableQuantity: 9 },
        { partial: false }
      )
    ).toMatch(/cannot exceed/i);
  });

  test("✅ partial updates are checked against the stored row", () => {
    const existing = { totalQuantity: 10, availableQuantity: 4 };

    expect(
      validateResourceInput({ availableQuantity: 8 }, { partial: true }, existing)
    ).toBeNull();

    expect(
      validateResourceInput(
        { availableQuantity: 12 },
        { partial: true },
        existing
      )
    ).toMatch(/cannot exceed/i);
  });

  test("❌ rejects an invalid low stock threshold or isActive flag", () => {
    expect(
      validateResourceInput(
        { name: "X", type: "Y", lowStockThreshold: -2 },
        { partial: false }
      )
    ).toMatch(/Low stock threshold/i);

    expect(
      validateResourceInput(
        { name: "X", type: "Y", isActive: "yes" },
        { partial: false }
      )
    ).toMatch(/isActive/i);
  });
});

describe("Resource normalization", () => {
  test("✅ drops unknown keys and trims text", () => {
    const data = normalizeResourceInput(
      {
        name: "  Rescue Boat  ",
        type: " RESCUE ",
        unit: " boat ",
        location: "  Kochi, Kerala  ",
        totalQuantity: 4,
        availableQuantity: 2,
        id: 999,
        createdAt: "hack",
      },
      { partial: false }
    );

    expect(data).toEqual({
      name: "Rescue Boat",
      type: "RESCUE",
      unit: "boat",
      location: "Kochi, Kerala",
      totalQuantity: 4,
      availableQuantity: 2,
    });
  });

  test("✅ a new resource defaults to fully available", () => {
    const data = normalizeResourceInput(
      { name: "Drone", type: "AERIAL", totalQuantity: 6 },
      { partial: false }
    );

    expect(data.availableQuantity).toBe(6);
  });

  test("✅ partial updates only carry the provided fields", () => {
    const data = normalizeResourceInput(
      { availableQuantity: 3, isActive: false },
      { partial: true }
    );

    expect(data).toEqual({ availableQuantity: 3, isActive: false });
  });
});
