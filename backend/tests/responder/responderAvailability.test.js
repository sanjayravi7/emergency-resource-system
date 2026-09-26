const request = require("supertest");
const jwt = require("jsonwebtoken");

const app = require("../../src/app");
const prisma = require("../../src/config/prisma");
const env = require("../../src/config/env");
const allocationService = require("../../src/services/allocationService");

/**
 * GET /api/responders/me/availability
 *
 * The responder UI must show "BUSY - 2 unfinished allocations" from persisted
 * PostgreSQL state only. This suite proves:
 *   - the counts are real (RESERVED + DISPATCHED, DELIVERED excluded)
 *   - the identity comes from the JWT, never from the request
 *   - other roles cannot read it
 */
describe("Responder availability (workload read model)", () => {
  const emails = [
    "availability-requester@test.com",
    "availability-responder@test.com",
    "availability-other@test.com",
    "availability-admin@test.com",
  ];
  const resourceNames = ["Availability Test Resource"];

  let requester;
  let responder;
  let otherResponder;
  let admin;

  let requesterToken;
  let responderToken;
  let otherResponderToken;
  let adminToken;

  let resource;
  let responderResource;

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
    await prisma.resource.deleteMany({ where: { name: { in: resourceNames } } });
    await prisma.user.deleteMany({ where: { email: { in: emails } } });
  }

  function tokenFor(user) {
    return jwt.sign({ userId: user.id, role: user.role }, env.JWT_SECRET, {
      expiresIn: "1h",
    });
  }

  beforeAll(async () => {
    await cleanup();

    requester = await prisma.user.create({
      data: {
        name: "Availability Requester",
        email: "availability-requester@test.com",
        password: "test-password",
        role: "REQUESTER",
        isActive: true,
      },
    });

    responder = await prisma.user.create({
      data: {
        name: "Availability Responder",
        email: "availability-responder@test.com",
        password: "test-password",
        role: "RESPONDER",
        responderStatus: "AVAILABLE",
        isActive: true,
      },
    });

    otherResponder = await prisma.user.create({
      data: {
        name: "Availability Other Responder",
        email: "availability-other@test.com",
        password: "test-password",
        role: "RESPONDER",
        responderStatus: "AVAILABLE",
        isActive: true,
      },
    });

    admin = await prisma.user.create({
      data: {
        name: "Availability Admin",
        email: "availability-admin@test.com",
        password: "test-password",
        role: "ADMIN",
        isActive: true,
      },
    });

    requesterToken = tokenFor(requester);
    responderToken = tokenFor(responder);
    otherResponderToken = tokenFor(otherResponder);
    adminToken = tokenFor(admin);

    resource = await prisma.resource.create({
      data: {
        name: "Availability Test Resource",
        type: "Medical",
        totalQuantity: 100,
        availableQuantity: 100,
        unit: "unit",
      },
    });

    responderResource = await prisma.responderResource.create({
      data: {
        responderId: responder.id,
        resourceId: resource.id,
        totalQuantity: 20,
        availableQuantity: 20,
        isEnabled: true,
        status: "AVAILABLE",
      },
    });
  });

  afterEach(async () => {
    await prisma.allocation.deleteMany({
      where: { responderId: { in: [responder.id, otherResponder.id] } },
    });
    await prisma.requestResource.deleteMany({
      where: { request: { requesterId: requester.id } },
    });
    await prisma.emergencyRequest.deleteMany({
      where: { requesterId: requester.id },
    });
    await prisma.responderResource.update({
      where: { id: responderResource.id },
      data: { totalQuantity: 20, availableQuantity: 20, status: "AVAILABLE" },
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

  async function createAcceptedRequest(quantity = 4) {
    const emergency = await prisma.emergencyRequest.create({
      data: {
        requesterId: requester.id,
        emergencyType: "Medical",
        description: "Availability workload test emergency",
        location: "Thrissur",
        priority: "HIGH",
        status: "ACCEPTED",
        acceptedById: responder.id,
        acceptedAt: new Date(),
        requiredResources: {
          create: [{ resourceId: resource.id, quantity }],
        },
      },
    });
    return emergency;
  }

  function readAvailability(token) {
    return request(app)
      .get("/api/responders/me/availability")
      .set("Authorization", `Bearer ${token}`);
  }

  test("reports AVAILABLE with no unfinished work", async () => {
    const response = await readAvailability(responderToken);

    expect(response.status).toBe(200);
    expect(response.body.success).toBe(true);
    expect(response.body.availability).toMatchObject({
      responderId: responder.id,
      unfinishedAllocations: 0,
      reservedAllocations: 0,
      dispatchedAllocations: 0,
      activeRequests: 0,
    });
  });

  test("counts RESERVED and DISPATCHED allocations as unfinished work", async () => {
    const emergency = await createAcceptedRequest(4);

    const reserved = await allocationService.createAllocation(responder.id, {
      requestId: emergency.id,
      responderResourceId: responderResource.id,
      resourceId: resource.id,
      quantity: 1,
    });

    const toDispatch = await allocationService.createAllocation(responder.id, {
      requestId: emergency.id,
      responderResourceId: responderResource.id,
      resourceId: resource.id,
      quantity: 1,
    });
    await allocationService.updateAllocationStatus(
      responder.id,
      toDispatch.id,
      "DISPATCHED"
    );

    const response = await readAvailability(responderToken);

    expect(response.status).toBe(200);
    expect(response.body.availability.reservedAllocations).toBe(1);
    expect(response.body.availability.dispatchedAllocations).toBe(1);
    expect(response.body.availability.unfinishedAllocations).toBe(2);
    expect(response.body.availability.activeRequests).toBeGreaterThanOrEqual(1);
    // Status is the persisted one recomputed by the lifecycle service.
    expect(response.body.availability.responderStatus).toBe("BUSY");
    expect(reserved.status).toBe("RESERVED");
  });

  test("a DELIVERED allocation no longer counts as unfinished work", async () => {
    const emergency = await createAcceptedRequest(1);

    const allocation = await allocationService.createAllocation(responder.id, {
      requestId: emergency.id,
      responderResourceId: responderResource.id,
      resourceId: resource.id,
      quantity: 1,
    });
    await allocationService.updateAllocationStatus(
      responder.id,
      allocation.id,
      "DISPATCHED"
    );
    await allocationService.updateAllocationStatus(
      responder.id,
      allocation.id,
      "DELIVERED"
    );

    const response = await readAvailability(responderToken);

    expect(response.status).toBe(200);
    expect(response.body.availability.unfinishedAllocations).toBe(0);
    expect(response.body.availability.responderStatus).toBe("AVAILABLE");
  });

  test("each responder only ever reads their own workload", async () => {
    const emergency = await createAcceptedRequest(2);
    await allocationService.createAllocation(responder.id, {
      requestId: emergency.id,
      responderResourceId: responderResource.id,
      resourceId: resource.id,
      quantity: 1,
    });

    const mine = await readAvailability(responderToken);
    const theirs = await readAvailability(otherResponderToken);

    expect(mine.body.availability.responderId).toBe(responder.id);
    expect(mine.body.availability.unfinishedAllocations).toBe(1);

    // The other responder's identity comes from their own JWT: no request
    // field can be used to read someone else's workload.
    expect(theirs.body.availability.responderId).toBe(otherResponder.id);
    expect(theirs.body.availability.unfinishedAllocations).toBe(0);
  });

  test("requesters and admins cannot read the responder workload endpoint", async () => {
    const asRequester = await readAvailability(requesterToken);
    const asAdmin = await readAvailability(adminToken);

    expect(asRequester.status).toBe(403);
    expect(asAdmin.status).toBe(403);
  });

  test("requires authentication", async () => {
    const response = await request(app).get(
      "/api/responders/me/availability"
    );

    expect(response.status).toBe(401);
  });
});
