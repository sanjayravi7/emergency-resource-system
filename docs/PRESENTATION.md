# ERAS Presentation Guide

## 5–7 minute demo

### 0:00–0:30 — Problem

“Emergency coordination can fail because information about requests, responders and resources is fragmented. ERAS puts the whole lifecycle into one realtime operational system.”

Show the authentication/landing UI.

### 0:30–1:15 — Roles

- REQUESTER — asks for help.
- RESPONDER — provides help and resources.
- ADMIN — manages users and operations.

Show role-based routing after login.

### 1:15–2:15 — Create an emergency

As REQUESTER:

1. Choose emergency type.
2. Set priority.
3. Search/select a place or use current location.
4. Select required resources.
5. Submit the emergency.

Show the request on the dispatch board.

### 2:15–3:15 — Responder response

As RESPONDER:

1. Set readiness/help types.
2. Enable resource capabilities.
3. Become AVAILABLE.
4. Receive the compatible emergency.
5. Accept/join it.

Highlight that active work changes the responder to BUSY.

### 3:15–4:15 — Allocation + realtime map

Show the emergency marker, responder marker, realtime connection state and allocation lifecycle.

Explain SERVICE versus CONSUMABLE resources.

### 4:15–5:00 — Completion

Move allocation through RESERVED → DISPATCHED → DELIVERED and show the request reach COMPLETED.

### 5:00–5:45 — Admin

Show user management, account status, activation/deactivation, operational history and audit-oriented controls.

### 5:45–6:30 — Architecture + deployment

Open `ARCHITECTURE.md`, then summarize:

**Flutter Web/Android → Render Express + Socket.IO → Neon PostgreSQL** with Firebase Auth/Hosting, Google Maps and email/push integrations.

Finish with https://eras.website and the v1.0.0-production release.

## Presentation priorities

**Technical:** realtime synchronization, transactional allocation, role-based authorization and SERVICE/CONSUMABLE modelling.

**Product:** one workflow from emergency creation to completion.

**Design:** clean light UI, map context, operational status visibility and responsive Flutter screens.

**Security:** server-side authorization, verification/reset codes, secure sessions, rate limits and no committed secrets.

## Demo setup

Use dedicated demo accounts and test resources. Before recording:

- close DevTools and terminal windows
- remove personal data from visible lists
- verify Maps and Socket.IO show connected
- create one fresh emergency for the recording
- keep a responder ready
- never show environment variable/secret screens
- use the v1.0.0-production baseline
