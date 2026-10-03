// Normalize provider results for API responses. A provider's successful
// synchronous response means it accepted the message for processing; it does
// not prove that it reached the recipient's inbox. Keep request acceptance and
// confirmed delivery as separate states (`delivered` remains null unless a
// provider webhook explicitly confirms inbox delivery).

function isEmailRequestAccepted(result) {
  return Boolean(
    result &&
      (result.deliveryAccepted === true ||
        result.accepted === true ||
        result.delivered === true ||
        result.deliveryResult === 'success' ||
        result.deliveryResult === 'accepted')
  );
}

function safeProviderValue(value) {
  if (typeof value !== 'string') return null;
  const normalized = value.trim();
  if (!normalized || normalized.length > 100) return null;
  if (!/^[A-Za-z0-9_.:-]+$/.test(normalized)) return null;
  if (/^\d{6}$/.test(normalized) || /@/.test(normalized)) return null;
  return normalized;
}

function summarizeEmailDelivery(result) {
  const accepted = isEmailRequestAccepted(result);
  const delivered = Boolean(result?.deliveryConfirmed === true && result?.delivered === true);
  const configured = result?.transportConfigured === 'yes' ||
    result?.transportConfigured === true;
  const configuredExplicitlyFalse = result?.transportConfigured === 'no' ||
    result?.transportConfigured === false;
  const provider = safeProviderValue(result?.provider) || 'unconfigured';
  const originalResult = result?.deliveryResult;

  let deliveryResult;
  if (accepted) {
    deliveryResult = 'accepted';
  } else if (originalResult === 'unconfigured' || configuredExplicitlyFalse) {
    deliveryResult = 'unconfigured';
  } else if (originalResult === 'not_attempted') {
    deliveryResult = 'not_attempted';
  } else {
    deliveryResult = configured || originalResult ? 'failed' : 'unconfigured';
  }

  const status = result?.providerResponseStatus;
  const providerResponseStatus =
    Number.isInteger(status) && status >= 100 && status <= 599 ? status : null;

  return {
    accepted,
    deliveryAccepted: accepted,
    requestAccepted: accepted,
    // Provider acceptance is not proof of inbox delivery. No configured
    // transport currently supplies a verified delivery webhook, so leave this
    // unknown rather than converting acceptance into a false delivery claim.
    delivered: delivered ? true : null,
    deliveryConfirmed: delivered,
    deliveryStatus: deliveryResult,
    deliveryResult,
    provider,
    transport: safeProviderValue(result?.transport) || 'unconfigured',
    transportConfigured: accepted || configured
      ? 'yes'
      : configuredExplicitlyFalse
        ? 'no'
        : 'no',
    providerResponseStatus,
    providerErrorCode: safeProviderValue(result?.providerErrorCode),
    providerErrorType: safeProviderValue(result?.providerErrorType),
    messageId: safeProviderValue(result?.messageId),
    fallbackUsed: result?.fallbackUsed === true,
  };
}

module.exports = {
  isEmailRequestAccepted,
  summarizeEmailDelivery,
};
