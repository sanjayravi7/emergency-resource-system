// Load backend/.env first so a locally configured PostgreSQL test database is
// detected (same pattern as the socket integration suite).
require('dotenv').config();

const prisma = require('../../src/config/prisma');

const hasDatabase = Boolean(process.env.DATABASE_URL);

// PHASE B focused tests: the ResponderAssignment data model only.
//
// Assignment *behaviour* (transactional acceptance, partial-capability
// matching, availability, realtime) is implemented in later phases. This
// suite pins the schema contract those phases will rely on:
//   - one row per (requestId, responderId) pair, enforced by the database
//   - multiple responders per emergency and multiple emergencies per responder
//   - ACTIVE/ENDED state with acceptedAt/endedAt
//   - the exact unique constraint and composite indexes
//   - request deletion cascades assignments away
(hasDatabase ? describe : describe.skip)(
  'ResponderAssignment data model (Phase B)',
  () => {
    const runId = `assign-${Date.now()}`;

    let requester;
    let responder1;
    let responder2;
    let request1;
    let request2;

    beforeAll(async () => {
      requester = await prisma.user.create({
        data: {
          name: 'Assignment Requester',
          email: `${runId}-requester@test.com`,
          password: 'test-password',
          role: 'REQUESTER',
        },
      });

      responder1 = await prisma.user.create({
        data: {
          name: 'Assignment Responder 1',
          email: `${runId}-responder-1@test.com`,
          password: 'test-password',
          role: 'RESPONDER',
          responderStatus: 'AVAILABLE',
        },
      });

      responder2 = await prisma.user.create({
        data: {
          name: 'Assignment Responder 2',
          email: `${runId}-responder-2@test.com`,
          password: 'test-password',
          role: 'RESPONDER',
          responderStatus: 'AVAILABLE',
        },
      });

      request1 = await prisma.emergencyRequest.create({
        data: {
          requesterId: requester.id,
          emergencyType: 'Medical',
          location: 'Thrissur',
          priority: 'HIGH',
          status: 'PENDING',
        },
      });

      request2 = await prisma.emergencyRequest.create({
        data: {
          requesterId: requester.id,
          emergencyType: 'Fire',
          location: 'Kochi',
          priority: 'CRITICAL',
          status: 'ACCEPTED',
          acceptedById: responder2.id,
          acceptedAt: new Date(),
        },
      });
    });

    afterAll(async () => {
      // Assignments for these requests disappear through the ON DELETE
      // CASCADE when the requests are removed.
      await prisma.emergencyRequest.deleteMany({
        where: { requesterId: requester.id },
      });
      await prisma.user.deleteMany({
        where: {
          id: { in: [requester.id, responder1.id, responder2.id] },
        },
      });
      await prisma.$disconnect();
    });

    test('table exists with the expected columns, types and defaults', async () => {
      const columns = await prisma.$queryRaw`
        SELECT column_name::text AS column_name,
               is_nullable::text AS is_nullable,
               column_default::text AS column_default,
               data_type::text AS data_type
        FROM information_schema.columns
        WHERE table_name = 'ResponderAssignment'
        ORDER BY ordinal_position
      `;
      const names = columns.map((column) => column.column_name);
      expect(names).toEqual([
        'id',
        'requestId',
        'responderId',
        'status',
        'acceptedAt',
        'endedAt',
        'createdAt',
        'updatedAt',
      ]);

      const byName = Object.fromEntries(
        columns.map((column) => [column.column_name, column])
      );

      expect(byName.id.data_type).toBe('integer');
      expect(byName.requestId.is_nullable).toBe('NO');
      expect(byName.responderId.is_nullable).toBe('NO');
      expect(byName.status.data_type).toBe('USER-DEFINED');
      expect(byName.status.column_default).toContain('ACTIVE');
      expect(byName.acceptedAt.is_nullable).toBe('NO');
      expect(byName.acceptedAt.column_default).toMatch(
        /now\(\)|CURRENT_TIMESTAMP/i
      );
      expect(byName.endedAt.is_nullable).toBe('YES');
      expect(byName.endedAt.column_default).toBeNull();
      expect(byName.createdAt.column_default).toMatch(
        /now\(\)|CURRENT_TIMESTAMP/i
      );
      expect(byName.updatedAt.is_nullable).toBe('NO');
    });

    test('AssignmentStatus enum has exactly ACTIVE and ENDED', async () => {
      const values = await prisma.$queryRaw`
        SELECT unnest(enum_range(NULL::"AssignmentStatus"))::text AS value
        ORDER BY value
      `;
      expect(values.map((row) => row.value)).toEqual(['ACTIVE', 'ENDED']);
    });

    test('unique constraint rejects a duplicate (requestId, responderId) pair', async () => {
      await prisma.responderAssignment.create({
        data: { requestId: request1.id, responderId: responder1.id },
      });

      await expect(
        prisma.responderAssignment.create({
          data: { requestId: request1.id, responderId: responder1.id },
        })
      ).rejects.toMatchObject({ code: 'P2002' });
    });

    test('multiple responders can be assigned to the same emergency', async () => {
      const second = await prisma.responderAssignment.create({
        data: { requestId: request1.id, responderId: responder2.id },
      });

      expect(second.status).toBe('ACTIVE');
      expect(second.endedAt).toBeNull();
      expect(second.acceptedAt).not.toBeNull();

      const count = await prisma.responderAssignment.count({
        where: { requestId: request1.id },
      });
      expect(count).toBe(2);
    });

    test('one responder can hold assignments across multiple emergencies', async () => {
      const cross = await prisma.responderAssignment.create({
        data: { requestId: request2.id, responderId: responder1.id },
      });

      expect(cross.requestId).toBe(request2.id);
      expect(cross.responderId).toBe(responder1.id);

      const forResponder = await prisma.responderAssignment.findMany({
        where: { responderId: responder1.id },
      });
      expect(forResponder.map((row) => row.requestId).sort()).toEqual(
        [request1.id, request2.id].sort()
      );
    });

    test('an assignment can transition to ENDED with endedAt set', async () => {
      const ended = await prisma.responderAssignment.update({
        where: {
          requestId_responderId: {
            requestId: request2.id,
            responderId: responder1.id,
          },
        },
        data: { status: 'ENDED', endedAt: new Date() },
      });

      expect(ended.status).toBe('ENDED');
      expect(ended.endedAt).not.toBeNull();

      const activeOnly = await prisma.responderAssignment.count({
        where: {
          requestId: request2.id,
          status: 'ACTIVE',
        },
      });
      expect(activeOnly).toBe(0);
    });

    test('expected unique constraint and composite indexes exist', async () => {
      const indexes = await prisma.$queryRaw`
        SELECT indexname::text AS indexname, indexdef::text AS indexdef
        FROM pg_indexes
        WHERE tablename = 'ResponderAssignment'
      `;
      const byName = Object.fromEntries(
        indexes.map((index) => [index.indexname, index.indexdef])
      );

      expect(Object.keys(byName)).toEqual(
        expect.arrayContaining([
          'ResponderAssignment_pkey',
          'ResponderAssignment_requestId_responderId_key',
          'ResponderAssignment_requestId_status_idx',
          'ResponderAssignment_responderId_status_idx',
        ])
      );

      // PostgreSQL only quotes mixed-case identifiers, so normalize quoting
      // before asserting the indexed column list.
      const normalize = (definition) =>
        definition.replace(/"/g, '').replace(/\s+/g, ' ');

      expect(
        normalize(byName.ResponderAssignment_requestId_responderId_key)
      ).toContain('UNIQUE');
      expect(
        normalize(byName.ResponderAssignment_requestId_status_idx)
      ).toContain('(requestId, status)');
      expect(
        normalize(byName.ResponderAssignment_responderId_status_idx)
      ).toContain('(responderId, status)');
    });

    test('foreign keys reference EmergencyRequest (cascade) and User (restrict)', async () => {
      const constraints = await prisma.$queryRaw`
        SELECT conname::text AS conname,
               confdeltype::text AS confdeltype,
               confupdtype::text AS confupdtype
        FROM pg_constraint
        WHERE contype = 'f'
          AND conrelid IN (
            SELECT c.oid
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE c.relname = 'ResponderAssignment' AND n.nspname = 'public'
          )
      `;
      const byName = Object.fromEntries(
        constraints.map((row) => [row.conname, row])
      );

      expect(byName.ResponderAssignment_requestId_fkey.confdeltype).toBe('c');
      expect(byName.ResponderAssignment_responderId_fkey.confdeltype).toBe('r');
      expect(byName.ResponderAssignment_requestId_fkey.confupdtype).toBe('c');
      expect(byName.ResponderAssignment_responderId_fkey.confupdtype).toBe('c');
    });

    test('deleting an emergency cascades its assignments away', async () => {
      const doomed = await prisma.emergencyRequest.create({
        data: {
          requesterId: requester.id,
          emergencyType: 'Flood',
          location: 'Aluva',
          priority: 'MEDIUM',
          status: 'PENDING',
        },
      });

      await prisma.responderAssignment.create({
        data: { requestId: doomed.id, responderId: responder1.id },
      });
      await prisma.responderAssignment.create({
        data: { requestId: doomed.id, responderId: responder2.id },
      });

      await prisma.emergencyRequest.delete({ where: { id: doomed.id } });

      const remaining = await prisma.responderAssignment.findMany({
        where: { requestId: doomed.id },
      });
      expect(remaining).toHaveLength(0);
    });

    test('existing acceptedById lead-responder field is untouched by assignments', async () => {
      // acceptedById keeps meaning "first/lead responder" (backward
      // compatibility): even the lead responder's own membership row must
      // never rewrite or clear it.
      const before = await prisma.emergencyRequest.findUnique({
        where: { id: request2.id },
        select: { acceptedById: true, acceptedAt: true },
      });
      expect(before.acceptedById).toBe(responder2.id);

      await prisma.responderAssignment.create({
        data: { requestId: request2.id, responderId: responder2.id },
      });

      const after = await prisma.emergencyRequest.findUnique({
        where: { id: request2.id },
        select: { acceptedById: true, acceptedAt: true },
      });

      expect(after.acceptedById).toBe(before.acceptedById);
      expect(after.acceptedAt?.toISOString()).toBe(
        before.acceptedAt?.toISOString()
      );
    });
  }
);
