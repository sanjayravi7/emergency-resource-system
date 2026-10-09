// Database-independent contract for the catalog/stock boundary. The lifecycle
// integration tests in resourceModes.test.js exercise mutations and allocations.
const mockPrisma = {
  resource: { findMany: jest.fn() },
  responderResource: { groupBy: jest.fn(), count: jest.fn() },
};
jest.mock('../../src/config/prisma', () => mockPrisma);
const { getResourceAvailability, getConsumableStock } = require('../../src/services/resourceService');

describe('derived operational inventory', () => {
  beforeEach(() => jest.clearAllMocks());

  test('returns responder stock despite zero master quantity; groups each eligible inventory row once', async () => {
    mockPrisma.resource.findMany.mockResolvedValue([
      { id: 1, name: 'Water', type: 'SUPPLY', mode: 'CONSUMABLE', unit: 'litres',
        totalQuantity: 0, availableQuantity: 0 },
      { id: 2, name: 'Rescue', type: 'TEAM', mode: 'SERVICE', unit: null },
    ]);
    mockPrisma.responderResource.groupBy.mockResolvedValue([
      { resourceId: 1, _sum: { totalQuantity: 18, availableQuantity: 8 } },
    ]);
    mockPrisma.responderResource.count.mockResolvedValue(2);
    const rows = await getResourceAvailability();
    expect(rows[0]).toMatchObject({ totalQuantity: 18, availableQuantity: 8,
      availableResponders: null });
    expect(rows[1]).toMatchObject({ availableResponders: 2, availableQuantity: null });
    expect(mockPrisma.responderResource.groupBy).toHaveBeenCalledWith(expect.objectContaining({
      by: ['resourceId'],
      where: expect.objectContaining({
        resourceId: { in: [1] }, isEnabled: true, status: 'AVAILABLE',
        availableQuantity: { gt: 0 },
        responder: { role: 'RESPONDER', isActive: true,
          responderStatus: { in: ['AVAILABLE', 'BUSY'] } },
        resource: { isActive: true, mode: 'CONSUMABLE' },
      }),
      _sum: { totalQuantity: true, availableQuantity: true },
    }));
  });

  test('no inventory returns zero, and an empty resource list skips querying stock', async () => {
    mockPrisma.responderResource.groupBy.mockResolvedValue([]);
    expect((await getConsumableStock([1])).get(1)).toBeUndefined();
    expect(await getConsumableStock([])).toEqual(new Map());
    expect(mockPrisma.responderResource.groupBy).toHaveBeenCalledTimes(1);
  });
});
