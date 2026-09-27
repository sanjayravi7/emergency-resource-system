/**
 * Phase I, Part 15 - lightweight, NON-DESTRUCTIVE performance smoke test.
 *
 * It measures latency of the read paths that dominate the operational UI plus
 * a self-contained Socket.IO room fan-out micro-benchmark. It performs NO
 * writes against the database and must NOT be pointed at production while under
 * live load.
 *
 * Usage:
 *   DATABASE_URL=... node scripts/perf-smoke.js
 *   PERF_ITERATIONS=200 PERF_FANOUT_CLIENTS=200 node scripts/perf-smoke.js
 *
 * Measured operations:
 *   1. compatible request discovery   (getCompatibleRequestsForResponder)
 *   2. assigned request discovery     (getAssignedRequestsForResponder)
 *   3. request snapshot generation    (requestService.getRequestById)
 *   4. multiple responder locations    (User rows with lat/long)
 *   5. Socket.IO assignment event fan-out (in-process, no DB)
 */

const http = require('http');
const prisma = require('../src/config/prisma');

const ITERATIONS = Number(process.env.PERF_ITERATIONS || 100);
const FANOUT_CLIENTS = Number(process.env.PERF_FANOUT_CLIENTS || 100);

function percentile(sorted, p) {
  if (!sorted.length) return 0;
  const idx = Math.min(sorted.length - 1, Math.floor((p / 100) * sorted.length));
  return sorted[idx];
}

async function timeIt(label, fn, iterations = ITERATIONS) {
  // Warm up once (connection pool, query plan cache) without recording it.
  try {
    await fn();
  } catch (error) {
    console.log(`  ${label}: skipped (${error.message})`);
    return;
  }

  const samples = [];
  for (let i = 0; i < iterations; i += 1) {
    const start = process.hrtime.bigint();
    // eslint-disable-next-line no-await-in-loop
    await fn();
    const end = process.hrtime.bigint();
    samples.push(Number(end - start) / 1e6);
  }
  samples.sort((a, b) => a - b);
  const avg = samples.reduce((s, v) => s + v, 0) / samples.length;
  console.log(
    `  ${label.padEnd(34)} n=${iterations}  ` +
      `avg=${avg.toFixed(2)}ms  p50=${percentile(samples, 50).toFixed(2)}ms  ` +
      `p95=${percentile(samples, 95).toFixed(2)}ms  max=${samples[samples.length - 1].toFixed(2)}ms`
  );
}

async function pickSampleIds() {
  const responder = await prisma.user.findFirst({ where: { role: 'RESPONDER' }, select: { id: true } });
  const request = await prisma.emergencyRequest.findFirst({ orderBy: { id: 'desc' }, select: { id: true } });
  return { responderId: responder?.id, requestId: request?.id };
}

async function dbBenchmarks() {
  console.log('\nDatabase read paths');
  let requestService;
  try {
    requestService = require('../src/services/requestService');
  } catch (error) {
    console.log(`  requestService unavailable: ${error.message}`);
    return;
  }

  const { responderId, requestId } = await pickSampleIds();

  if (responderId && typeof requestService.getCompatibleRequestsForResponder === 'function') {
    await timeIt('compatible request discovery', () =>
      requestService.getCompatibleRequestsForResponder(responderId)
    );
  } else {
    console.log('  compatible request discovery: skipped (no responder in DB)');
  }

  if (responderId && typeof requestService.getAssignedRequestsForResponder === 'function') {
    await timeIt('assigned request discovery', () =>
      requestService.getAssignedRequestsForResponder(responderId)
    );
  } else {
    console.log('  assigned request discovery: skipped (no responder in DB)');
  }

  if (requestId && typeof requestService.getRequestById === 'function') {
    await timeIt('request snapshot generation', () =>
      requestService.getRequestById(requestId)
    );
  } else {
    console.log('  request snapshot generation: skipped (no request in DB)');
  }

  await timeIt('multiple responder locations', () =>
    prisma.user.findMany({
      where: { role: 'RESPONDER', latitude: { not: null } },
      select: { id: true, latitude: true, longitude: true, responderStatus: true },
    })
  );
}

async function fanoutBenchmark() {
  console.log('\nSocket.IO assignment event fan-out (in-process, no DB writes)');
  let Server;
  let ioClient;
  try {
    ({ Server } = require('socket.io'));
    ioClient = require('socket.io-client');
  } catch (error) {
    console.log(`  skipped (${error.message})`);
    return;
  }

  const httpServer = http.createServer();
  const io = new Server(httpServer, { cors: { origin: true } });
  const ROOM = 'request:perf';
  io.on('connection', (socket) => socket.join(ROOM));

  await new Promise((resolve) => httpServer.listen(0, resolve));
  const port = httpServer.address().port;
  const url = `http://127.0.0.1:${port}`;

  const clients = [];
  const connectAll = [];
  for (let i = 0; i < FANOUT_CLIENTS; i += 1) {
    const c = ioClient(url, { transports: ['websocket'], forceNew: true });
    clients.push(c);
    connectAll.push(new Promise((resolve) => c.on('connect', resolve)));
  }
  await Promise.all(connectAll);
  // Give the server a tick to complete every room join.
  await new Promise((r) => setTimeout(r, 100));

  const samples = [];
  const rounds = 20;
  for (let r = 0; r < rounds; r += 1) {
    // eslint-disable-next-line no-await-in-loop
    const latency = await new Promise((resolve) => {
      let received = 0;
      const start = process.hrtime.bigint();
      const onEvent = () => {
        received += 1;
        if (received === clients.length) {
          const end = process.hrtime.bigint();
          clients.forEach((c) => c.off('responder.assigned', onEvent));
          resolve(Number(end - start) / 1e6);
        }
      };
      clients.forEach((c) => c.on('responder.assigned', onEvent));
      io.to(ROOM).emit('responder.assigned', { requestId: 1, ts: Date.now() });
    });
    samples.push(latency);
  }

  samples.sort((a, b) => a - b);
  const avg = samples.reduce((s, v) => s + v, 0) / samples.length;
  console.log(
    `  fan-out to ${FANOUT_CLIENTS} clients  rounds=${rounds}  ` +
      `avg=${avg.toFixed(2)}ms  p50=${percentile(samples, 50).toFixed(2)}ms  ` +
      `p95=${percentile(samples, 95).toFixed(2)}ms`
  );

  clients.forEach((c) => c.close());
  await new Promise((resolve) => io.close(resolve));
  await new Promise((resolve) => httpServer.close(resolve));
}

async function main() {
  console.log('ERAS performance smoke test (non-destructive, read-only DB)');
  console.log(`Node ${process.version}  iterations=${ITERATIONS}  fanoutClients=${FANOUT_CLIENTS}`);

  await dbBenchmarks();
  await fanoutBenchmark();
}

main()
  .catch((error) => {
    console.error('perf-smoke failed:', error.message);
    process.exitCode = 1;
  })
  .finally(async () => {
    await prisma.$disconnect().catch(() => {});
  });
