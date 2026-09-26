process.env.DATABASE_URL = 'postgresql://test/test';
process.env.JWT_SECRET = 'test-secret';

const {
  fetchPhoton,
  displayNameFromProperties,
} = require('../../src/services/reverseGeocodingService');

describe('Photon reverse geocoding service', () => {
  const originalFetch = global.fetch;
  afterEach(() => {
    global.fetch = originalFetch;
  });

  test('maps a Photon feature to a small normalized result', async () => {
    global.fetch = jest.fn().mockResolvedValue({
      ok: true,
      json: async () => ({
        features: [{
          properties: { name: 'Central Hospital', street: 'Main Road', housenumber: '7', city: 'Kochi' },
          geometry: { coordinates: [76, 9] },
        }],
      }),
    });

    await expect(fetchPhoton(9, 76)).resolves.toEqual({
      displayName: 'Central Hospital, 7 Main Road, Kochi',
      latitude: 9,
      longitude: 76,
    });
    expect(String(global.fetch.mock.calls[0][0])).toContain('lat=9');
    expect(global.fetch.mock.calls[0][1].headers).toEqual(
      expect.objectContaining({ Accept: 'application/json' }),
    );
  });

  test('returns null for no Photon feature and does not fabricate an address', async () => {
    global.fetch = jest.fn().mockResolvedValue({ ok: true, json: async () => ({ features: [] }) });
    await expect(fetchPhoton(10, 77)).resolves.toBeNull();
    expect(displayNameFromProperties({})).toBe('');
  });

  test('turns an aborted Photon request into a timeout error', async () => {
    const error = new Error('aborted');
    error.name = 'AbortError';
    global.fetch = jest.fn().mockRejectedValue(error);
    await expect(fetchPhoton(11, 78)).rejects.toMatchObject({
      message: 'Reverse geocoding service timed out',
      statusCode: 504,
    });
  });
});
