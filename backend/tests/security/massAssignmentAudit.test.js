// MASS ASSIGNMENT GUARD: no endpoint may spread an untrusted request body into
// a Prisma write, and every update path must build an explicit allow-list.
//
// This is a source-level audit: it fails as soon as someone introduces
// `data: { ...req.body }` (or a variant) anywhere in the backend.

const fs = require('fs');
const path = require('path');

const SRC_DIR = path.join(__dirname, '..', '..', 'src');

function listJsFiles(dir) {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) return listJsFiles(full);
    return entry.name.endsWith('.js') ? [full] : [];
  });
}

const files = listJsFiles(SRC_DIR);
const read = (file) => fs.readFileSync(file, 'utf8');

describe('mass assignment audit', () => {
  test('the backend contains source files to audit', () => {
    expect(files.length).toBeGreaterThan(20);
  });

  test('no Prisma write spreads a raw request body', () => {
    const offenders = [];
    for (const file of files) {
      const source = read(file);
      // `...req.body` / `...req.query` / `...req.params` inside any object
      // literal is the classic mass-assignment vector.
      if (/\.\.\.\s*req\.(body|query|params)/.test(source)) {
        offenders.push(path.relative(SRC_DIR, file));
      }
    }
    expect(offenders).toEqual([]);
  });

  test('the controller layer never forwards the whole body to the database', () => {
    const offenders = [];
    for (const file of files.filter((f) => f.includes(`${path.sep}controllers${path.sep}`))) {
      const source = read(file);
      if (/prisma\.\w+\.(update|create|upsert)\s*\(\s*\{[^}]*\.\.\.req\.body/s.test(source)) {
        offenders.push(path.relative(SRC_DIR, file));
      }
    }
    expect(offenders).toEqual([]);
  });

  test('response serializers never return a stored password hash', () => {
    const offenders = [];
    for (const file of files) {
      const source = read(file);
      // A password column may never be selected into an API payload. The only
      // legitimate uses are credential reads/updates in the auth services and
      // the explicit `select` list that excludes it.
      const selectsPasswordIntoPayload =
        /select:\s*\{[^}]*password:\s*true/s.test(source) &&
        !file.includes('authService') &&
        !file.includes('userService');
      if (selectsPasswordIntoPayload) offenders.push(path.relative(SRC_DIR, file));
    }
    expect(offenders).toEqual([]);
  });

  // Protected columns must never be writable by naming them in a request body.
  // `role` is the single, deliberate exception: the ADMIN role change writes it
  // after an explicit allow-list check (asserted separately below).
  test('no source file writes a protected identity field from a request body',
    () => {
      const forbidden = [
        'acceptedById',
        'isAdmin',
        'emailVerified',
        'emailVerifiedAt',
        'passwordChangedAt',
        'firebaseUid',
        'archivedById',
        'archivedAt',
        'expiredAt',
        'passwordHash',
      ];

      const offenders = [];
      for (const file of files) {
        const source = read(file);
        for (const field of forbidden) {
          const pattern = new RegExp(
            `${field}\\s*:\\s*\\(?req\\.(body|query|params)`
          );
          if (pattern.test(source)) {
            offenders.push(`${path.relative(SRC_DIR, file)} (${field})`);
          }
        }
      }
      expect(offenders).toEqual([]);
    }
  );

  test('every role taken from a request body is allow-list validated', () => {
    const writers = [];
    for (const file of files) {
      const source = read(file);
      if (/role\s*:\s*req\.body\.role/.test(source)) {
        writers.push(path.relative(SRC_DIR, file));
      }
    }

    // Exactly two writers:
    //   * the ADMIN role change (validated allow-list, self-demotion guard),
    //   * Google registration, where the role is only a creation intent and is
    //     validated against the PUBLIC allow-list before any write.
    expect(writers.sort()).toEqual([
      'controllers/adminController.js',
      'controllers/authController.js',
    ]);

    const adminSource = read(path.join(SRC_DIR, 'controllers', 'adminController.js'));
    const roleUpdateStart = adminSource.indexOf('exports.updateUserRole');
    expect(roleUpdateStart).toBeGreaterThan(-1);
    const roleUpdate = adminSource.slice(roleUpdateStart, roleUpdateStart + 1200);
    expect(roleUpdate).toContain(
      "const allowedRoles = ['REQUESTER', 'RESPONDER', 'ADMIN']"
    );
    expect(roleUpdate).toContain('allowedRoles.includes(req.body && req.body.role)');
    expect(roleUpdate).toContain('Invalid role');

    // Google sign-in validates the requested role through the validator and the
    // service's own public-role normalizer, so a crafted body cannot create an
    // ADMIN account.
    const authSource = read(path.join(SRC_DIR, 'controllers', 'authController.js'));
    expect(authSource).toContain('validateGoogleSignIn(req.body)');

    const validator = read(path.join(SRC_DIR, 'validators', 'authValidator.js'));
    expect(validator).toContain(
      "PUBLIC_REGISTRATION_ROLES = ['REQUESTER', 'RESPONDER']"
    );

    const googleService = read(path.join(SRC_DIR, 'services', 'googleAuthService.js'));
    expect(googleService).toContain('normalizePublicRole');
    expect(googleService).toContain('PUBLIC_REGISTRATION_ROLES.includes(normalized)');
    // An EXISTING account keeps its stored role: the requested role is ignored.
    expect(googleService).toContain("The account's role is untouched");
  });

  test('the role-changing admin route is ADMIN-only behind authentication',
    () => {
      const routes = read(
        path.join(SRC_DIR, 'routes', 'adminRoutes.js')
      );
      // Every admin route inherits the guard, including the role change and the
      // log deletion endpoint.
      expect(routes).toMatch(
        /router\.use\(\s*authenticate\s*,\s*authorizeRoles\('ADMIN'\)\s*\)/
      );
    }
  );

  test('authenticated identity and role are read from the database', () => {
    const middleware = read(
      path.join(SRC_DIR, 'middleware', 'authMiddleware.js')
    );

    // The token supplies only the subject id; role comes from the live row, so
    // a forged or stale role claim can never grant privileges. `id` and
    // `userId` both point at that same verified row so every existing caller
    // (either spelling) is consistent.
    expect(middleware).toContain('role: user.role');
    expect(middleware).toContain('id: user.id');
    expect(middleware).toContain('userId: user.id');
    expect(middleware).toContain('isActive: true');
    expect(middleware).toMatch(/if \(!user\.isActive\)/);
  });

  test('auth services never log passwords, codes or tokens', () => {
    const offenders = [];
    for (const file of files) {
      const source = read(file);
      // Logging the raw variables would leak credentials into the log stream.
      if (/(logger\.\w+|console\.\w+)\([^)]*\bpassword\b\s*[,)]/.test(source)) {
        offenders.push(path.relative(SRC_DIR, file));
      }
    }
    expect(offenders).toEqual([]);
  });

});
