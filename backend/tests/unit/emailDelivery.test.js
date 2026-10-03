const {
  isEmailRequestAccepted,
  summarizeEmailDelivery,
} = require('../../src/domain/emailDelivery');

describe('email delivery state normalization', () => {
  test('provider acceptance is not reported as confirmed inbox delivery', () => {
    const summary = summarizeEmailDelivery({
      deliveryAccepted: true,
      accepted: true,
      deliveryResult: 'accepted',
      transportConfigured: 'yes',
      provider: 'Resend',
      transport: 'resend',
      providerResponseStatus: 202,
    });

    expect(summary).toMatchObject({
      accepted: true,
      deliveryAccepted: true,
      requestAccepted: true,
      delivered: null,
      deliveryConfirmed: false,
      deliveryStatus: 'accepted',
      deliveryResult: 'accepted',
      provider: 'Resend',
      transport: 'resend',
      providerResponseStatus: 202,
    });
  });

  test('only an explicit provider delivery confirmation reports delivered', () => {
    const summary = summarizeEmailDelivery({
      deliveryAccepted: true,
      delivered: true,
      deliveryConfirmed: true,
      deliveryResult: 'accepted',
      transportConfigured: 'yes',
      provider: 'Resend',
    });

    expect(summary.delivered).toBe(true);
    expect(summary.deliveryConfirmed).toBe(true);
    expect(summary.accepted).toBe(true);
  });

  test.each([
    ['failed', 'failed'],
    ['unconfigured', 'unconfigured'],
    ['not_attempted', 'not_attempted'],
  ])('reports %s without pretending delivery was confirmed', (input, expected) => {
    const summary = summarizeEmailDelivery({
      accepted: false,
      delivered: null,
      deliveryResult: input,
      transportConfigured: input === 'unconfigured' ? 'no' : 'yes',
      provider: input === 'unconfigured' ? 'unconfigured' : 'Resend',
    });

    expect(summary.accepted).toBe(false);
    expect(summary.delivered).toBeNull();
    expect(summary.deliveryConfirmed).toBe(false);
    expect(summary.deliveryStatus).toBe(expected);
  });

  test('legacy delivered/success results remain accepted for compatibility', () => {
    expect(isEmailRequestAccepted({ delivered: true })).toBe(true);
    expect(isEmailRequestAccepted({ deliveryResult: 'success' })).toBe(true);
    expect(summarizeEmailDelivery({ delivered: true }).accepted).toBe(true);
    expect(summarizeEmailDelivery({ delivered: true }).delivered).toBeNull();
  });
});
