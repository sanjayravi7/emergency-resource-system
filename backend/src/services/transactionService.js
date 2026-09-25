const prisma = require('../config/prisma');

/**
 * PostgreSQL raises SQLSTATE 40001 / 40P01 for the losing side of a
 * Serializable race. Retrying the complete transaction preserves the
 * Serializable + row-lock guarantees while returning a useful business error.
 */
function isRetryableTransactionError(error) {
  if (!error) return false;
  if (error.code === 'P2034') return true;

  return /40001|40P01|could not serialize|deadlock detected/i.test(
    error.message || ''
  );
}

async function runSerializableTransaction(callback, retries = 5) {
  let lastError;

  for (let attempt = 0; attempt <= retries; attempt += 1) {
    try {
      return await prisma.$transaction(callback, {
        isolationLevel: 'Serializable',
      });
    } catch (error) {
      if (!isRetryableTransactionError(error)) throw error;

      lastError = error;
      await new Promise((resolve) =>
        setTimeout(resolve, 10 * (attempt + 1) + Math.floor(Math.random() * 10))
      );
    }
  }

  throw lastError;
}

module.exports = {
  isRetryableTransactionError,
  runSerializableTransaction,
};
