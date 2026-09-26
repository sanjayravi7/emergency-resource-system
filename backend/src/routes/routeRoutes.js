const express = require('express');
const router = express.Router();
const routeController = require('../controllers/routeController');
const authenticate = require('../middleware/authMiddleware');

/**
 * Road routing (Google Routes API Compute Routes).
 *
 * Authentication is mandatory: the endpoint spends a server-side, billable
 * Google quota, so anonymous callers are rejected by authMiddleware before the
 * controller (and therefore before the upstream request) runs.
 *
 * Every authenticated ERAS role may compute a route:
 *   * REQUESTER - sees the responder approaching their own emergency,
 *   * RESPONDER - sees the road route to the emergency they accepted,
 *   * ADMIN     - sees the same route on the dispatch board.
 */
router.post('/compute', authenticate, routeController.computeRoute);

module.exports = router;
