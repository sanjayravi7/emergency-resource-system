const env = require('../../src/config/env');
const googlePlacesService = require('../../src/services/googlePlacesService');

const originalFetch = global.fetch;

describe('Google Places API (New) Service', () => {
  const fakeApiKey = 'AIzaSyFakeKeyForTest-Places12345';

  beforeEach(() => {
    env.GOOGLE_PLACES_API_KEY = fakeApiKey;
    googlePlacesService.clearCache();
    jest.clearAllMocks();
  });

  afterAll(() => {
    global.fetch = originalFetch;
  });

  // ---------------------------------------------------------------------------
  // 1. Native Autocomplete Mapping
  // ---------------------------------------------------------------------------
  describe('autocomplete', () => {
    test('maps Places API (New) suggestions to placeId, primaryText, and secondaryText', async () => {
      const mockGoogleResponse = {
        suggestions: [
          {
            placePrediction: {
              placeId: 'ChIJ1111111111',
              structuredFormat: {
                mainText: { text: 'Government Hospital' },
                secondaryText: { text: 'Kolenchery, Ernakulam' },
              },
            },
          },
          {
            placePrediction: {
              place: 'places/ChIJ2222222222',
              text: { text: 'Kolenchery Medical Mission' },
            },
          },
        ],
      };

      global.fetch = jest.fn().mockResolvedValue({
        ok: true,
        status: 200,
        json: async () => mockGoogleResponse,
      });

      const result = await googlePlacesService.autocomplete({
        query: 'Government Hospital',
        latitude: 9.9816,
        longitude: 76.2999,
        radiusMeters: 30000,
      });

      expect(result.predictions).toHaveLength(2);
      expect(result.predictions[0]).toEqual({
        placeId: 'ChIJ1111111111',
        primaryText: 'Government Hospital',
        secondaryText: 'Kolenchery, Ernakulam',
      });
      expect(result.predictions[1]).toEqual({
        placeId: 'ChIJ2222222222',
        primaryText: 'Kolenchery Medical Mission',
        secondaryText: '',
      });

      // Verify request payload to Places API (New)
      expect(global.fetch).toHaveBeenCalledTimes(1);
      const [url, options] = global.fetch.mock.calls[0];
      expect(url).toBe('https://places.googleapis.com/v1/places:autocomplete');
      expect(options.headers['X-Goog-Api-Key']).toBe(fakeApiKey);
      const parsedBody = JSON.parse(options.body);
      expect(parsedBody.input).toBe('Government Hospital');
      expect(parsedBody.locationBias.circle.center.latitude).toBe(9.9816);
      expect(parsedBody.locationBias.circle.center.longitude).toBe(76.2999);
    });

    test('empty or whitespace query returns empty predictions without calling API', async () => {
      global.fetch = jest.fn();

      const r1 = await googlePlacesService.autocomplete({ query: '' });
      const r2 = await googlePlacesService.autocomplete({ query: '   ' });

      expect(r1.predictions).toEqual([]);
      expect(r2.predictions).toEqual([]);
      expect(global.fetch).not.toHaveBeenCalled();
    });

    test('zero coordinates (0, 0) are rejected as bias per rule', async () => {
      global.fetch = jest.fn().mockResolvedValue({
        ok: true,
        status: 200,
        json: async () => ({ suggestions: [] }),
      });

      await googlePlacesService.autocomplete({
        query: 'Test Place',
        latitude: 0,
        longitude: 0,
      });

      expect(global.fetch).toHaveBeenCalledTimes(1);
      const [, options] = global.fetch.mock.calls[0];
      const parsedBody = JSON.parse(options.body);
      expect(parsedBody.locationBias).toBeUndefined();
    });
  });

  // ---------------------------------------------------------------------------
  // 2. Native Place Details Mapping & Canonical Coordinates
  // ---------------------------------------------------------------------------
  describe('placeDetails', () => {
    test('resolves place details into canonical coordinates and formatted label', async () => {
      const mockDetailResponse = {
        id: 'ChIJPlaceGovHosp',
        displayName: { text: 'Government Hospital' },
        formattedAddress: 'Aluva - Munnar Rd, Kolenchery, Kerala 682311',
        location: {
          latitude: 9.979123,
          longitude: 76.471456,
        },
      };

      global.fetch = jest.fn().mockResolvedValue({
        ok: true,
        status: 200,
        json: async () => mockDetailResponse,
      });

      const result = await googlePlacesService.placeDetails('ChIJPlaceGovHosp');

      expect(result).toEqual({
        placeId: 'ChIJPlaceGovHosp',
        label: 'Government Hospital, Aluva - Munnar Rd, Kolenchery, Kerala 682311',
        latitude: 9.979123,
        longitude: 76.471456,
      });

      const [url, options] = global.fetch.mock.calls[0];
      expect(url).toBe('https://places.googleapis.com/v1/places/ChIJPlaceGovHosp');
      expect(options.headers['X-Goog-FieldMask']).toBe(
        'id,displayName,formattedAddress,location'
      );
    });

    test('rejects (0, 0) coordinates from Google without fabricating fallback', async () => {
      global.fetch = jest.fn().mockResolvedValue({
        ok: true,
        status: 200,
        json: async () => ({
          id: 'ChIJZero',
          displayName: { text: 'Zero Island Place' },
          location: { latitude: 0.0, longitude: 0.0 },
        }),
      });

      await expect(
        googlePlacesService.placeDetails('ChIJZero')
      ).rejects.toThrow('Google returned invalid (0, 0) coordinates');
    });

    test('rejects missing or non-finite coordinates', async () => {
      global.fetch = jest.fn().mockResolvedValue({
        ok: true,
        status: 200,
        json: async () => ({
          id: 'ChIJNoLoc',
          displayName: { text: 'No Location Place' },
        }),
      });

      await expect(
        googlePlacesService.placeDetails('ChIJNoLoc')
      ).rejects.toThrow('Google returned no valid coordinates');
    });
  });

  // ---------------------------------------------------------------------------
  // 3. Native Nearby Place Search Mapping & Distance Ranking
  // ---------------------------------------------------------------------------
  describe('searchNearby', () => {
    test('maps category to Google Table A types and ranks places by distance', async () => {
      const centerLat = 9.9800;
      const centerLng = 76.3000;

      const mockNearbyResponse = {
        places: [
          {
            id: 'place-far',
            displayName: { text: 'Far Medical Center' },
            formattedAddress: 'Highway 49',
            location: { latitude: 9.9950, longitude: 76.3150 }, // ~2.3 km
          },
          {
            id: 'place-near',
            displayName: { text: 'Near City Hospital' },
            formattedAddress: 'Main St',
            location: { latitude: 9.9820, longitude: 76.3020 }, // ~310 m
          },
        ],
      };

      global.fetch = jest.fn().mockResolvedValue({
        ok: true,
        status: 200,
        json: async () => mockNearbyResponse,
      });

      const result = await googlePlacesService.searchNearby({
        latitude: centerLat,
        longitude: centerLng,
        category: 'hospital',
        radiusMeters: 5000,
        maxResults: 10,
      });

      expect(result.places).toHaveLength(2);
      // Closest place comes first (ranked by distance)
      expect(result.places[0].placeId).toBe('place-near');
      expect(result.places[0].name).toBe('Near City Hospital');
      expect(result.places[0].distanceMeters).toBeLessThan(result.places[1].distanceMeters);

      expect(result.places[1].placeId).toBe('place-far');
      expect(result.places[1].name).toBe('Far Medical Center');

      // Verify request payload
      const [url, options] = global.fetch.mock.calls[0];
      expect(url).toBe('https://places.googleapis.com/v1/places:searchNearby');
      const body = JSON.parse(options.body);
      expect(body.includedTypes).toEqual(['hospital']);
      expect(body.rankPreference).toBe('DISTANCE');
      expect(body.locationRestriction.circle.center.latitude).toBe(centerLat);
      expect(body.locationRestriction.circle.center.longitude).toBe(centerLng);
    });

    test('correctly maps various emergency categories', () => {
      expect(googlePlacesService.CATEGORY_MAP.police).toEqual(['police']);
      expect(googlePlacesService.CATEGORY_MAP.firestation).toEqual(['fire_station']);
      expect(googlePlacesService.CATEGORY_MAP.school).toEqual([
        'school',
        'primary_school',
        'secondary_school',
      ]);
      expect(googlePlacesService.CATEGORY_MAP.college).toEqual(['university']);
      expect(googlePlacesService.CATEGORY_MAP.railway).toEqual([
        'train_station',
        'light_rail_station',
        'subway_station',
      ]);
      expect(googlePlacesService.CATEGORY_MAP.bus).toEqual(['bus_station', 'bus_stop']);
      expect(googlePlacesService.CATEGORY_MAP.church).toEqual(['church']);
      expect(googlePlacesService.CATEGORY_MAP.temple).toEqual([
        'hindu_temple',
        'buddhist_temple',
        'shinto_shrine',
      ]);
      expect(googlePlacesService.CATEGORY_MAP.mosque).toEqual(['mosque']);
    });

    test('rejects (0, 0) coordinates for nearby search', async () => {
      await expect(
        googlePlacesService.searchNearby({
          latitude: 0,
          longitude: 0,
          category: 'hospital',
        })
      ).rejects.toThrow('Coordinates (0, 0) are invalid');
    });

    test('skips places with (0, 0) or invalid coordinates from results', async () => {
      global.fetch = jest.fn().mockResolvedValue({
        ok: true,
        status: 200,
        json: async () => ({
          places: [
            {
              id: 'zero-place',
              displayName: { text: 'Bogus Island' },
              location: { latitude: 0.0, longitude: 0.0 },
            },
            {
              id: 'valid-place',
              displayName: { text: 'Real Clinic' },
              formattedAddress: 'Road 1',
              location: { latitude: 9.981, longitude: 76.301 },
            },
          ],
        }),
      });

      const result = await googlePlacesService.searchNearby({
        latitude: 9.98,
        longitude: 76.30,
        category: 'hospital',
      });

      expect(result.places).toHaveLength(1);
      expect(result.places[0].placeId).toBe('valid-place');
    });
  });

  // ---------------------------------------------------------------------------
  // 4. Invalid Responses, API Failures, and Key Redaction
  // ---------------------------------------------------------------------------
  describe('error handling and security', () => {
    test('unconfigured API key produces clear actionable 503 error', async () => {
      env.GOOGLE_PLACES_API_KEY = null;

      await expect(
        googlePlacesService.autocomplete({ query: 'hospital' })
      ).rejects.toMatchObject({
        statusCode: 503,
        code: 'PLACES_NOT_CONFIGURED',
      });
    });

    test('Places API (New) disabled or permission denied surfaces actionable guidance', async () => {
      global.fetch = jest.fn().mockResolvedValue({
        ok: false,
        status: 403,
        json: async () => ({
          error: {
            code: 403,
            message:
              'Requests to this API places.googleapis.com method google.maps.places.v1.Places.AutocompletePlaces are blocked.',
            status: 'PERMISSION_DENIED',
          },
        }),
      });

      await expect(
        googlePlacesService.autocomplete({ query: 'clinic' })
      ).rejects.toMatchObject({
        statusCode: 502,
        code: 'PLACES_API_DISABLED',
        message: 'Nearby places unavailable. Enable Places API (New) in Google Cloud.',
      });
    });

    test('API key is never leaked in error messages', async () => {
      const secretKey = 'SECRET_PLACES_API_KEY_99999';
      env.GOOGLE_PLACES_API_KEY = secretKey;

      global.fetch = jest.fn().mockResolvedValue({
        ok: false,
        status: 500,
        json: async () => ({
          error: {
            message: `Internal error for key ${secretKey}`,
          },
        }),
      });

      try {
        await googlePlacesService.placeDetails('ChIJTest');
        throw new Error('should have failed');
      } catch (err) {
        expect(err.message).not.toContain(secretKey);
        expect(err.message).toContain('[REDACTED]');
      }
    });

    test('timeout produces a 504 error', async () => {
      const abortError = new Error('The operation was aborted');
      abortError.name = 'AbortError';

      global.fetch = jest.fn().mockRejectedValue(abortError);

      await expect(
        googlePlacesService.autocomplete({ query: 'test' })
      ).rejects.toMatchObject({
        statusCode: 504,
        code: 'TIMEOUT',
      });
    });
  });
});
