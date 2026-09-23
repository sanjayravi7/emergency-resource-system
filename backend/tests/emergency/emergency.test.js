const request = require("supertest");
const jwt = require("jsonwebtoken");

const app = require("../../src/app");
const prisma = require("../../src/config/prisma");
const env = require("../../src/config/env");

describe("Emergency Request Lifecycle", () => {
  let requester;
  let requester2;
  let responder;
  let admin;

  let requesterToken;
  let requester2Token;
  let responderToken;
  let adminToken;

  beforeAll(async () => {
    // Clean only our test users
    await prisma.user.deleteMany({
      where: {
        email: {
          in: [
            "emergency-requester@test.com",
            "emergency-requester2@test.com",
            "emergency-responder@test.com",
            "emergency-admin@test.com",
          ],
        },
      },
    });

    requester = await prisma.user.create({
      data: {
        name: "Emergency Requester",
        email: "emergency-requester@test.com",
        password: "test-password",
        role: "REQUESTER",
        isActive: true,
      },
    });

    requester2 = await prisma.user.create({
      data: {
        name: "Emergency Requester 2",
        email: "emergency-requester2@test.com",
        password: "test-password",
        role: "REQUESTER",
        isActive: true,
      },
    });

    responder = await prisma.user.create({
      data: {
        name: "Emergency Responder",
        email: "emergency-responder@test.com",
        password: "test-password",
        role: "RESPONDER",
        responderStatus: "AVAILABLE",
        isActive: true,
      },
    });

    admin = await prisma.user.create({
      data: {
        name: "Emergency Admin",
        email: "emergency-admin@test.com",
        password: "test-password",
        role: "ADMIN",
        isActive: true,
      },
    });

    // Tokens match the payload used by the backend
    requesterToken = jwt.sign(
      {
        userId: requester.id,
        role: "REQUESTER",
      },
      env.JWT_SECRET,
      { expiresIn: "1h" }
    );

    requester2Token = jwt.sign(
      {
        userId: requester2.id,
        role: "REQUESTER",
      },
      env.JWT_SECRET,
      { expiresIn: "1h" }
    );

    responderToken = jwt.sign(
      {
        userId: responder.id,
        role: "RESPONDER",
      },
      env.JWT_SECRET,
      { expiresIn: "1h" }
    );

    adminToken = jwt.sign(
      {
        userId: admin.id,
        role: "ADMIN",
      },
      env.JWT_SECRET,
      { expiresIn: "1h" }
    );
  });

  afterEach(async () => {
    // Remove test emergency requests after each test.
    // Cascade removes RequestResource records.
    await prisma.emergencyRequest.deleteMany({
      where: {
        requesterId: {
          in: [requester.id, requester2.id],
        },
      },
    });
  });

  afterAll(async () => {
    await prisma.emergencyRequest.deleteMany({
      where: {
        requesterId: {
          in: [requester.id, requester2.id],
        },
      },
    });

    await prisma.user.deleteMany({
      where: {
        email: {
          in: [
            "emergency-requester@test.com",
            "emergency-requester2@test.com",
            "emergency-responder@test.com",
            "emergency-admin@test.com",
          ],
        },
      },
    });

    await prisma.$disconnect();
  });

  // =====================================================
  // ACCEPT EMERGENCY
  // =====================================================

 test("✅ RESPONDER can accept a PENDING emergency", async () => {
  const resource = await prisma.resource.create({
    data: {
      name: "Test Fire Resource",
      type: "FIRE",
      totalQuantity: 10,
      availableQuantity: 10,
      unit: "unit",
      location: "Thrissur",
    },
  });

  const responderResource = await prisma.responderResource.create({
    data: {
      responderId: responder.id,
      resourceId: resource.id,
      totalQuantity: 5,
      availableQuantity: 5,
      status: "AVAILABLE",
    },
  });

  const emergency = await prisma.emergencyRequest.create({
    data: {
      requesterId: requester.id,
      emergencyType: "Fire",
      description: "Building fire",
      location: "Thrissur",
      priority: "HIGH",
      status: "PENDING",
      requiredResources: {
        create: [
          {
            resourceId: resource.id,
            quantity: 1,
          },
        ],
      },
    },
  });

  await prisma.user.update({
    where: {
      id: responder.id,
    },
    data: {
      responderStatus: "AVAILABLE",
      isActive: true,
      lastActiveAt: new Date(),
    },
  });

  const res = await request(app)
    .patch(`/api/requests/${emergency.id}/accept`)
    .set("Authorization", `Bearer ${responderToken}`);

  expect(res.statusCode).toBe(200);

  const updated = await prisma.emergencyRequest.findUnique({
    where: {
      id: emergency.id,
    },
  });

  expect(updated.status).toBe("ACCEPTED");
  expect(updated.acceptedById).toBe(responder.id);
  expect(updated.acceptedAt).not.toBeNull();

  const updatedResponder = await prisma.user.findUnique({
    where: {
      id: responder.id,
    },
  });

  expect(updatedResponder.responderStatus).toBe("BUSY");

  await prisma.responderResource.delete({
    where: {
      id: responderResource.id,
    },
  });

  await prisma.resource.delete({
    where: {
      id: resource.id,
    },
  });
});

  test("❌ REQUESTER cannot accept an emergency", async () => {
    const emergency = await prisma.emergencyRequest.create({
      data: {
        requesterId: requester.id,
        emergencyType: "Accident",
        description: "Road accident",
        location: "Kodungallur",
        priority: "MEDIUM",
        status: "PENDING",
      },
    });

    const res = await request(app)
      .patch(`/api/requests/${emergency.id}/accept`)
      .set("Authorization", `Bearer ${requesterToken}`);

    expect(res.statusCode).toBe(403);
  });

  test("❌ ADMIN cannot accept an emergency", async () => {
    const emergency = await prisma.emergencyRequest.create({
      data: {
        requesterId: requester.id,
        emergencyType: "Flood",
        description: "Flood emergency",
        location: "Ernakulam",
        priority: "HIGH",
        status: "PENDING",
      },
    });

    const res = await request(app)
      .patch(`/api/requests/${emergency.id}/accept`)
      .set("Authorization", `Bearer ${adminToken}`);

    expect(res.statusCode).toBe(403);
  });

  test("❌ OFFLINE responder cannot accept an emergency", async () => {
    const emergency = await prisma.emergencyRequest.create({
      data: {
        requesterId: requester.id,
        emergencyType: "Medical",
        description: "Urgent medical assistance",
        location: "Thrissur",
        priority: "CRITICAL",
        status: "PENDING",
      },
    });

    await prisma.user.update({
      where: {
        id: responder.id,
      },
      data: {
        responderStatus: "OFFLINE",
      },
    });

    const res = await request(app)
      .patch(`/api/requests/${emergency.id}/accept`)
      .set("Authorization", `Bearer ${responderToken}`);

    expect(res.statusCode).toBe(400);
    expect(res.body.message).toContain("Responder is not available");

    // Restore responder for later tests
    await prisma.user.update({
      where: {
        id: responder.id,
      },
      data: {
        responderStatus: "AVAILABLE",
      },
    });
  });

  // =====================================================
  // CANCEL EMERGENCY
  // =====================================================

  test("✅ REQUESTER can cancel own PENDING emergency", async () => {
    const emergency = await prisma.emergencyRequest.create({
      data: {
        requesterId: requester.id,
        emergencyType: "Fire",
        description: "Small fire",
        location: "Thrissur",
        priority: "MEDIUM",
        status: "PENDING",
      },
    });

    const res = await request(app)
      .patch(`/api/requests/${emergency.id}/cancel`)
      .set("Authorization", `Bearer ${requesterToken}`);

    expect([200, 204]).toContain(res.statusCode);

    const updated = await prisma.emergencyRequest.findUnique({
      where: {
        id: emergency.id,
      },
    });

    expect(updated.status).toBe("CANCELLED");
  });

  test("❌ REQUESTER cannot cancel another user's emergency", async () => {
    const emergency = await prisma.emergencyRequest.create({
      data: {
        requesterId: requester.id,
        emergencyType: "Accident",
        description: "Vehicle accident",
        location: "Ernakulam",
        priority: "HIGH",
        status: "PENDING",
      },
    });

    const res = await request(app)
      .patch(`/api/requests/${emergency.id}/cancel`)
      .set("Authorization", `Bearer ${requester2Token}`);

    expect([403, 500]).toContain(res.statusCode);

    const unchanged = await prisma.emergencyRequest.findUnique({
      where: {
        id: emergency.id,
      },
    });

    expect(unchanged.status).toBe("PENDING");
  });

  test("❌ RESPONDER cannot cancel an emergency", async () => {
    const emergency = await prisma.emergencyRequest.create({
      data: {
        requesterId: requester.id,
        emergencyType: "Flood",
        description: "Flood assistance",
        location: "Thrissur",
        priority: "HIGH",
        status: "PENDING",
      },
    });

    const res = await request(app)
      .patch(`/api/requests/${emergency.id}/cancel`)
      .set("Authorization", `Bearer ${responderToken}`);

    expect(res.statusCode).toBe(403);
  });

  test("❌ ADMIN cannot cancel an emergency", async () => {
    const emergency = await prisma.emergencyRequest.create({
      data: {
        requesterId: requester.id,
        emergencyType: "Medical",
        description: "Medical emergency",
        location: "Kodungallur",
        priority: "CRITICAL",
        status: "PENDING",
      },
    });

    const res = await request(app)
      .patch(`/api/requests/${emergency.id}/cancel`)
      .set("Authorization", `Bearer ${adminToken}`);

    expect(res.statusCode).toBe(403);
  });

  test("❌ Cannot cancel an already ACCEPTED emergency", async () => {
    const emergency = await prisma.emergencyRequest.create({
      data: {
        requesterId: requester.id,
        emergencyType: "Fire",
        description: "Fire response",
        location: "Thrissur",
        priority: "HIGH",
        status: "ACCEPTED",
      },
    });

    const res = await request(app)
      .patch(`/api/requests/${emergency.id}/cancel`)
      .set("Authorization", `Bearer ${requesterToken}`);

    expect(res.statusCode).toBe(500);
    expect(res.body.message).toContain(
      "Only PENDING requests can be cancelled"
    );
  });

  test("❌ Cannot cancel an already CANCELLED emergency twice", async () => {
    const emergency = await prisma.emergencyRequest.create({
      data: {
        requesterId: requester.id,
        emergencyType: "Medical",
        description: "Medical assistance",
        location: "Thrissur",
        priority: "MEDIUM",
        status: "PENDING",
      },
    });

    const first = await request(app)
      .patch(`/api/requests/${emergency.id}/cancel`)
      .set("Authorization", `Bearer ${requesterToken}`);

    expect([200, 204]).toContain(first.statusCode);

    const second = await request(app)
      .patch(`/api/requests/${emergency.id}/cancel`)
      .set("Authorization", `Bearer ${requesterToken}`);

    expect(second.statusCode).toBe(500);
    expect(second.body.message).toContain(
      "Only PENDING requests can be cancelled"
    );
  });
});