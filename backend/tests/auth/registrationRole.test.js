/**
 * Public registration role selection.
 *
 * ERAS registration asks "How would you like to use ERAS?" and stores the
 * selected role (REQUESTER | RESPONDER) on the User record in PostgreSQL.
 *
 * Security contract verified here:
 *  - public registration CAN create REQUESTER and RESPONDER accounts,
 *  - public registration can NEVER create an ADMIN account,
 *  - empty / unknown role values are rejected before any user is written,
 *  - login and /me always return the CURRENT database role,
 *  - the ADMIN-protected role-management API can change a role, and the
 *    user's NEXT login reflects the new database role (registration choice
 *    is only the initial role, never a permanent lock),
 *  - a duplicate email never creates a second account.
 */

const request = require("supertest");
const bcrypt = require("bcrypt");

const app = require("../../src/app");
const prisma = require("../../src/config/prisma");

describe("Registration role selection", () => {
  const stamp = `${Date.now()}_${Math.floor(Math.random() * 10000)}`;
  const password = "Test123456";

  const adminEmail = `admin_${stamp}@eras.test`;
  const requesterEmail = `requester_${stamp}@eras.test`;
  const responderEmail = `responder_${stamp}@eras.test`;
  const adminAttackEmail = `admin_attack_${stamp}@eras.test`;
  const invalidRoleEmail = `invalid_${stamp}@eras.test`;
  const duplicateEmail = `duplicate_${stamp}@eras.test`;

  let adminId;
  let requesterId;
  let responderId;
  let adminToken;

  beforeAll(async () => {
    const hashedPassword = await bcrypt.hash(password, 10);

    // The ADMIN account is provisioned directly in the database, exactly like
    // the existing seed workflow - never through public registration.
    const admin = await prisma.user.create({
      data: {
        name: "Role Test Admin",
        email: adminEmail,
        password: hashedPassword,
        role: "ADMIN",
      },
    });
    adminId = admin.id;

    const loginResponse = await request(app)
      .post("/api/auth/login")
      .send({ email: adminEmail, password });

    adminToken = loginResponse.body.data.token;
  });

  afterAll(async () => {
    const emails = [
      adminEmail,
      requesterEmail,
      responderEmail,
      adminAttackEmail,
      invalidRoleEmail,
      duplicateEmail,
    ];

    await prisma.user.deleteMany({
      where: { email: { in: emails } },
    });

    await prisma.$disconnect();
  });

  test("public registration with REQUESTER succeeds and stores role=REQUESTER", async () => {
    const response = await request(app)
      .post("/api/auth/register")
      .send({
        name: "Public Requester",
        email: requesterEmail,
        password,
        phone: "9876543210",
        role: "REQUESTER",
      });

    expect(response.statusCode).toBe(201);
    expect(response.body.success).toBe(true);
    expect(response.body.data.user.role).toBe("REQUESTER");
    expect(response.body.data.token).toBeDefined();

    const dbUser = await prisma.user.findUnique({
      where: { email: requesterEmail },
      select: { role: true, responderStatus: true },
    });

    expect(dbUser.role).toBe("REQUESTER");
    requesterId = response.body.data.user.id;
  });

  test("public registration with RESPONDER succeeds and stores role=RESPONDER without fabricating readiness", async () => {
    const response = await request(app)
      .post("/api/auth/register")
      .send({
        name: "Public Responder",
        email: responderEmail,
        password,
        phone: "9876543211",
        role: "RESPONDER",
      });

    expect(response.statusCode).toBe(201);
    expect(response.body.success).toBe(true);
    expect(response.body.data.user.role).toBe("RESPONDER");

    const dbUser = await prisma.user.findUnique({
      where: { email: responderEmail },
      select: { role: true, responderStatus: true },
    });

    // The responder is created through the existing architecture with its
    // honest initial state: OFFLINE, no invented capabilities or resources.
    expect(dbUser.role).toBe("RESPONDER");
    expect(dbUser.responderStatus).toBe("OFFLINE");

    const resources = await prisma.responderResource.findMany({
      where: { responderId: response.body.data.user.id },
    });
    expect(resources).toHaveLength(0);

    responderId = response.body.data.user.id;
  });

  test("public registration with role=ADMIN is rejected and creates no ADMIN account", async () => {
    const response = await request(app)
      .post("/api/auth/register")
      .send({
        name: "Admin Impersonator",
        email: adminAttackEmail,
        password,
        role: "ADMIN",
      });

    expect(response.statusCode).toBe(400);
    expect(response.body.success).toBe(false);

    const dbUser = await prisma.user.findUnique({
      where: { email: adminAttackEmail },
      select: { role: true },
    });

    expect(dbUser).toBeNull();

    const adminAccounts = await prisma.user.findMany({
      where: { email: adminAttackEmail, role: "ADMIN" },
    });
    expect(adminAccounts).toHaveLength(0);
  });

  test("public registration with an invalid role is rejected", async () => {
    const response = await request(app)
      .post("/api/auth/register")
      .send({
        name: "Invalid Role User",
        email: invalidRoleEmail,
        password,
        role: "something-else",
      });

    expect(response.statusCode).toBe(400);
    expect(response.body.success).toBe(false);

    const dbUser = await prisma.user.findUnique({
      where: { email: invalidRoleEmail },
    });
    expect(dbUser).toBeNull();
  });

  test("public registration without a role is rejected (role selection is required)", async () => {
    const response = await request(app)
      .post("/api/auth/register")
      .send({
        name: "No Role User",
        email: `no_role_${stamp}@eras.test`,
        password,
      });

    expect(response.statusCode).toBe(400);
    expect(response.body.success).toBe(false);

    const dbUser = await prisma.user.findUnique({
      where: { email: `no_role_${stamp}@eras.test` },
    });
    expect(dbUser).toBeNull();
  });

  test("public registration with an empty role value is rejected", async () => {
    const response = await request(app)
      .post("/api/auth/register")
      .send({
        name: "Empty Role User",
        email: `empty_role_${stamp}@eras.test`,
        password,
        role: "   ",
      });

    expect(response.statusCode).toBe(400);
    expect(response.body.success).toBe(false);
  });

  test("duplicate email never creates a second account", async () => {
    const first = await request(app)
      .post("/api/auth/register")
      .send({
        name: "First Account",
        email: duplicateEmail,
        password,
        role: "REQUESTER",
      });
    expect(first.statusCode).toBe(201);

    const second = await request(app)
      .post("/api/auth/register")
      .send({
        name: "Second Account",
        email: duplicateEmail,
        password,
        role: "RESPONDER",
      });

    expect(second.statusCode).toBe(409);
    expect(second.body.success).toBe(false);

    const users = await prisma.user.findMany({
      where: { email: duplicateEmail },
      select: { role: true },
    });
    expect(users).toHaveLength(1);
    expect(users[0].role).toBe("REQUESTER");
  });

  test("login returns the user's actual database role", async () => {
    const responderLogin = await request(app)
      .post("/api/auth/login")
      .send({ email: responderEmail, password });

    expect(responderLogin.statusCode).toBe(200);
    expect(responderLogin.body.data.user.role).toBe("RESPONDER");

    const requesterLogin = await request(app)
      .post("/api/auth/login")
      .send({ email: requesterEmail, password });

    expect(requesterLogin.statusCode).toBe(200);
    expect(requesterLogin.body.data.user.role).toBe("REQUESTER");

    const adminLogin = await request(app)
      .post("/api/auth/login")
      .send({ email: adminEmail, password });

    expect(adminLogin.statusCode).toBe(200);
    expect(adminLogin.body.data.user.role).toBe("ADMIN");
  });

  test("GET /api/auth/me returns the current database role", async () => {
    const login = await request(app)
      .post("/api/auth/login")
      .send({ email: responderEmail, password });

    const response = await request(app)
      .get("/api/auth/me")
      .set("Authorization", `Bearer ${login.body.data.token}`);

    expect(response.statusCode).toBe(200);
    expect(response.body.data.user.role).toBe("RESPONDER");
  });

  test("non-admin users cannot change roles through the role-management API", async () => {
    const login = await request(app)
      .post("/api/auth/login")
      .send({ email: requesterEmail, password });

    const response = await request(app)
      .patch(`/api/users/${responderId}/role`)
      .set("Authorization", `Bearer ${login.body.data.token}`)
      .send({ role: "ADMIN" });

    expect(response.statusCode).toBe(403);

    const dbUser = await prisma.user.findUnique({
      where: { id: responderId },
      select: { role: true },
    });
    expect(dbUser.role).toBe("RESPONDER");
  });

  test("ADMIN changes REQUESTER -> RESPONDER and the next login uses the new database role", async () => {
    const changeResponse = await request(app)
      .patch(`/api/users/${requesterId}/role`)
      .set("Authorization", `Bearer ${adminToken}`)
      .send({ role: "RESPONDER" });

    expect(changeResponse.statusCode).toBe(200);
    expect(changeResponse.body.user.role).toBe("RESPONDER");

    const dbUser = await prisma.user.findUnique({
      where: { id: requesterId },
      select: { role: true },
    });
    expect(dbUser.role).toBe("RESPONDER");

    const login = await request(app)
      .post("/api/auth/login")
      .send({ email: requesterEmail, password });

    expect(login.statusCode).toBe(200);
    expect(login.body.data.user.role).toBe("RESPONDER");
  });

  test("ADMIN reverses RESPONDER -> REQUESTER and the next login uses the new database role", async () => {
    const changeResponse = await request(app)
      .patch(`/api/users/${requesterId}/role`)
      .set("Authorization", `Bearer ${adminToken}`)
      .send({ role: "REQUESTER" });

    expect(changeResponse.statusCode).toBe(200);
    expect(changeResponse.body.user.role).toBe("REQUESTER");

    const login = await request(app)
      .post("/api/auth/login")
      .send({ email: requesterEmail, password });

    expect(login.statusCode).toBe(200);
    expect(login.body.data.user.role).toBe("REQUESTER");
  });
});
