const mockUser = {
  id: 42,
  role: 'REQUESTER',
  isActive: true,
  passwordChangedAt: null,
};

jest.mock('../../src/config/prisma', () => ({
  user: {
    findUnique: jest.fn(async ({ where }) => {
      if (where.id === 42) return mockUser;
      return null;
    }),
  },
}));

const request = require('supertest');
const jwt = require('jsonwebtoken');

const app = require('../../src/app');
const env = require('../../src/config/env');
const googlePlacesService = require('../../src/services/googlePlacesService');
const reverseGeocodingService = require('../../src/services/reverseGeocodingService');

describe('Location API Endpoints (native & reverse)', () => {
  let token;

  beforeAll(() => {
    token = jwt.sign(
      {
        userId: 42,
        email: 'requester@test.eras',
        role: 'REQUESTER',
        authProvider: 'PASSWORD',
      },
      env.JWT_SECRET,
      { expiresIn: '1h' }
    );
  });

  describe('GET /api/location/reverse', () => {
    test('requires authentication', async () => {
      const res = await request(app).get('/api/location/reverse?latitude=9.98&longitude=76.30');
      expect(res.status).toBe(401);
    });

    test('rejects invalid or missing latitude / longitude', async () => {
      const res1 = await request(app)
        .get('/api/location/reverse?latitude=abc&longitude=76.30')
        .set('Authorization', `Bearer ${token}`);
      expect(res1.status).toBe(422);

      const res2 = await request(app)
        .get('/api/location/reverse?latitude=9.98&longitude=200')
        .set('Authorization', `Bearer ${token}`);
      expect(res2.status).toBe(422);
    });

    test('returns reverse geocoding result for valid coordinates', async () => {
      jest.spyOn(reverseGeocodingService, 'fetchPhoton').mockResolvedValueOnce({
        displayName: 'Kolenchery, Kerala, India',
        latitude: 9.98,
        longitude: 76.30,
      });

      const res = await request(app)
        .get('/api/location/reverse?latitude=9.98&longitude=76.30')
        .set('Authorization', `Bearer ${token}`);

      expect(res.status).toBe(200);
      expect(res.body.success).toBe(true);
      expect(res.body.data.displayName).toBe('Kolenchery, Kerala, India');
    });
  });

  describe('GET /api/location/autocomplete', () => {
    test('requires authentication', async () => {
      const res = await request(app).get('/api/location/autocomplete?query=hospital');
      expect(res.status).toBe(401);
    });

    test('returns autocomplete predictions for valid query', async () => {
      jest.spyOn(googlePlacesService, 'autocomplete').mockResolvedValueOnce({
        predictions: [
          {
            placeId: 'p1',
            primaryText: 'Government Hospital',
            secondaryText: 'Kolenchery',
          },
        ],
      });

      const res = await request(app)
        .get('/api/location/autocomplete?query=Government%20Hospital&latitude=9.98&longitude=76.30')
        .set('Authorization', `Bearer ${token}`);

      expect(res.status).toBe(200);
      expect(res.body.success).toBe(true);
      expect(res.body.data.predictions).toHaveLength(1);
      expect(res.body.data.predictions[0].placeId).toBe('p1');
    });
  });

  describe('GET /api/location/details', () => {
    test('requires authentication', async () => {
      const res = await request(app).get('/api/location/details/p1');
      expect(res.status).toBe(401);
    });

    test('resolves place details into canonical coordinates and label', async () => {
      jest.spyOn(googlePlacesService, 'placeDetails').mockResolvedValueOnce({
        placeId: 'p1',
        label: 'Government Hospital, Kolenchery',
        latitude: 9.979,
        longitude: 76.471,
      });

      const res = await request(app)
        .get('/api/location/details/p1')
        .set('Authorization', `Bearer ${token}`);

      expect(res.status).toBe(200);
      expect(res.body.success).toBe(true);
      expect(res.body.data.latitude).toBe(9.979);
      expect(res.body.data.longitude).toBe(76.471);
    });

    test('also accepts placeId via query parameter', async () => {
      jest.spyOn(googlePlacesService, 'placeDetails').mockResolvedValueOnce({
        placeId: 'p2',
        label: 'Taluk Hospital',
        latitude: 9.980,
        longitude: 76.470,
      });

      const res = await request(app)
        .get('/api/location/details?placeId=p2')
        .set('Authorization', `Bearer ${token}`);

      expect(res.status).toBe(200);
      expect(res.body.data.placeId).toBe('p2');
    });
  });

  describe('GET /api/location/nearby', () => {
    test('requires authentication', async () => {
      const res = await request(app).get('/api/location/nearby?latitude=9.98&longitude=76.30&category=hospital');
      expect(res.status).toBe(401);
    });

    test('rejects (0, 0) coordinates with 422', async () => {
      const res = await request(app)
        .get('/api/location/nearby?latitude=0&longitude=0&category=hospital')
        .set('Authorization', `Bearer ${token}`);

      expect(res.status).toBe(422);
      expect(res.body.message).toContain('(0, 0)');
    });

    test('returns nearby places ranked by distance', async () => {
      jest.spyOn(googlePlacesService, 'searchNearby').mockResolvedValueOnce({
        places: [
          {
            placeId: 'h1',
            name: 'City Hospital',
            address: 'Main Road',
            latitude: 9.981,
            longitude: 76.301,
            distanceMeters: 250,
          },
        ],
      });

      const res = await request(app)
        .get('/api/location/nearby?latitude=9.98&longitude=76.30&category=hospital')
        .set('Authorization', `Bearer ${token}`);

      expect(res.status).toBe(200);
      expect(res.body.success).toBe(true);
      expect(res.body.data.places).toHaveLength(1);
      expect(res.body.data.places[0].placeId).toBe('h1');
      expect(res.body.data.places[0].distanceMeters).toBe(250);
    });
  });
});
