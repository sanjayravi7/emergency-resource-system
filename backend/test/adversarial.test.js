const request = require('supertest');
const app = require('../src/app');
const prisma = require('../src/config/prisma');
const jwt = require('jsonwebtoken');
const { JWT_SECRET } = require('../src/config/env');
const bcrypt = require('bcrypt');

let server;
let reqUserToken, resp1Token, resp2Token, inactiveToken;
let reqUser, resp1, resp2, inactiveUser;
let reqResource1, reqResource2;
let emergencyReq;

const setupUsersAndTokens = async () => {
    // Clean DB
    await prisma.allocation.deleteMany({});
    await prisma.requestResource.deleteMany({});
    await prisma.emergencyRequest.deleteMany({});
    await prisma.responderResource.deleteMany({});
    await prisma.resource.deleteMany({});
    await prisma.user.deleteMany({});

    const pwd = await bcrypt.hash('pass', 1);

    reqUser = await prisma.user.create({
        data: { name: 'Requester', email: 'req@m.co', password: pwd, role: 'REQUESTER' }
    });
    reqUserToken = jwt.sign({ userId: reqUser.id, role: reqUser.role }, JWT_SECRET, { expiresIn: '1h' });

    resp1 = await prisma.user.create({
        data: { name: 'Responder1', email: 'resp1@m.co', password: pwd, role: 'RESPONDER', responderStatus: 'AVAILABLE' }
    });
    resp1Token = jwt.sign({ userId: resp1.id, role: resp1.role }, JWT_SECRET, { expiresIn: '1h' });

    resp2 = await prisma.user.create({
        data: { name: 'Responder2', email: 'resp2@m.co', password: pwd, role: 'RESPONDER', responderStatus: 'OFFLINE' }
    });
    resp2Token = jwt.sign({ userId: resp2.id, role: resp2.role }, JWT_SECRET, { expiresIn: '1h' });

    inactiveUser = await prisma.user.create({
        data: { name: 'Inactive', email: 'inactive@m.co', password: pwd, role: 'REQUESTER', isActive: false }
    });
    inactiveToken = jwt.sign({ userId: inactiveUser.id, role: inactiveUser.role }, JWT_SECRET, { expiresIn: '1h' });

    // Create Catalog Resources
    const resA = await prisma.resource.create({ data: { name: 'Ambulance', type: 'Vehicle' } });
    const resB = await prisma.resource.create({ data: { name: 'Oxygen', type: 'Eq' } });

    // Create Responder Inventory
    reqResource1 = await prisma.responderResource.create({ data: { responderId: resp1.id, resourceId: resA.id, totalQuantity: 5, availableQuantity: 3 } });
    reqResource2 = await prisma.responderResource.create({ data: { responderId: resp2.id, resourceId: resB.id, totalQuantity: 10, availableQuantity: 10 } });

    // Create single emergency request
    emergencyReq = await prisma.emergencyRequest.create({
        data: { requesterId: reqUser.id, emergencyType: 'Flood', description: 'Help', location: 'City' }
    });
};

beforeAll(async () => {
    server = app.listen(0);
    await setupUsersAndTokens();
});

afterAll(async () => {
    await new Promise(r => server.close(r));
    await prisma.$disconnect();
});

