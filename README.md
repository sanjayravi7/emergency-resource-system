# ERAS — Emergency Resource Allocation System

> **Right Resource. Right Place. Right Time.**

ERAS is a real-time emergency coordination platform that connects people requesting help with responders and available resources through a role-based Flutter application, an Express/Node.js API, PostgreSQL, Google Maps, and Socket.IO.

**Production:** https://eras.website
**Firebase Hosting:** https://eras-production-f3ce6.web.app
**API health:** https://eras-api-sdjo.onrender.com/health
**Release:** v1.0.0-production

## What ERAS solves

Emergency coordination can suffer from fragmented information, delayed resource visibility, and weak situational awareness. ERAS provides one operational workflow:

**Request → Match → Accept → Allocate → Dispatch → Track → Deliver → Complete**

The system supports reusable **SERVICE** resources and inventory-backed **CONSUMABLE** resources.

## Core features

| Area | Capabilities |
|---|---|
| Authentication | Email/password, email verification, 6-digit password reset, Google/Firebase sign-in |
| Roles | REQUESTER, RESPONDER, ADMIN with role-based routing and authorization |
| Emergency requests | Category, priority, description, place/current location and required resources |
| Resource coordination | Availability, SERVICE vs CONSUMABLE semantics, quantity-aware allocation |
| Responder network | Availability, help types, resource capabilities and active assignments |
| Real-time operations | Socket.IO status updates and responder location updates |
| Maps & location | Google Maps, place search, current location, emergency/responder markers |
| Lifecycle | Pending → Accepted → In Progress → Partially Allocated → Completed / Cancelled |
| Admin | User management, activation/deactivation, history and audit controls |
| Notifications | Verification/welcome/reset email and FCM support for backgrounded responders |
| Security | JWT sessions, server-side authorization, rate limits, security headers, validation and audit logging |
| Deployment | Flutter Web on Firebase Hosting, Express + Socket.IO on Render, PostgreSQL on Neon |

## Technology stack

**Frontend:** Flutter, Dart, Google Maps, Geolocator, Socket.IO client, Firebase Auth/FCM
**Backend:** Node.js, Express 5, Socket.IO, Prisma, Zod, JWT, bcrypt, Helmet, rate limiting
**Database:** PostgreSQL + Prisma migrations
**Cloud:** Render, Neon, Firebase Hosting, Firebase Auth, Resend
**Platforms:** Web/PWA + Android

## Repository structure

```text
.
├── backend/
│   ├── prisma/
│   ├── src/
│   └── tests/
├── frontend/
│   └── emergency_app/
│       ├── lib/
│       ├── android/
│       └── tool/
├── docs/
├── render.yaml
└── README.md
```

## Local installation

### Backend

Requirements: Node.js, PostgreSQL and npm.

```bash
cd backend
npm ci
cp .env.example .env
# Fill DATABASE_URL and local development values in .env
npx prisma generate
npx prisma migrate deploy
npm test
npm start
```

### Flutter

Requirements: Flutter SDK and a configured Web/Android toolchain.

```bash
cd frontend/emergency_app
flutter pub get
flutter analyze
flutter test
flutter run -d chrome
```

## Production deployment

### Web

```bash
cd frontend/emergency_app
./tool/build_production_web.sh
firebase deploy --only hosting --project "$ERAS_FIREBASE_PROJECT_ID"
```

### Android

```bash
cd frontend/emergency_app
./tool/build_release_apk.sh
```

The release helper validates the production package, Firebase configuration, OAuth client and release signing requirements before producing the release APK.

Full production setup, secret handling, Render, Neon, Firebase, Maps and smoke tests are documented in `PRODUCTION_DEPLOYMENT.md`.

## Demo flow

1. **Requester** signs in and creates an emergency with type, priority, location and required resources.
2. **Responder** enables relevant help/resource capabilities and becomes AVAILABLE.
3. The compatible emergency appears in the responder workflow.
4. **Responder** accepts/joins the emergency and becomes BUSY.
5. Resources are allocated using SERVICE/CONSUMABLE rules.
6. The operational map shows emergency and responder context.
7. Allocation progresses through **RESERVED → DISPATCHED → DELIVERED**.
8. The request becomes **COMPLETED** when required delivered quantities are satisfied.
9. **Admin** reviews users, account status, operational history and audit information.

See `docs/PRESENTATION.md` for a 5–7 minute presentation script.

## Architecture

The system separates the Flutter clients, identity services, REST/realtime backend, persistence and external integrations. See `docs/ARCHITECTURE.md` and `docs/architecture.svg`.

## Screenshots

Presentation-ready copies are stored under `docs/screenshots/`. All supplied copies are cropped/redacted for presentation use.

## Security

- Production secrets stay outside Git.
- Public registration is limited to operational user roles; ADMIN provisioning is controlled separately.
- Passwords and reset codes are never returned by API responses.
- Authorization is server-side and based on current user/account state.
- Production API uses HTTPS and Socket.IO uses the Render origin.
- Browser Maps credentials are protected by referrer/API restrictions.

## Testing

The repository contains backend Jest tests, Flutter tests, lifecycle tests, configuration verifiers and production helper scripts.

Manual physical-device acceptance criteria are documented in `MANUAL_ACCEPTANCE_CHECKLIST.md`.

## Production release

```text
v1.0.0-production
```

Treat this tag as the production baseline for demos and regression checks.

## Engineering records

Detailed implementation and audit records remain in the repository for traceability. Start with:

- `FINAL_REPORT.md`
- `PRODUCTION_DEPLOYMENT.md`
- `PRODUCTION_ACCEPTANCE_REPORT.md`
- `SECURITY_HARDENING_REPORT.md`

The README and `docs/` folder are the presentation surface; historical engineering records are retained for traceability.
