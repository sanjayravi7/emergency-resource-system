const request = require("supertest");
const jwt = require("jsonwebtoken");

const app = require("../../src/app");
const prisma = require("../../src/config/prisma");
const env = require("../../src/config/env");

describe("Authentication", () => {
  const email = `test_${Date.now()}@example.com`;
  const password = "Test123456";

  let userId;
  let token;

  beforeAll(async () => {
    const hashedPassword = await require("bcrypt").hash(
      password,
      10
    );

    const user = await prisma.user.create({
      data: {
        name: "Test User",
        email,
        password: hashedPassword,
        phone: "9876543210",
        location: "Thrissur",
        role: "REQUESTER",
      },
    });

    userId = user.id;
  });

  afterAll(async () => {
    await prisma.user.deleteMany({
      where: {
        id: userId,
      },
    });

    await prisma.$disconnect();
  });

  test("✅ Register", async () => {
    const registerEmail =
      `register_${Date.now()}@example.com`;

    const response = await request(app)
      .post("/api/auth/register")
      .send({
        name: "New User",
        email: registerEmail,
        password: "Test123456",
        phone: "9999999999",
        location: "Thrissur",
        role: "REQUESTER",
      });

    expect(response.statusCode).toBe(201);
    expect(response.body.success).toBe(true);
    expect(response.body.data.user.email)
      .toBe(registerEmail);
    expect(response.body.data.token).toBeDefined();

    await prisma.user.delete({
      where: {
        email: registerEmail,
      },
    });
  });

  test("✅ Login", async () => {
    const response = await request(app)
      .post("/api/auth/login")
      .send({
        email,
        password,
      });

    expect(response.statusCode).toBe(200);
    expect(response.body.success).toBe(true);
    expect(response.body.data.token).toBeDefined();

    token = response.body.data.token;
  });

  test("✅ Invalid password", async () => {
    const response = await request(app)
      .post("/api/auth/login")
      .send({
        email,
        password: "WrongPassword123",
      });

    expect(response.statusCode).toBe(401);
    expect(response.body.success).toBe(false);
  });

  test("✅ Invalid JWT", async () => {
    const response = await request(app)
      .get("/api/auth/me")
      .set(
        "Authorization",
        "Bearer invalid-token"
      );

    expect(response.statusCode).toBe(401);
  });

  test("✅ Expired JWT", async () => {
    const expiredToken = jwt.sign(
      {
        userId,
        role: "REQUESTER",
      },
      env.JWT_SECRET,
      {
        expiresIn: -1,
      }
    );

    const response = await request(app)
      .get("/api/auth/me")
      .set(
        "Authorization",
        `Bearer ${expiredToken}`
      );

    expect(response.statusCode).toBe(401);
  });

  test("✅ Inactive user", async () => {
    await prisma.user.update({
      where: {
        id: userId,
      },
      data: {
        isActive: false,
      },
    });

    const response = await request(app)
      .post("/api/auth/login")
      .send({
        email,
        password,
      });

    expect(response.statusCode).toBe(403);
    expect(response.body.message)
      .toBe("Account is inactive");

    await prisma.user.update({
      where: {
        id: userId,
      },
      data: {
        isActive: true,
      },
    });
  });

  test("✅ Authenticated /me", async () => {
    const loginResponse = await request(app)
      .post("/api/auth/login")
      .send({
        email,
        password,
      });

    token = loginResponse.body.data.token;

    const response = await request(app)
      .get("/api/auth/me")
      .set(
        "Authorization",
        `Bearer ${token}`
      );

    expect(response.statusCode).toBe(200);
    expect(response.body.success).toBe(true);
    expect(response.body.data.user.id)
      .toBe(userId);
  });
});