describe('Adversarial Backend Test', () => {

    test('1. requester attempts allocation', async () => {
        const res = await request(app).post('/api/allocations')
            .set('Authorization', `Bearer ${reqUserToken}`)
            .send({ requestId: emergencyReq.id, responderResourceId: reqResource1.id, resourceId: reqResource1.resourceId, quantity: 1 });
        expect(res.status).toBe(403);
        expect(res.body.message).toMatch(/Access denied/);
    });

    test('2. responder modifies another responders inventory', async () => {
        const res = await request(app).patch(`/api/responder-resources/${reqResource2.id}`) // belogs to resp2
            .set('Authorization', `Bearer ${resp1Token}`)
            .send({ availableQuantity: 5 });
        expect(res.status).toBe(500);
        // Our simple errorHandler returns 500 with err.message
        expect(res.body.message).toMatch(/You can only manage your own resources/);
    });

    test('3. offline responder accepts request', async () => {
        const res = await request(app).patch(`/api/requests/${emergencyReq.id}/accept`)
            .set('Authorization', `Bearer ${resp2Token}`);
        expect(res.status).toBe(400); // the auth check in controller gives 400 manually, or service gives 500
        expect(res.body.message).toMatch(/Responder is not available/);
    });

    test('4. insufficient resources', async () => {
        const res = await request(app).post('/api/allocations')
            .set('Authorization', `Bearer ${resp1Token}`)
            .send({ requestId: emergencyReq.id, responderResourceId: reqResource1.id, resourceId: reqResource1.resourceId, quantity: 10 }); // available is 3
        expect(res.status).toBe(500);
        expect(res.body.message).toMatch(/Not enough available quantity/);
    });

    test('5. duplicate cancellation', async () => {
        // Create a new request to cancel
        const tempReq = await prisma.emergencyRequest.create({
            data: { requesterId: reqUser.id, emergencyType: 'Fire', description: 'Help', location: 'City' }
        });

        let res = await request(app).patch(`/api/requests/${tempReq.id}/cancel`).set('Authorization', `Bearer ${reqUserToken}`);
        expect(res.status).toBe(200);

        // Duplicate
        res = await request(app).patch(`/api/requests/${tempReq.id}/cancel`).set('Authorization', `Bearer ${reqUserToken}`);
        expect(res.body.message).toMatch(/Only PENDING requests can be cancelled/);
    });

    test('6. allocation for unrelated resource', async () => {
        const res = await request(app).post('/api/allocations')
            .set('Authorization', `Bearer ${resp1Token}`)
            .send({ requestId: emergencyReq.id, responderResourceId: reqResource1.id, resourceId: 9999, quantity: 1 });
        expect(res.body.message).toMatch(/Resource mismatch/);
    });

    test('7. allocation for another responders ResponderResource', async () => {
        const res = await request(app).post('/api/allocations')
            .set('Authorization', `Bearer ${resp1Token}`)
            .send({ requestId: emergencyReq.id, responderResourceId: reqResource2.id, resourceId: reqResource2.resourceId, quantity: 1 });
        expect(res.body.message).toMatch(/Responder mismatch: unauthorized/);
    });

    test('8 & 9. allocation for completed or cancelled request', async () => {
        const tempReq = await prisma.emergencyRequest.create({
            data: { requesterId: reqUser.id, emergencyType: 'Fire', description: 'Help', location: 'City', status: 'CANCELLED' }
        });
        const res = await request(app).post('/api/allocations')
            .set('Authorization', `Bearer ${resp1Token}`)
            .send({ requestId: tempReq.id, responderResourceId: reqResource1.id, resourceId: reqResource1.resourceId, quantity: 1 });
        expect(res.body.message).toMatch(/Request is invalid or already closed/);
    });

    test('10. invalid quantity', async () => {
        const res = await request(app).post('/api/allocations')
            .set('Authorization', `Bearer ${resp1Token}`)
            .send({ requestId: emergencyReq.id, responderResourceId: reqResource1.id, resourceId: reqResource1.resourceId, quantity: -2 });
        expect(res.body.message).toMatch(/Quantity must be greater than 0/);
    });

    test('11. inactive user calls protected API', async () => {
        const res = await request(app).get('/api/auth/me')
            .set('Authorization', `Bearer ${inactiveToken}`);
        expect(res.status).toBe(401);
        expect(res.body.message).toMatch(/User is inactive or does not exist/);
    });

    test('12. two concurrent allocations', async () => {
        // available is 3. We request 2 twice concurrently.
        const req1 = request(app).post('/api/allocations')
            .set('Authorization', `Bearer ${resp1Token}`)
            .send({ requestId: emergencyReq.id, responderResourceId: reqResource1.id, resourceId: reqResource1.resourceId, quantity: 2 });

        const req2 = request(app).post('/api/allocations')
            .set('Authorization', `Bearer ${resp1Token}`)
            .send({ requestId: emergencyReq.id, responderResourceId: reqResource1.id, resourceId: reqResource1.resourceId, quantity: 2 });

        const [res1, res2] = await Promise.all([req1, req2]);

        // One must fail
        const successes = [res1, res2].filter(r => r.status === 201).length;
        const failures = [res1, res2].filter(r => r.body.message && r.body.message.includes('Not enough available quantity')).length;

        expect(successes).toBe(1);
        expect(failures).toBe(1);
    });
});
