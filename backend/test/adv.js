const request = require('supertest');
const app = require('../src/app');
const prisma = require('../src/config/prisma');
const jwt = require('jsonwebtoken');
const { JWT_SECRET } = require('../src/config/env');
const bcrypt = require('bcrypt');

async function runTests() {
    let server = app.listen(0);
    console.log('Server started.');

    // Clean DB
    await prisma.allocation.deleteMany({});
    await prisma.requestResource.deleteMany({});
    await prisma.emergencyRequest.deleteMany({});
    await prisma.responderResource.deleteMany({});
    await prisma.resource.deleteMany({});
    await prisma.user.deleteMany({});

    const pwd = await bcrypt.hash('pass', 1);

    const reqUser = await prisma.user.create({
        data: { name: 'Requester', email: 'req@m.co', password: pwd, role: 'REQUESTER' }
    });
    const reqUserToken = jwt.sign({ userId: reqUser.id, role: reqUser.role }, JWT_SECRET, { expiresIn: '1h' });

    const resp1 = await prisma.user.create({
        data: { name: 'Responder1', email: 'resp1@m.co', password: pwd, role: 'RESPONDER', responderStatus: 'AVAILABLE' }
    });
    const resp1Token = jwt.sign({ userId: resp1.id, role: resp1.role }, JWT_SECRET, { expiresIn: '1h' });

    const resp2 = await prisma.user.create({
        data: { name: 'Responder2', email: 'resp2@m.co', password: pwd, role: 'RESPONDER', responderStatus: 'OFFLINE' }
    });
    const resp2Token = jwt.sign({ userId: resp2.id, role: resp2.role }, JWT_SECRET, { expiresIn: '1h' });

    const inactiveUser = await prisma.user.create({
        data: { name: 'Inactive', email: 'inactive@m.co', password: pwd, role: 'REQUESTER', isActive: false }
    });
    const inactiveToken = jwt.sign({ userId: inactiveUser.id, role: inactiveUser.role }, JWT_SECRET, { expiresIn: '1h' });

    const resA = await prisma.resource.create({
    data: { name: 'Ambulance', type: 'Vehicle' }
});

const resB = await prisma.resource.create({
    data: { name: 'Oxygen', type: 'Eq' }
});

const reqResource1 = await prisma.responderResource.create({
    data: {
        responderId: resp1.id,
        resourceId: resA.id,
        totalQuantity: 5,
        availableQuantity: 3
    }
});

const reqResource2 = await prisma.responderResource.create({
    data: {
        responderId: resp2.id,
        resourceId: resB.id,
        totalQuantity: 10,
        availableQuantity: 10
    }
});

const emergencyReq = await prisma.emergencyRequest.create({
    data: {
        requesterId: reqUser.id,
        emergencyType: 'Flood',
        description: 'Help',
        location: 'City',
        requiredResources: {
            create: {
                resourceId: resA.id,
                quantity: 4
            }
        }
    }
});
    let passed = 0;
    let failed = 0;

    const assertReject = async (name, promise, expectedStatus, expectedMsg) => {
        try {
            const res = await promise;
            if (res.status === expectedStatus && res.body && res.body.message && res.body.message.includes(expectedMsg)) {
                console.log('✅ ' + name);
                passed++;
            } else {
                console.log('❌ ' + name + ' | Expected ' + expectedStatus + ' ' + expectedMsg + ' but got ' + res.status + ' ' + JSON.stringify(res.body));
                failed++;
            }
        } catch (e) {
            console.log('❌ ' + name + ' | EXCEPTION: ' + e.message);
            failed++;
        }
    };

    await assertReject('1. requester attempts allocation',
        request(server).post('/api/allocations').set('Authorization', 'Bearer ' + reqUserToken).send({ requestId: emergencyReq.id, responderResourceId: reqResource1.id, resourceId: reqResource1.resourceId, quantity: 1 }),
        403, 'Access denied');

    await assertReject('2. responder modifies another responders inventory',
        request(server).patch('/api/responder-resources/' + reqResource2.id).set('Authorization', 'Bearer ' + resp1Token).send({ availableQuantity: 5 }),
        500, 'You can only manage your own resources');

    await assertReject('3. offline responder accepts request',
        request(server).patch('/api/requests/' + emergencyReq.id + '/accept').set('Authorization', 'Bearer ' + resp2Token),
        400, 'Responder is not available');

    await assertReject('4. insufficient resources',
        request(server).post('/api/allocations').set('Authorization', 'Bearer ' + resp1Token).send({ requestId: emergencyReq.id, responderResourceId: reqResource1.id, resourceId: reqResource1.resourceId, quantity: 10 }),
        500, 'Not enough available quantity');

    const tempReq = await prisma.emergencyRequest.create({ data: { requesterId: reqUser.id, emergencyType: 'Fire', description: 'Help', location: 'City' } });
    await request(server).patch('/api/requests/' + tempReq.id + '/cancel').set('Authorization', 'Bearer ' + reqUserToken);
    await assertReject('5. duplicate cancellation',
        request(server).patch('/api/requests/' + tempReq.id + '/cancel').set('Authorization', 'Bearer ' + reqUserToken),
        500, 'Only PENDING requests can be cancelled');

    await assertReject('6. allocation for unrelated resource',
        request(server).post('/api/allocations').set('Authorization', 'Bearer ' + resp1Token).send({ requestId: emergencyReq.id, responderResourceId: reqResource1.id, resourceId: 9999, quantity: 1 }),
        500, 'Resource mismatch');

    await assertReject('7. allocation for another responder',
        request(server).post('/api/allocations').set('Authorization', 'Bearer ' + resp1Token).send({ requestId: emergencyReq.id, responderResourceId: reqResource2.id, resourceId: reqResource2.resourceId, quantity: 1 }),
        500, 'unauthorized');

    await assertReject('8. allocation for cancelled request',
        request(server).post('/api/allocations').set('Authorization', 'Bearer ' + resp1Token).send({ requestId: tempReq.id, responderResourceId: reqResource1.id, resourceId: reqResource1.resourceId, quantity: 1 }),
        500, 'Request is invalid or already closed');

    await assertReject('10. invalid quantity',
        request(server).post('/api/allocations').set('Authorization', 'Bearer ' + resp1Token).send({ requestId: emergencyReq.id, responderResourceId: reqResource1.id, resourceId: reqResource1.resourceId, quantity: -2 }),
        500, 'Quantity must be greater than 0');

    await assertReject('11. inactive user calls protected API',
        request(server).get('/api/auth/me').set('Authorization', 'Bearer ' + inactiveToken),
        401, 'User is inactive');

    // 12. concurrent allocation
    const p1 = request(server).post('/api/allocations').set('Authorization', 'Bearer ' + resp1Token).send({ requestId: emergencyReq.id, responderResourceId: reqResource1.id, resourceId: reqResource1.resourceId, quantity: 2 });
    const p2 = request(server).post('/api/allocations').set('Authorization', 'Bearer ' + resp1Token).send({ requestId: emergencyReq.id, responderResourceId: reqResource1.id, resourceId: reqResource1.resourceId, quantity: 2 });

    const [res1, res2] = await Promise.all([p1, p2]);
    const succ = [res1, res2].filter(r => r.status === 201).length;
    const fail = [res1, res2].filter(r => r.status === 500 && r.body && r.body.message && r.body.message.includes('Not enough available quantity')).length;

    if (succ === 1 && fail === 1) {
        console.log('✅ 12. two concurrent allocations');
        passed++;
    } else {
        console.log('❌ 12. two concurrent allocations failed: succ=' + succ + ' fail=' + fail);
        failed++;
    }

    server.close();
    await prisma.$disconnect();
    console.log(`\nResults: ${passed} passed, ${failed} failed`);
}

runTests();
