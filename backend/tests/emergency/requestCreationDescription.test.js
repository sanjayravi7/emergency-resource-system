const request = require("supertest");
const jwt = require("jsonwebtoken");

const app = require("../../src/app");
const prisma = require("../../src/config/prisma");
const env = require("../../src/config/env");

describe("Emergency request creation description handling", () => {
  let requester;
  let requesterToken;
  let resource;

  const testEmail = "description-optional-requester@test.com";
  const resourceName = "Description Optional Test Resource";

  beforeAll(async () => {
    await prisma.requestResource.deleteMany({
      where: { resource: { name: resourceName } },
    });
    await prisma.emergencyRequest.deleteMany({
      where: { requester: { email: testEmail } },
    });
    await prisma.resource.deleteMany({ where: { name: resourceName } });
    await prisma.user.deleteMany({ where: { email: testEmail } });

    requester = await prisma.user.create({
      data: {
        name: "Description Optional Requester",
        email: testEmail,
        password: "test-password",
        role: "REQUESTER",
        isActive: true,
      },
    });

    requesterToken = jwt.sign(
      { userId: requester.id, role: "REQUESTER" },
      env.JWT_SECRET,
      { expiresIn: "1h" }
    );

    resource = await prisma.resource.create({
      data: {
        name: resourceName,
        type: "MEDICAL",
        totalQuantity: 10,
        availableQuantity: 10,
        unit: "kit",
        isActive: true,
      },
    });
  });

  afterEach(async () => {
    await prisma.emergencyRequest.deleteMany({
      where: { requesterId: requester.id },
    });
  });

  afterAll(async () => {
    await prisma.requestResource.deleteMany({
      where: { resourceId: resource.id },
    });
    await prisma.emergencyRequest.deleteMany({
      where: { requesterId: requester.id },
    });
    await prisma.resource.deleteMany({ where: { id: resource.id } });
    await prisma.user.delete({ where: { id: requester.id } });
    await prisma.$disconnect();
  });

  function validPayload(overrides = {}) {
    return {
      emergencyType: "Medical",
      location: "Kolenchery Government Hospital",
      priority: "HIGH",
      latitude: 9.9911,
      longitude: 76.6622,
      requiredResources: [{ resourceId: resource.id, quantity: 1 }],
      ...overrides,
    };
  }

  async function postPayload(payload) {
    return request(app)
      .post("/api/requests")
      .set("Authorization", `Bearer ${requesterToken}`)
      .send(payload);
  }

  test("✅ backend accepts a missing description and stores it as null", async () => {
    const res = await postPayload(validPayload());

    expect(res.statusCode).toBe(201);
    expect(res.body.request.description).toBeNull();

    const stored = await prisma.emergencyRequest.findUnique({
      where: { id: res.body.request.id },
    });
    expect(stored.description).toBeNull();
  });

  test("✅ backend accepts a null description", async () => {
    const res = await postPayload(validPayload({ description: null }));

    expect(res.statusCode).toBe(201);
    expect(res.body.request.description).toBeNull();
  });

  test("✅ whitespace-only description is accepted as empty/null", async () => {
    const res = await postPayload(validPayload({ description: "   \n\t  " }));

    expect(res.statusCode).toBe(201);
    expect(res.body.request.description).toBeNull();
  });

  test("✅ non-empty description is preserved exactly", async () => {
    const description = "  Two people trapped near the east gate.  ";
    const res = await postPayload(validPayload({ description }));

    expect(res.statusCode).toBe(201);
    expect(res.body.request.description).toBe(description);

    const stored = await prisma.emergencyRequest.findUnique({
      where: { id: res.body.request.id },
    });
    expect(stored.description).toBe(description);
  });

  test("❌ existing validation for required fields remains unchanged", async () => {
    await expect(
      postPayload(validPayload({ emergencyType: "   " }))
    ).resolves.toMatchObject({
      statusCode: 400,
      body: { message: expect.stringMatching(/Emergency type/i) },
    });

    await expect(
      postPayload(validPayload({ priority: "URGENT" }))
    ).resolves.toMatchObject({
      statusCode: 400,
      body: { message: expect.stringMatching(/priority/i) },
    });

    await expect(
      postPayload(validPayload({ location: "  " }))
    ).resolves.toMatchObject({
      statusCode: 400,
      body: { message: expect.stringMatching(/Location/i) },
    });

    await expect(
      postPayload(validPayload({ longitude: undefined }))
    ).resolves.toMatchObject({
      statusCode: 400,
      body: { message: expect.stringMatching(/Latitude and longitude/i) },
    });

    await expect(
      postPayload(validPayload({ requiredResources: [] }))
    ).resolves.toMatchObject({
      statusCode: 400,
      body: {
        message: expect.stringMatching(/At least one required resource/i),
      },
    });
  });
});
