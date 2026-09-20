const request = require("supertest");
const bcrypt = require("bcrypt");
const app = require("../../src/app");
const prisma = require("../../src/config/prisma");

describe("Authorization / RBAC", () => {
  let requesterToken;
  let responderToken;
  let adminToken;

  let requester;
  let responder;
  let admin;

  beforeAll(async () => {
    const passwordHash = await bcrypt.hash("Test@12345", 10);

    // Clean only these test emails
    await prisma.user.deleteMany({
      where: {
        email: {
          in: [
            "authz-requester@test.com",
            "authz-responder@test.com",
            "authz-admin@test.com",
          ],
        },
      },
    });

    requester = await prisma.user.create({
      data: {
        name: "Authz Requester",
        email: "authz-requester@test.com",
        password: passwordHash,
        role: "REQUESTER",
        isActive: true,
      },
    });

    responder = await prisma.user.create({
      data: {
        name: "Authz Responder",
        email: "authz-responder@test.com",
        password: passwordHash,
        role: "RESPONDER",
        responderStatus: "AVAILABLE",
        isActive: true,
      },
    });

    admin = await prisma.user.create({
      data: {
        name: "Authz Admin",
        email: "authz-admin@test.com",
        password: passwordHash,
        role: "ADMIN",
        isActive: true,
      },
    });
// Login each user
let res = await request(app)
  .post("/api/auth/login")
  .send({
    email: requester.email,
    password: "Test@12345",
  });



expect(res.statusCode).toBe(200);
requesterToken = res.body.data.token;

res = await request(app)
  .post("/api/auth/login")
  .send({
    email: responder.email,
    password: "Test@12345",
  });

expect(res.statusCode).toBe(200);
responderToken = res.body.data.token;

res = await request(app)
  .post("/api/auth/login")
  .send({
    email: admin.email,
    password: "Test@12345",
  });

expect(res.statusCode).toBe(200);
adminToken = res.body.data.token;

}); // ✅ CLOSE beforeAll()


afterAll(async () => {
  await prisma.user.deleteMany({
    where: {
      email: {
        in: [
          "authz-requester@test.com",
          "authz-responder@test.com",
          "authz-admin@test.com",
        ],
      },
    },
  });

  await prisma.$disconnect();
});

  // =====================================================
  // RESOURCE CATALOG
  // =====================================================

  test("❌ REQUESTER cannot create resource", async () => {
    const res = await request(app)
      .post("/api/resources")
      .set("Authorization", `Bearer ${requesterToken}`)
      .send({
        name: "Test Ambulance",
        type: "Vehicle",
        unit: "vehicle",
      });

    expect(res.statusCode).toBe(403);
  });

  test("❌ RESPONDER cannot create resource", async () => {
    const res = await request(app)
      .post("/api/resources")
      .set("Authorization", `Bearer ${responderToken}`)
      .send({
        name: "Test Fire Truck",
        type: "Vehicle",
        unit: "vehicle",
      });

    expect(res.statusCode).toBe(403);
  });

  test("✅ ADMIN can create resource", async () => {
    const resourceName = `Authz Resource ${Date.now()}`;

    const res = await request(app)
      .post("/api/resources")
      .set("Authorization", `Bearer ${adminToken}`)
      .send({
        name: resourceName,
        type: "Vehicle",
        unit: "vehicle",
      });

    expect([200, 201]).toContain(res.statusCode);

    // Clean the resource created by this test
    await prisma.resource.delete({
      where: {
        name: resourceName,
      },
    });
  });

  // =====================================================
  // USER ROLE MANAGEMENT
  // =====================================================

  test("❌ REQUESTER cannot change user role", async () => {
    const res = await request(app)
      .patch(`/api/users/${responder.id}/role`)
      .set("Authorization", `Bearer ${requesterToken}`)
      .send({
        role: "ADMIN",
      });

    expect(res.statusCode).toBe(403);
  });

  test("❌ RESPONDER cannot change user role", async () => {
    const res = await request(app)
      .patch(`/api/users/${requester.id}/role`)
      .set("Authorization", `Bearer ${responderToken}`)
      .send({
        role: "ADMIN",
      });

    expect(res.statusCode).toBe(403);
  });

 test("✅ ADMIN can change user role", async () => {
  const res = await request(app)
    .patch(`/api/users/${requester.id}/role`)
    .set("Authorization", `Bearer ${adminToken}`)
    .send({
      role: "RESPONDER",
    });

  expect([200, 204]).toContain(res.statusCode);

  // Restore requester role for the remaining tests
  await prisma.user.update({
    where: {
      id: requester.id,
    },
    data: {
      role: "REQUESTER",
    },
  });
});
 

   
  // =====================================================
  // RESPONDER STATUS
  // =====================================================

  test("❌ REQUESTER cannot update responder status", async () => {
    const res = await request(app)
      .patch("/api/responders/status")
      .set("Authorization", `Bearer ${requesterToken}`)
      .send({
        status: "AVAILABLE",
      });

    expect(res.statusCode).toBe(403);
  });

  test("✅ RESPONDER can update own responder status", async () => {
    const res = await request(app)
      .patch("/api/responders/status")
      .set("Authorization", `Bearer ${responderToken}`)
      .send({
        status: "BUSY",
      });

    expect([200, 204]).toContain(res.statusCode);
  });

  // =====================================================
  // RESPONDER LOCATION
  // =====================================================

  test("❌ REQUESTER cannot update responder location endpoint", async () => {
    const res = await request(app)
      .patch("/api/responders/location")
      .set("Authorization", `Bearer ${requesterToken}`)
      .send({
        location: "Thrissur",
        latitude: 10.5276,
        longitude: 76.2144,
      });

    expect(res.statusCode).toBe(403);
  });

  test("✅ RESPONDER can update own location", async () => {
    const res = await request(app)
      .patch("/api/responders/location")
      .set("Authorization", `Bearer ${responderToken}`)
      .send({
        location: "Thrissur",
        latitude: 10.5276,
        longitude: 76.2144,
      });

    expect([200, 204]).toContain(res.statusCode);
  });
});