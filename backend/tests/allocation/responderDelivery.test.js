const request = require("supertest");
const jwt = require("jsonwebtoken");

const app = require("../../src/app");
const prisma = require("../../src/config/prisma");
const env = require("../../src/config/env");
const allocationService = require("../../src/services/allocationService");

/**
 * Responder "Mark Delivered" fallback.
 *
 * DISPATCHED → DELIVERED may now be completed by BOTH actors:
 *   - the requester via  PATCH /api/allocations/:id/received
 *   - the owning responder via PATCH /api/allocations/:id/status
 *
 * Responder availability must always be recomputed by
 * syncResponderAvailability, never forced from the client.
 */
describe("Responder Mark Delivered Fallback", () => {
  let requester;
  let responder;
  let responder2;

  let requesterToken;
  let responderToken;
  let responder2Token;

  let resource; // CONSUMABLE
  let resource2; // CONSUMABLE (second required line for multi-resource tests)
  let responderResource;
  let responderResource2;

  const emails = [
    "delivery-requester@test.com",
    "delivery-responder@test.com",
    "delivery-responder2@test.com",
  ];
  const resourceNames = [
    "Delivery Test Resource",
    "Delivery Test Resource 2",
  ];

  async function cleanup() {
    await prisma.allocation.deleteMany({
      where: {
        OR: [
          { responder: { email: { in: emails } } },
          { request: { requester: { email: { in: emails } } } },
        ],
      },
    });

    await prisma.requestResource.deleteMany({
      where: { request: { requester: { email: { in: emails } } } },
    });

    await prisma.emergencyRequest.deleteMany({
      where: { requester: { email: { in: emails } } },
    });

    await prisma.responderResource.deleteMany({
      where: { responder: { email: { in: emails } } },
    });

    await prisma.resource.deleteMany({
      where: { name: { in: resourceNames } },
    });

    await prisma.user.deleteMany({
      where: { email: { in: emails } },
    });
  }

  beforeAll(async () => {
    await cleanup();

    requester = await prisma.user.create({
      data: {
        name: "Delivery Requester",
        email: "delivery-requester@test.com",
        password: "test-password",
        role: "REQUESTER",
        isActive: true,
      },
    });

    responder = await prisma.user.create({
      data: {
        name: "Delivery Responder",
        email: "delivery-responder@test.com",
        password: "test-password",
        role: "RESPONDER",
        responderStatus: "AVAILABLE",
        isActive: true,
      },
    });

    responder2 = await prisma.user.create({
      data: {
        name: "Delivery Responder 2",
        email: "delivery-responder2@test.com",
        password: "test-password",
        role: "RESPONDER",
        responderStatus: "AVAILABLE",
        isActive: true,
      },
    });

    requesterToken = jwt.sign(
      { userId: requester.id, role: requester.role },
      env.JWT_SECRET,
      { expiresIn: "1h" }
    );

    responderToken = jwt.sign(
      { userId: responder.id, role: responder.role },
      env.JWT_SECRET,
      { expiresIn: "1h" }
    );

    responder2Token = jwt.sign(
      { userId: responder2.id, role: responder2.role },
      env.JWT_SECRET,
      { expiresIn: "1h" }
    );

    // Both resources default to CONSUMABLE mode, so allocations decrement
    // spendable inventory and deliveries must never restore it.
    resource = await prisma.resource.create({
      data: {
        name: "Delivery Test Resource",
        type: "Medical",
        totalQuantity: 100,
        availableQuantity: 100,
        unit: "unit",
      },
    });

    resource2 = await prisma.resource.create({
      data: {
        name: "Delivery Test Resource 2",
        type: "Medical",
        totalQuantity: 100,
        availableQuantity: 100,
        unit: "unit",
      },
    });

    // isEnabled keeps the capability usable so the responder can legally
    // return to AVAILABLE once all work is finished.
    responderResource = await prisma.responderResource.create({
      data: {
        responderId: responder.id,
        resourceId: resource.id,
        totalQuantity: 10,
        availableQuantity: 10,
        isEnabled: true,
        status: "AVAILABLE",
      },
    });

    responderResource2 = await prisma.responderResource.create({
      data: {
        responderId: responder.id,
        resourceId: resource2.id,
        totalQuantity: 10,
        availableQuantity: 10,
        isEnabled: true,
        status: "AVAILABLE",
      },
    });
  });

  afterEach(async () => {
    await prisma.allocation.deleteMany({
      where: { responderId: { in: [responder.id, responder2.id] } },
    });

    await prisma.requestResource.deleteMany({
      where: { request: { requesterId: requester.id } },
    });

    await prisma.emergencyRequest.deleteMany({
      where: { requesterId: requester.id },
    });

    await prisma.responderResource.update({
      where: { id: responderResource.id },
      data: { totalQuantity: 10, availableQuantity: 10, status: "AVAILABLE" },
    });

    await prisma.responderResource.update({
      where: { id: responderResource2.id },
      data: { totalQuantity: 10, availableQuantity: 10, status: "AVAILABLE" },
    });

    await prisma.user.update({
      where: { id: responder.id },
      data: { responderStatus: "AVAILABLE" },
    });
  });

  afterAll(async () => {
    await cleanup();
    await prisma.$disconnect();
  });

  // =====================================================
  // HELPERS
  // =====================================================

  async function createPendingRequest({
    quantity = 2,
    withSecondResource = false,
    secondQuantity = 1,
  } = {}) {
    return prisma.emergencyRequest.create({
      data: {
        requesterId: requester.id,
        emergencyType: "Medical",
        description: "Responder delivery fallback test emergency",
        location: "Thrissur",
        priority: "HIGH",
        status: "PENDING",
        requiredResources: {
          create: [
            { resourceId: resource.id, quantity },
            ...(withSecondResource
              ? [{ resourceId: resource2.id, quantity: secondQuantity }]
              : []),
          ],
        },
      },
    });
  }

  async function createDispatchedAllocation(emergency, quantity = 2) {
    const allocation = await allocationService.createAllocation(responder.id, {
      requestId: emergency.id,
      responderResourceId: responderResource.id,
      resourceId: resource.id,
      quantity,
    });

    return allocationService.updateAllocationStatus(
      responder.id,
      allocation.id,
      "DISPATCHED"
    );
  }

  function patchStatus(allocationId, status, token = responderToken) {
    return request(app)
      .patch(`/api/allocations/${allocationId}/status`)
      .set("Authorization", `Bearer ${token}`)
      .send({ status });
  }

  // =====================================================
  // HAPPY PATH
  // =====================================================

  test("✅ Responder can mark a DISPATCHED allocation DELIVERED and it persists", async () => {
    const emergency = await createPendingRequest({ quantity: 2 });
    const dispatched = await createDispatchedAllocation(emergency, 2);

    const res = await patchStatus(dispatched.id, "DELIVERED");

    expect(res.statusCode).toBe(200);
    expect(res.body.success).toBe(true);
    expect(res.body.allocation.status).toBe("DELIVERED");

    // Persisted in PostgreSQL, not just echoed back.
    const stored = await prisma.allocation.findUnique({
      where: { id: dispatched.id },
    });
    expect(stored.status).toBe("DELIVERED");
  });

  test("✅ Responder becomes AVAILABLE after final delivery with no other unfinished work", async () => {
    const emergency = await createPendingRequest({ quantity: 2 });
    const dispatched = await createDispatchedAllocation(emergency, 2);

    // While DISPATCHED the responder is BUSY.
    let user = await prisma.user.findUnique({ where: { id: responder.id } });
    expect(user.responderStatus).toBe("BUSY");

    const res = await patchStatus(dispatched.id, "DELIVERED");
    expect(res.statusCode).toBe(200);

    // The request itself is fully delivered → COMPLETED.
    const storedRequest = await prisma.emergencyRequest.findUnique({
      where: { id: emergency.id },
    });
    expect(storedRequest.status).toBe("COMPLETED");

    // Availability was recomputed by syncResponderAvailability, not forced.
    user = await prisma.user.findUnique({ where: { id: responder.id } });
    expect(user.responderStatus).toBe("AVAILABLE");
  });

  test("✅ Responder stays BUSY while a sibling allocation is still DISPATCHED", async () => {
    const emergency = await createPendingRequest({
      quantity: 2,
      withSecondResource: true,
      secondQuantity: 1,
    });

    const dispatchedFirst = await createDispatchedAllocation(emergency, 2);

    const secondAllocation = await allocationService.createAllocation(
      responder.id,
      {
        requestId: emergency.id,
        responderResourceId: responderResource2.id,
        resourceId: resource2.id,
        quantity: 1,
      }
    );
    await allocationService.updateAllocationStatus(
      responder.id,
      secondAllocation.id,
      "DISPATCHED"
    );

    // Deliver only the first resource ("Ambulance delivered, Blood still out").
    const res = await patchStatus(dispatchedFirst.id, "DELIVERED");
    expect(res.statusCode).toBe(200);

    let user = await prisma.user.findUnique({ where: { id: responder.id } });
    expect(user.responderStatus).toBe("BUSY");

    const storedRequest = await prisma.emergencyRequest.findUnique({
      where: { id: emergency.id },
    });
    expect(storedRequest.status).toBe("PARTIALLY_ALLOCATED");

    // Delivering the remaining allocation releases the responder.
    const res2 = await patchStatus(secondAllocation.id, "DELIVERED");
    expect(res2.statusCode).toBe(200);

    user = await prisma.user.findUnique({ where: { id: responder.id } });
    expect(user.responderStatus).toBe("AVAILABLE");

    const completedRequest = await prisma.emergencyRequest.findUnique({
      where: { id: emergency.id },
    });
    expect(completedRequest.status).toBe("COMPLETED");
  });

  test("✅ CONSUMABLE inventory is NOT restored by marking DELIVERED", async () => {
    const emergency = await createPendingRequest({ quantity: 3 });
    const dispatched = await createDispatchedAllocation(emergency, 3);

    let inventory = await prisma.responderResource.findUnique({
      where: { id: responderResource.id },
    });
    expect(inventory.availableQuantity).toBe(7);

    const res = await patchStatus(dispatched.id, "DELIVERED");
    expect(res.statusCode).toBe(200);

    // The units were genuinely consumed: unlike CANCELLED, DELIVERED must
    // never put stock back.
    inventory = await prisma.responderResource.findUnique({
      where: { id: responderResource.id },
    });
    expect(inventory.availableQuantity).toBe(7);
    expect(inventory.totalQuantity).toBe(10);
  });

  // =====================================================
  // REJECTED TRANSITIONS
  // =====================================================

  test("❌ Responder cannot mark a RESERVED allocation DELIVERED", async () => {
    const emergency = await createPendingRequest({ quantity: 2 });
    const reserved = await allocationService.createAllocation(responder.id, {
      requestId: emergency.id,
      responderResourceId: responderResource.id,
      resourceId: resource.id,
      quantity: 2,
    });

    const res = await patchStatus(reserved.id, "DELIVERED");

    expect(res.statusCode).toBe(500);
    expect(res.body.message).toContain(
      "Only DISPATCHED allocations can be marked as delivered"
    );

    const stored = await prisma.allocation.findUnique({
      where: { id: reserved.id },
    });
    expect(stored.status).toBe("RESERVED");
  });

  test("❌ Another responder cannot mark someone else's allocation DELIVERED", async () => {
    const emergency = await createPendingRequest({ quantity: 2 });
    const dispatched = await createDispatchedAllocation(emergency, 2);

    const res = await patchStatus(dispatched.id, "DELIVERED", responder2Token);

    expect(res.statusCode).toBe(500);
    expect(res.body.message).toContain("Unauthorized");

    const stored = await prisma.allocation.findUnique({
      where: { id: dispatched.id },
    });
    expect(stored.status).toBe("DISPATCHED");
  });

  test("❌ A DELIVERED allocation cannot be delivered again", async () => {
    const emergency = await createPendingRequest({ quantity: 2 });
    const dispatched = await createDispatchedAllocation(emergency, 2);

    await patchStatus(dispatched.id, "DELIVERED");
    const res = await patchStatus(dispatched.id, "DELIVERED");

    expect(res.statusCode).toBe(500);
    expect(res.body.message).toContain("Already delivered");
  });

  test("❌ A CANCELLED allocation cannot be marked DELIVERED", async () => {
    const emergency = await createPendingRequest({ quantity: 2 });
    const dispatched = await createDispatchedAllocation(emergency, 2);

    await allocationService.updateAllocationStatus(
      responder.id,
      dispatched.id,
      "CANCELLED"
    );

    const res = await patchStatus(dispatched.id, "DELIVERED");

    expect(res.statusCode).toBe(500);
    expect(res.body.message).toContain("Already cancelled");
  });

  test("❌ A REQUESTER cannot use the responder status endpoint", async () => {
    const emergency = await createPendingRequest({ quantity: 2 });
    const dispatched = await createDispatchedAllocation(emergency, 2);

    const res = await patchStatus(dispatched.id, "DELIVERED", requesterToken);

    expect(res.statusCode).toBe(403);

    const stored = await prisma.allocation.findUnique({
      where: { id: dispatched.id },
    });
    expect(stored.status).toBe("DISPATCHED");
  });

  // =====================================================
  // REQUESTER FLOW REMAINS INTACT
  // =====================================================

  test("✅ Requester receipt confirmation still works", async () => {
    const emergency = await createPendingRequest({ quantity: 2 });
    const dispatched = await createDispatchedAllocation(emergency, 2);

    const res = await request(app)
      .patch(`/api/allocations/${dispatched.id}/received`)
      .set("Authorization", `Bearer ${requesterToken}`);

    expect(res.statusCode).toBe(200);
    expect(res.body.success).toBe(true);
    expect(res.body.allocation.status).toBe("DELIVERED");

    const user = await prisma.user.findUnique({ where: { id: responder.id } });
    expect(user.responderStatus).toBe("AVAILABLE");
  });

  test("✅ Requester and responder paths reach the same final state", async () => {
    // Path A: requester confirms receipt.
    const emergencyA = await createPendingRequest({ quantity: 2 });
    const dispatchedA = await createDispatchedAllocation(emergencyA, 2);

    await request(app)
      .patch(`/api/allocations/${dispatchedA.id}/received`)
      .set("Authorization", `Bearer ${requesterToken}`)
      .expect(200);

    const allocationA = await prisma.allocation.findUnique({
      where: { id: dispatchedA.id },
    });
    const requestA = await prisma.emergencyRequest.findUnique({
      where: { id: emergencyA.id },
    });
    const responderAfterA = await prisma.user.findUnique({
      where: { id: responder.id },
    });
    const inventoryAfterA = await prisma.responderResource.findUnique({
      where: { id: responderResource.id },
    });

    // Reset inventory between the two paths (afterEach normally does this).
    await prisma.responderResource.update({
      where: { id: responderResource.id },
      data: { totalQuantity: 10, availableQuantity: 10, status: "AVAILABLE" },
    });

    // Path B: responder marks delivered.
    const emergencyB = await createPendingRequest({ quantity: 2 });
    const dispatchedB = await createDispatchedAllocation(emergencyB, 2);

    await patchStatus(dispatchedB.id, "DELIVERED").expect(200);

    const allocationB = await prisma.allocation.findUnique({
      where: { id: dispatchedB.id },
    });
    const requestB = await prisma.emergencyRequest.findUnique({
      where: { id: emergencyB.id },
    });
    const responderAfterB = await prisma.user.findUnique({
      where: { id: responder.id },
    });
    const inventoryAfterB = await prisma.responderResource.findUnique({
      where: { id: responderResource.id },
    });

    expect(allocationA.status).toBe("DELIVERED");
    expect(allocationB.status).toBe(allocationA.status);
    expect(requestA.status).toBe("COMPLETED");
    expect(requestB.status).toBe(requestA.status);
    expect(responderAfterA.responderStatus).toBe("AVAILABLE");
    expect(responderAfterB.responderStatus).toBe(
      responderAfterA.responderStatus
    );
    expect(inventoryAfterA.availableQuantity).toBe(8);
    expect(inventoryAfterB.availableQuantity).toBe(
      inventoryAfterA.availableQuantity
    );
  });

  test("❌ Unsupported status values are still rejected", async () => {
    const emergency = await createPendingRequest({ quantity: 2 });
    const dispatched = await createDispatchedAllocation(emergency, 2);

    const res = await patchStatus(dispatched.id, "RESERVED");

    expect(res.statusCode).toBe(500);
    expect(res.body.message).toContain(
      "Responders may only dispatch, deliver, or cancel an allocation"
    );
  });
});
