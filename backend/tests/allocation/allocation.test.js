const request = require("supertest");
const jwt = require("jsonwebtoken");

const app = require("../../src/app");
const prisma = require("../../src/config/prisma");
const env = require("../../src/config/env");
const allocationService = require("../../src/services/allocationService");

describe("Allocation Lifecycle", () => {
  let requester;
  let requester2;
  let responder;
  let responder2;
  let admin;

  let requesterToken;
  let requester2Token;
  let responderToken;
  let responder2Token;
  let adminToken;

  let resource;
  let resource2;
  let responderResource;
  let responderResource2;

  beforeAll(async () => {
    // -----------------------------------------------------
    // CLEAN ONLY OUR TEST DATA
    // -----------------------------------------------------

    await prisma.allocation.deleteMany({
      where: {
        OR: [
          {
            responder: {
              email: {
                in: [
                  "allocation-responder@test.com",
                  "allocation-responder2@test.com",
                ],
              },
            },
          },
          {
            request: {
              requester: {
                email: {
                  in: [
                    "allocation-requester@test.com",
                    "allocation-requester2@test.com",
                  ],
                },
              },
            },
          },
        ],
      },
    });

    await prisma.requestResource.deleteMany({
      where: {
        request: {
          requester: {
            email: {
              in: [
                "allocation-requester@test.com",
                "allocation-requester2@test.com",
              ],
            },
          },
        },
      },
    });

    await prisma.emergencyRequest.deleteMany({
      where: {
        requester: {
          email: {
            in: [
              "allocation-requester@test.com",
              "allocation-requester2@test.com",
            ],
          },
        },
      },
    });

    await prisma.responderResource.deleteMany({
      where: {
        responder: {
          email: {
            in: [
              "allocation-responder@test.com",
              "allocation-responder2@test.com",
            ],
          },
        },
      },
    });

    await prisma.resource.deleteMany({
      where: {
        name: {
          in: ["Allocation Test Resource", "Allocation Test Resource 2"],
        },
      },
    });

    await prisma.user.deleteMany({
      where: {
        email: {
          in: [
            "allocation-requester@test.com",
            "allocation-requester2@test.com",
            "allocation-responder@test.com",
            "allocation-responder2@test.com",
            "allocation-admin@test.com",
          ],
        },
      },
    });

    // -----------------------------------------------------
    // CREATE USERS
    // -----------------------------------------------------

    requester = await prisma.user.create({
      data: {
        name: "Allocation Requester",
        email: "allocation-requester@test.com",
        password: "test-password",
        role: "REQUESTER",
        isActive: true,
      },
    });

    requester2 = await prisma.user.create({
      data: {
        name: "Allocation Requester 2",
        email: "allocation-requester2@test.com",
        password: "test-password",
        role: "REQUESTER",
        isActive: true,
      },
    });

    responder = await prisma.user.create({
      data: {
        name: "Allocation Responder",
        email: "allocation-responder@test.com",
        password: "test-password",
        role: "RESPONDER",
        responderStatus: "AVAILABLE",
        isActive: true,
      },
    });

    responder2 = await prisma.user.create({
      data: {
        name: "Allocation Responder 2",
        email: "allocation-responder2@test.com",
        password: "test-password",
        role: "RESPONDER",
        responderStatus: "AVAILABLE",
        isActive: true,
      },
    });

    admin = await prisma.user.create({
      data: {
        name: "Allocation Admin",
        email: "allocation-admin@test.com",
        password: "test-password",
        role: "ADMIN",
        isActive: true,
      },
    });

    // -----------------------------------------------------
    // TOKENS
    // -----------------------------------------------------

    requesterToken = jwt.sign(
      {
        userId: requester.id,
        role: requester.role,
      },
      env.JWT_SECRET,
      { expiresIn: "1h" }
    );

    requester2Token = jwt.sign(
      {
        userId: requester2.id,
        role: requester2.role,
      },
      env.JWT_SECRET,
      { expiresIn: "1h" }
    );

    responderToken = jwt.sign(
      {
        userId: responder.id,
        role: responder.role,
      },
      env.JWT_SECRET,
      { expiresIn: "1h" }
    );

    responder2Token = jwt.sign(
      {
        userId: responder2.id,
        role: responder2.role,
      },
      env.JWT_SECRET,
      { expiresIn: "1h" }
    );

    adminToken = jwt.sign(
      {
        userId: admin.id,
        role: admin.role,
      },
      env.JWT_SECRET,
      { expiresIn: "1h" }
    );

    // -----------------------------------------------------
    // RESOURCES
    // -----------------------------------------------------

    resource = await prisma.resource.create({
      data: {
        name: "Allocation Test Resource",
        type: "Medical",
        totalQuantity: 100,
        availableQuantity: 100,
        unit: "unit",
      },
    });

    resource2 = await prisma.resource.create({
      data: {
        name: "Allocation Test Resource 2",
        type: "Medical",
        totalQuantity: 100,
        availableQuantity: 100,
        unit: "unit",
      },
    });

    // -----------------------------------------------------
    // RESPONDER INVENTORY
    // -----------------------------------------------------

    responderResource = await prisma.responderResource.create({
      data: {
        responderId: responder.id,
        resourceId: resource.id,
        totalQuantity: 10,
        availableQuantity: 10,
        status: "AVAILABLE",
      },
    });

    responderResource2 = await prisma.responderResource.create({
      data: {
        responderId: responder2.id,
        resourceId: resource2.id,
        totalQuantity: 10,
        availableQuantity: 10,
        status: "AVAILABLE",
      },
    });
  });

  afterEach(async () => {
    // Delete allocations first because they reference requests/resources.
    await prisma.allocation.deleteMany({
      where: {
        OR: [
          { responderId: responder.id },
          { responderId: responder2.id },
        ],
      },
    });

    await prisma.requestResource.deleteMany({
      where: {
        request: {
          requesterId: {
            in: [requester.id, requester2.id],
          },
        },
      },
    });

    await prisma.emergencyRequest.deleteMany({
      where: {
        requesterId: {
          in: [requester.id, requester2.id],
        },
      },
    });

    // Reset test inventory after every test.
    await prisma.responderResource.update({
      where: { id: responderResource.id },
      data: {
        totalQuantity: 10,
        availableQuantity: 10,
        status: "AVAILABLE",
      },
    });

    await prisma.responderResource.update({
      where: { id: responderResource2.id },
      data: {
        totalQuantity: 10,
        availableQuantity: 10,
        status: "AVAILABLE",
      },
    });
  });

  afterAll(async () => {
    await prisma.allocation.deleteMany({
      where: {
        OR: [
          { responderId: responder.id },
          { responderId: responder2.id },
        ],
      },
    });

    await prisma.requestResource.deleteMany({
      where: {
        request: {
          requesterId: {
            in: [requester.id, requester2.id],
          },
        },
      },
    });

    await prisma.emergencyRequest.deleteMany({
      where: {
        requesterId: {
          in: [requester.id, requester2.id],
        },
      },
    });

    await prisma.responderResource.deleteMany({
      where: {
        id: {
          in: [responderResource.id, responderResource2.id],
        },
      },
    });

    await prisma.resource.deleteMany({
      where: {
        id: {
          in: [resource.id, resource2.id],
        },
      },
    });

    await prisma.user.deleteMany({
      where: {
        email: {
          in: [
            "allocation-requester@test.com",
            "allocation-requester2@test.com",
            "allocation-responder@test.com",
            "allocation-responder2@test.com",
            "allocation-admin@test.com",
          ],
        },
      },
    });

    await prisma.$disconnect();
  });

  // =====================================================
  // HELPER
  // =====================================================

  async function createPendingRequest(quantity = 5) {
    return await prisma.emergencyRequest.create({
      data: {
        requesterId: requester.id,
        emergencyType: "Medical",
        description: "Allocation test emergency",
        location: "Thrissur",
        priority: "HIGH",
        status: "PENDING",

        requiredResources: {
          create: {
            resourceId: resource.id,
            quantity,
          },
        },
      },
    });
  }

  // =====================================================
  // CREATE ALLOCATION
  // =====================================================

  test("✅ RESPONDER can create an allocation", async () => {
    const emergency = await createPendingRequest(5);

    const res = await request(app)
      .post("/api/allocations")
      .set("Authorization", `Bearer ${responderToken}`)
      .send({
        requestId: emergency.id,
        responderResourceId: responderResource.id,
        resourceId: resource.id,
        quantity: 2,
      });

    expect(res.statusCode).toBe(201);
    expect(res.body.success).toBe(true);
    expect(res.body.allocation).toBeDefined();

    const allocation = await prisma.allocation.findUnique({
      where: {
        id: res.body.allocation.id,
      },
    });

    expect(allocation.quantity).toBe(2);
    expect(allocation.responderId).toBe(responder.id);
    expect(allocation.resourceId).toBe(resource.id);
    expect(allocation.status).toBe("RESERVED");

    const inventory = await prisma.responderResource.findUnique({
      where: {
        id: responderResource.id,
      },
    });

    expect(inventory.availableQuantity).toBe(8);
  });

  test("❌ REQUESTER cannot create an allocation", async () => {
    const emergency = await createPendingRequest(5);

    const res = await request(app)
      .post("/api/allocations")
      .set("Authorization", `Bearer ${requesterToken}`)
      .send({
        requestId: emergency.id,
        responderResourceId: responderResource.id,
        resourceId: resource.id,
        quantity: 1,
      });

    expect(res.statusCode).toBe(403);
    expect(res.body.message).toContain("Access denied");
  });

  test("❌ ADMIN cannot create an allocation", async () => {
    const emergency = await createPendingRequest(5);

    const res = await request(app)
      .post("/api/allocations")
      .set("Authorization", `Bearer ${adminToken}`)
      .send({
        requestId: emergency.id,
        responderResourceId: responderResource.id,
        resourceId: resource.id,
        quantity: 1,
      });

    expect(res.statusCode).toBe(403);
  });

  test("❌ Responder cannot allocate another responder's resource", async () => {
    const emergency = await createPendingRequest(5);

    const res = await request(app)
      .post("/api/allocations")
      .set("Authorization", `Bearer ${responderToken}`)
      .send({
        requestId: emergency.id,
        responderResourceId: responderResource2.id,
        resourceId: resource2.id,
        quantity: 1,
      });

    expect(res.statusCode).toBe(500);
    expect(res.body.message).toContain(
      "Responder mismatch: unauthorized"
    );
  });

  test("❌ Resource ID must match responder resource", async () => {
    const emergency = await createPendingRequest(5);

    const res = await request(app)
      .post("/api/allocations")
      .set("Authorization", `Bearer ${responderToken}`)
      .send({
        requestId: emergency.id,
        responderResourceId: responderResource.id,
        resourceId: resource2.id,
        quantity: 1,
      });

    expect(res.statusCode).toBe(500);
    expect(res.body.message).toContain("Resource mismatch");
  });

  test("❌ Cannot allocate more than available quantity", async () => {
    const emergency = await createPendingRequest(20);

    const res = await request(app)
      .post("/api/allocations")
      .set("Authorization", `Bearer ${responderToken}`)
      .send({
        requestId: emergency.id,
        responderResourceId: responderResource.id,
        resourceId: resource.id,
        quantity: 11,
      });

    expect(res.statusCode).toBe(500);
    expect(res.body.message).toContain(
      "Not enough available quantity"
    );

    const inventory = await prisma.responderResource.findUnique({
      where: {
        id: responderResource.id,
      },
    });

    expect(inventory.availableQuantity).toBe(10);
  });

  test("❌ Quantity must be greater than zero", async () => {
    const emergency = await createPendingRequest(5);

    const res = await request(app)
      .post("/api/allocations")
      .set("Authorization", `Bearer ${responderToken}`)
      .send({
        requestId: emergency.id,
        responderResourceId: responderResource.id,
        resourceId: resource.id,
        quantity: -2,
      });

    expect(res.statusCode).toBe(500);
    expect(res.body.message).toContain(
      "Quantity must be greater than 0"
    );
  });

  test("❌ Cannot allocate to a cancelled request", async () => {
    const emergency = await createPendingRequest(5);

    await prisma.emergencyRequest.update({
      where: {
        id: emergency.id,
      },
      data: {
        status: "CANCELLED",
      },
    });

    const res = await request(app)
      .post("/api/allocations")
      .set("Authorization", `Bearer ${responderToken}`)
      .send({
        requestId: emergency.id,
        responderResourceId: responderResource.id,
        resourceId: resource.id,
        quantity: 1,
      });

    expect(res.statusCode).toBe(500);
    expect(res.body.message).toContain(
      "Request is invalid or already closed"
    );
  });

  test("✅ Cancelling an allocation restores inventory", async () => {
    const emergency = await createPendingRequest(5);

    const allocation = await allocationService.createAllocation(
      responder.id,
      {
        requestId: emergency.id,
        responderResourceId: responderResource.id,
        resourceId: resource.id,
        quantity: 3,
      }
    );

    let inventory = await prisma.responderResource.findUnique({
      where: {
        id: responderResource.id,
      },
    });

    expect(inventory.availableQuantity).toBe(7);

    const cancelled = await allocationService.updateAllocationStatus(
      responder.id,
      allocation.id,
      "CANCELLED"
    );

    expect(cancelled.status).toBe("CANCELLED");

    inventory = await prisma.responderResource.findUnique({
      where: {
        id: responderResource.id,
      },
    });

    expect(inventory.availableQuantity).toBe(10);
  });

  test("❌ Cannot cancel the same allocation twice", async () => {
    const emergency = await createPendingRequest(5);

    const allocation = await allocationService.createAllocation(
      responder.id,
      {
        requestId: emergency.id,
        responderResourceId: responderResource.id,
        resourceId: resource.id,
        quantity: 2,
      }
    );

    await allocationService.updateAllocationStatus(
      responder.id,
      allocation.id,
      "CANCELLED"
    );

    await expect(
      allocationService.updateAllocationStatus(
        responder.id,
        allocation.id,
        "CANCELLED"
      )
    ).rejects.toThrow("Already cancelled");
  });

  test("✅ Concurrent allocations cannot overspend inventory", async () => {
    const emergency = await createPendingRequest(5);

    // Reset inventory to exactly 3 for this concurrency test.
    await prisma.responderResource.update({
      where: {
        id: responderResource.id,
      },
      data: {
        totalQuantity: 3,
        availableQuantity: 3,
      },
    });

    const allocation1 = request(app)
      .post("/api/allocations")
      .set("Authorization", `Bearer ${responderToken}`)
      .send({
        requestId: emergency.id,
        responderResourceId: responderResource.id,
        resourceId: resource.id,
        quantity: 2,
      });

    const allocation2 = request(app)
      .post("/api/allocations")
      .set("Authorization", `Bearer ${responderToken}`)
      .send({
        requestId: emergency.id,
        responderResourceId: responderResource.id,
        resourceId: resource.id,
        quantity: 2,
      });

    const [res1, res2] = await Promise.all([
      allocation1,
      allocation2,
    ]);

    const successCount = [res1, res2].filter(
      (res) => res.statusCode === 201
    ).length;

    const insufficientCount = [res1, res2].filter(
      (res) =>
        res.statusCode === 500 &&
        res.body &&
        res.body.message &&
        res.body.message.includes(
          "Not enough available quantity"
        )
    ).length;

    expect(successCount).toBe(1);
    expect(insufficientCount).toBe(1);

    const inventory = await prisma.responderResource.findUnique({
      where: {
        id: responderResource.id,
      },
    });

    expect(inventory.availableQuantity).toBe(1);
  });
});