// In-memory Prisma stand-in for the AuthCode table.
//
// Used by tests that must exercise the REAL service logic (hashing, TTL,
// single use, attempt limit, throttling) without a PostgreSQL instance. It is a
// test helper, never imported by application code.

let rows = [];
let nextId = 1;

function matchesWhere(row, where = {}) {
  return Object.entries(where).every(([key, value]) => {
    if (value && typeof value === 'object' && !(value instanceof Date)) {
      if ('not' in value && row[key] === value.not) return false;
      if ('gte' in value && !(new Date(row[key]) >= new Date(value.gte))) return false;
      if ('lt' in value && !(new Date(row[key]) < new Date(value.lt))) return false;
      if ('lte' in value && !(new Date(row[key]) <= new Date(value.lte))) return false;
      if ('in' in value && !value.in.includes(row[key])) return false;
      return true;
    }
    return row[key] === value;
  });
}

const authCode = {
  create: async ({ data }) => {
    const row = {
      id: nextId++,
      attempts: 0,
      maxAttempts: 5,
      consumedAt: null,
      createdAt: data.lastSentAt || new Date(),
      ...data,
    };
    rows.push(row);
    return { ...row };
  },
  findFirst: async ({ where, orderBy } = {}) => {
    const found = rows.filter((row) => matchesWhere(row, where));
    if (orderBy && orderBy.id === 'desc') found.sort((a, b) => b.id - a.id);
    return found.length ? { ...found[0] } : null;
  },
  findMany: async ({ where } = {}) => rows.filter((row) => matchesWhere(row, where)).map((r) => ({ ...r })),
  update: async ({ where, data }) => {
    const row = rows.find((candidate) => candidate.id === where.id);
    Object.assign(row, data);
    return { ...row };
  },
  updateMany: async ({ where, data }) => {
    const affected = rows.filter((row) => matchesWhere(row, where));
    affected.forEach((row) => Object.assign(row, data));
    return { count: affected.length };
  },
  count: async ({ where } = {}) => rows.filter((row) => matchesWhere(row, where)).length,
  deleteMany: async ({ where } = {}) => {
    const before = rows.length;
    rows = rows.filter((row) => !matchesWhere(row, where));
    return { count: before - rows.length };
  },
};

const prisma = {
  authCode,
  $transaction: async (callback) => callback(prisma),
};

module.exports = {
  prisma,
  authCode,
  reset() {
    rows = [];
    nextId = 1;
  },
  allRows() {
    return rows.map((row) => ({ ...row }));
  },
};
