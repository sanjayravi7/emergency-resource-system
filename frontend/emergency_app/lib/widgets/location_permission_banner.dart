import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

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
    return Container(
      key: const Key('location-permission-disabled-banner'),
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.amberDim,
        border: Border.all(color: AppColors.amber.withValues(alpha: .35)),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 14,
        runSpacing: 8,
        children: [
          const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.location_off_outlined,
                size: 18,
                color: AppColors.amber,
              ),
              SizedBox(width: 8),
              Text(
                'Location access is disabled.',
                style: TextStyle(
                  fontSize: 12.5,
                  color: AppColors.text,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          OutlinedButton.icon(
            key: const Key('enable-location-button'),
            onPressed: requestInProgress ? null : onEnableLocation,
            icon: requestInProgress
                ? const SizedBox(
                    width: 13,
                    height: 13,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.my_location, size: 15),
            label: const Text('ENABLE LOCATION'),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.amber,
              side: const BorderSide(color: AppColors.amber),
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
              textStyle: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
