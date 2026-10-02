// HTTP hardening contract: the headers ERAS production must always send, and
// the absence of unsafe CSP directives.

const {
  securityHeaders,
  cspPolicy,
  DEFAULT_API_CSP,
} = require('../../src/middleware/securityHeaders');
const env = require('../../src/config/env');

function runMiddleware(req = {}) {
  const headers = {};
  const res = { setHeader: (name, value) => { headers[name.toLowerCase()] = value; } };
  securityHeaders(req, res, () => {});
  return headers;
}

describe('security headers', () => {
  test('sets nosniff, frame denial, referrer and permissions policies', () => {
    const headers = runMiddleware();
    expect(headers['x-content-type-options']).toBe('nosniff');
    expect(headers['x-frame-options']).toBe('DENY');
    expect(headers['referrer-policy']).toBe('no-referrer');
    expect(headers['permissions-policy']).toContain('camera=()');
    expect(headers['permissions-policy']).toContain('geolocation=(self)');
    expect(headers['x-permitted-cross-domain-policies']).toBe('none');
    expect(headers['cache-control']).toBe('no-store');
  });

  test('always sends a Content-Security-Policy with frame-ancestors and object-src restrictions', () => {
    const headers = runMiddleware();
    expect(headers['content-security-policy']).toBeTruthy();
    expect(headers['content-security-policy']).toContain("frame-ancestors 'self'");
    expect(headers['content-security-policy']).toContain("object-src 'none'");
  });

  test('the default API policy executes nothing (no unsafe-eval / unsafe-inline)', () => {
    expect(DEFAULT_API_CSP).not.toContain('unsafe-eval');
    expect(DEFAULT_API_CSP).not.toContain('unsafe-inline');
    expect(cspPolicy()).toBe(DEFAULT_API_CSP);
  });

  test('HSTS is only sent in production', () => {
    const previous = env.IS_PRODUCTION;
    env.IS_PRODUCTION = false;
    expect(runMiddleware()['strict-transport-security']).toBeUndefined();

    env.IS_PRODUCTION = true;
    const headers = runMiddleware();
    expect(headers['strict-transport-security']).toContain('max-age=');
    expect(headers['strict-transport-security']).toContain('includeSubDomains');
    env.IS_PRODUCTION = previous;
  });

  test('an explicit CSP_POLICY override wins (documented escape hatch)', () => {
    const previous = process.env.CSP_POLICY;
    process.env.CSP_POLICY = "default-src 'self'";
    expect(cspPolicy()).toBe("default-src 'self'");
    if (previous === undefined) delete process.env.CSP_POLICY;
    else process.env.CSP_POLICY = previous;
  });
});
