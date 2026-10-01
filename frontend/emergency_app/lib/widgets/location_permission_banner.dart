import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'auth_motion.dart';

/// Non-blocking dashboard notice shown after the automatic post-login
/// permission check/request did not grant location access.
class LocationPermissionBanner extends StatelessWidget {
  const LocationPermissionBanner({
    super.key,
    required this.onEnableLocation,
    this.requestInProgress = false,
  });

  final Future<void> Function() onEnableLocation;
  final bool requestInProgress;

  @override
  Widget build(BuildContext context) {
    final p = ErasPalette.of(context);

    return EntranceReveal(
      offset: const Offset(0, 4),
      child: AnimatedContainer(
        duration: AuthMotion.normal,
        curve: AuthMotion.outCurve,
        key: const Key('location-permission-disabled-banner'),
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: p.amberDim,
          border: Border.all(
            color: p.amber.withValues(alpha: p.dark ? .45 : .35),
          ),
          borderRadius: BorderRadius.circular(7),
        ),
        child: Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 14,
          runSpacing: 8,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.location_off_outlined,
                  size: 18,
                  color: p.amber,
                ),
                const SizedBox(width: 8),
                Text(
                  'Location access is disabled.',
                  style: TextStyle(
                    fontSize: 12.5,
                    color: p.text,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            PressableScale(
              enabled: !requestInProgress,
              child: OutlinedButton.icon(
                key: const Key('enable-location-button'),
                onPressed: requestInProgress ? null : onEnableLocation,
                icon: requestInProgress
                    ? SizedBox(
                        width: 13,
                        height: 13,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: p.amber,
                        ),
                      )
                    : const Icon(Icons.my_location, size: 15),
                label: const Text('ENABLE LOCATION'),
                style: OutlinedButton.styleFrom(
                  backgroundColor: p.dark ? p.surface : Colors.transparent,
                  foregroundColor: p.amber,
                  side: BorderSide(color: p.amber),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
                  textStyle: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
