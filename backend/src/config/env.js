require("dotenv").config();

const env = {
  port: process.env.PORT || 5000,
  databaseUrl: process.env.DATABASE_URL,
  jwtSecret: process.env.JWT_SECRET,
  jwtExpiresIn: process.env.JWT_EXPIRES_IN || "7d",
};

if (!env.databaseUrl) {
  throw new Error("DATABASE_URL is missing");
}

if (!env.jwtSecret) {
  throw new Error("JWT_SECRET is missing");
}

module.exports = env;