const app = require("./app");
const env = require("./config/env");
const prisma = require("./config/prisma");

async function startServer() {
  try {
    await prisma.$connect();

    console.log("PostgreSQL connected");

    app.listen(env.port, () => {
      console.log(
        `Server running on http://localhost:${env.port}`
      );
    });
  } catch (error) {
    console.error("Server startup failed:", error);
    process.exit(1);
  }
}

startServer();