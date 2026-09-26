import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../models/eras_models.dart';
import '../services/location_service.dart';
import '../theme/app_theme.dart';
import 'common_widgets.dart';

/// Requester location workflow:
///
///   GPS -> reverse geocode -> place text filled automatically
///   or
///   search -> Google place prediction -> label + exact coordinates
///   or (web only)
///   tap the preview map -> reverse geocode the tapped point
///
/// latitude/longitude always remain the canonical location; the place text is
/// only the human readable label for those coordinates.
class RequesterLocationPicker extends StatefulWidget {
  const RequesterLocationPicker({
    super.key,
    required this.placeController,
    required this.latitude,
    required this.longitude,
    required this.locationService,
    required this.onUseCurrentLocation,
    required this.onLocationChanged,
    this.onPlaceTextChanged,
    this.enabled = true,
    this.showMapPreview = kIsWeb,
    this.searchDebounce = const Duration(milliseconds: 350),
  });

  final TextEditingController placeController;
  final double? latitude;
  final double? longitude;
  final LocationService locationService;

  /// Reads the browser/device GPS. Returns null when unavailable/denied.
  final Future<GeoPoint?> Function() onUseCurrentLocation;

  /// Emits the canonical coordinates (null clears them).
  final void Function(double? latitude, double? longitude) onLocationChanged;

  /// Called whenever the human readable place text is edited by the user.
  final VoidCallback? onPlaceTextChanged;

  final bool enabled;
  final bool showMapPreview;
  final Duration searchDebounce;

  @override
  State<RequesterLocationPicker> createState() =>
      _RequesterLocationPickerState();
}

class _RequesterLocationPickerState extends State<RequesterLocationPicker> {
  final TextEditingController _searchController = TextEditingController();

  Timer? _debounce;
  int _searchToken = 0;
  bool _locating = false;
  bool _searching = false;
  bool _resolving = false;
  List<PlacePrediction> _predictions = const <PlacePrediction>[];
  String? _statusMessage;
  bool _statusIsError = false;
  GoogleMapController? _previewController;

  bool get _hasCoordinates => widget.latitude != null && widget.longitude != null;

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    _previewController?.dispose();
    super.dispose();
  }

  void _setStatus(String? message, {bool isError = false}) {
    if (!mounted) return;
    setState(() {
      _statusMessage = message;
      _statusIsError = isError;
    });
  }

  // ------------------------------------------------------------------
  // 1. Use my current location
  // ------------------------------------------------------------------
  Future<void> useCurrentLocation() async {
    setState(() {
      _locating = true;
      _statusMessage = 'Requesting location permission…';
      _statusIsError = false;
      _predictions = const <PlacePrediction>[];
    });

    final point = await widget.onUseCurrentLocation();

    if (!mounted) return;

    if (point == null) {
      setState(() {
        _locating = false;
        _statusMessage =
            'Location permission denied or GPS unavailable. Search for a nearby '
            'place instead.';
        _statusIsError = true;
      });
      return;
    }

    // Coordinates are stored immediately - before reverse geocoding - so they
    // are never lost when Google cannot name the place.
    widget.onLocationChanged(point.latitude, point.longitude);
    setState(() => _statusMessage = 'Using current location…');

    await _reverseGeocodeInto(point, successMessage: 'Location detected ✓');
    await _movePreviewCamera(point.latitude, point.longitude);

    if (mounted) setState(() => _locating = false);
  }

  Future<void> _reverseGeocodeInto(
    GeoPoint point, {
    required String successMessage,
  }) async {
    try {
      final place =
          await widget.locationService.reverseGeocode(point.latitude, point.longitude);
      if (!mounted) return;
      widget.placeController.text = place.label;
      widget.onPlaceTextChanged?.call();
      _setStatus(successMessage);
    } on LocationServiceException catch (error) {
      if (!mounted) return;
      // Coordinates are kept, the place field stays editable and nothing is
      // fabricated.
      _setStatus(
        'Location detected, but place name could not be determined. Please '
        'enter a nearby place. (${error.message})',
        isError: true,
      );
    } catch (error) {
      if (!mounted) return;
      _setStatus(
        'Location detected, but place name could not be determined. Please '
        'enter a nearby place.',
        isError: true,
      );
    }
  }

  // ------------------------------------------------------------------
  // 2. Nearby place search (Google Places autocomplete, location biased)
  // ------------------------------------------------------------------
  void _onSearchChanged(String value) {
    _debounce?.cancel();
    final query = value.trim();

    if (query.length < 2) {
      setState(() {
        _predictions = const <PlacePrediction>[];
        _searching = false;
      });
      return;
    }

    _debounce = Timer(widget.searchDebounce, () => _runSearch(query));
  }

  Future<void> _runSearch(String query) async {
    final token = ++_searchToken;
    setState(() => _searching = true);

    try {
      final results = await widget.locationService.autocomplete(
        query,
        // Nearby bias: the requester's own coordinates when known.
        bias: _hasCoordinates
            ? GeoPoint(widget.latitude!, widget.longitude!)
            : null,
      );

      if (!mounted || token != _searchToken) return;
      setState(() {
        _predictions = results;
        _searching = false;
        if (results.isEmpty) {
          _statusMessage = 'No places matched "$query".';
          _statusIsError = false;
        }
      });
    } on LocationServiceException catch (error) {
      if (!mounted || token != _searchToken) return;
      setState(() {
        _predictions = const <PlacePrediction>[];
        _searching = false;
        _statusMessage = 'Place search unavailable: ${error.message}';
        _statusIsError = true;
      });
    } catch (error) {
      if (!mounted || token != _searchToken) return;
      setState(() {
        _predictions = const <PlacePrediction>[];
        _searching = false;
        _statusMessage = 'Place search failed. Please try again.';
        _statusIsError = true;
      });
    }
  }

  Future<void> selectPrediction(PlacePrediction prediction) async {
    setState(() {
      _resolving = true;
      _predictions = const <PlacePrediction>[];
      _statusMessage = 'Resolving ${prediction.primaryText}…';
      _statusIsError = false;
    });

    try {
      final place = await widget.locationService.resolvePrediction(prediction);
      if (!mounted) return;

      // Both the label AND the canonical coordinates come from Google.
      widget.placeController.text = place.label;
      widget.onLocationChanged(place.latitude, place.longitude);
      widget.onPlaceTextChanged?.call();
      _searchController.clear();

      setState(() {
        _resolving = false;
        _statusMessage = 'Selected: ${place.label}';
        _statusIsError = false;
      });

      await _movePreviewCamera(place.latitude, place.longitude);
    } on LocationServiceException catch (error) {
      if (!mounted) return;
      setState(() {
        _resolving = false;
        _statusMessage =
            'Could not resolve that place: ${error.message}. Coordinates were '
            'left unchanged.';
        _statusIsError = true;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _resolving = false;
        _statusMessage = 'Could not resolve that place. Please try again.';
        _statusIsError = true;
      });
    }
  }

  // ------------------------------------------------------------------
  // 3. Optional map pin selection
  // ------------------------------------------------------------------
  Future<void> handleMapTap(LatLng position) async {
    widget.onLocationChanged(position.latitude, position.longitude);
    _setStatus('Using selected map point…');
    await _movePreviewCamera(position.latitude, position.longitude);
    await _reverseGeocodeInto(
      GeoPoint(position.latitude, position.longitude),
      successMessage: 'Map point selected ✓',
    );
  }

  Future<void> _movePreviewCamera(double latitude, double longitude) async {
    final controller = _previewController;
    if (controller == null) return;
    await controller.animateCamera(
      CameraUpdate.newLatLngZoom(LatLng(latitude, longitude), 16),
    );
  }

  void clearLocation() {
    widget.onLocationChanged(null, null);
    widget.placeController.clear();
    widget.onPlaceTextChanged?.call();
    _searchController.clear();
    setState(() {
      _predictions = const <PlacePrediction>[];
      _statusMessage = 'Location cleared.';
      _statusIsError = false;
    });
  }

  // ------------------------------------------------------------------
  // UI
  // ------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    final enabled = widget.enabled && !_locating && !_resolving;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const FieldLabel('Place / location'),
        const SizedBox(height: 6),
        TextField(
          key: const Key('location-search-field'),
          controller: _searchController,
          enabled: enabled,
          style: const TextStyle(fontSize: 13),
          decoration: fieldDecoration(
            hintText: 'Search for a place, landmark, address…',
          ).copyWith(
            prefixIcon: const Icon(Icons.search, size: 18, color: AppColors.textFaint),
            suffixIcon: _searching
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : null,
          ),
          onChanged: _onSearchChanged,
          onSubmitted: (value) {
            _debounce?.cancel();
            if (value.trim().length >= 2) {
              unawaited(_runSearch(value.trim()));
            }
          },
        ),
        if (_predictions.isNotEmpty) ...[
          const SizedBox(height: 6),
          _predictionList(),
        ],
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              key: const Key('use-current-location-button'),
              onPressed: enabled ? () => unawaited(useCurrentLocation()) : null,
              icon: _locating
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.my_location_rounded, size: 16),
              label: Text(_locating ? 'Locating…' : 'Use my current location'),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.blue,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                textStyle: const TextStyle(fontSize: 12.5),
              ),
            ),
            if (_hasCoordinates)
              OutlinedButton.icon(
                key: const Key('clear-location-button'),
                onPressed: enabled ? clearLocation : null,
                icon: const Icon(Icons.clear, size: 16),
                label: const Text('Clear location'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.textDim,
                  side: const BorderSide(color: AppColors.border),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  textStyle: const TextStyle(fontSize: 12.5),
                ),
              ),
          ],
        ),
        const SizedBox(height: 10),
        const FieldLabel('Place'),
        const SizedBox(height: 6),
        TextField(
          key: const Key('location-place-field'),
          controller: widget.placeController,
          enabled: widget.enabled,
          minLines: 1,
          maxLines: 2,
          style: const TextStyle(fontSize: 13),
          decoration: fieldDecoration(
            hintText: 'Human readable place, e.g. Kolenchery, Kerala',
          ),
          onChanged: (_) => widget.onPlaceTextChanged?.call(),
        ),
        const SizedBox(height: 8),
        _coordinateBox(),
        if (_statusMessage != null) ...[
          const SizedBox(height: 6),
          Text(
            _statusMessage!,
            key: const Key('location-status-text'),
            style: TextStyle(
              fontSize: 11.5,
              height: 1.35,
              color: _statusIsError ? AppColors.amber : AppColors.teal,
            ),
          ),
        ],
        if (widget.showMapPreview && _hasCoordinates) ...[
          const SizedBox(height: 10),
          _mapPreview(),
        ],
      ],
    );
  }

  Widget _predictionList() {
    return Container(
      key: const Key('location-prediction-list'),
      decoration: BoxDecoration(
        color: AppColors.surface2,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        children: [
          for (final prediction in _predictions)
            InkWell(
              key: Key('prediction-${prediction.placeId}'),
              onTap: widget.enabled
                  ? () => unawaited(selectPrediction(prediction))
                  : null,
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Row(
                  children: [
                    const Icon(Icons.place_outlined,
                        size: 16, color: AppColors.textFaint),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            prediction.primaryText,
                            style: const TextStyle(
                                fontSize: 12.5, color: AppColors.text),
                          ),
                          if (prediction.secondaryText.isNotEmpty)
                            Text(
                              prediction.secondaryText,
                              style: const TextStyle(
                                  fontSize: 11, color: AppColors.textFaint),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _coordinateBox() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
        color: _hasCoordinates ? AppColors.tealDim : AppColors.surface2,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(
          color: _hasCoordinates
              ? AppColors.teal.withValues(alpha: .35)
              : AppColors.border,
        ),
      ),
      child: Text(
        _hasCoordinates
            ? 'Coordinates: ${formatCoordinatePair(widget.latitude!, widget.longitude!)}'
            : 'No coordinates yet. Use your current location or pick a place from search.',
        key: const Key('location-coordinates-text'),
        style: TextStyle(
          fontSize: 11.5,
          height: 1.35,
          color: _hasCoordinates ? AppColors.teal : AppColors.textFaint,
        ),
      ),
    );
  }

  Widget _mapPreview() {
    final target = LatLng(widget.latitude!, widget.longitude!);

    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: SizedBox(
        height: 190,
        child: GoogleMap(
          initialCameraPosition: CameraPosition(target: target, zoom: 16),
          markers: <Marker>{
            Marker(
              markerId: const MarkerId('requester-selected-location'),
              position: target,
              infoWindow: InfoWindow(
                title: widget.placeController.text.isEmpty
                    ? 'Selected location'
                    : widget.placeController.text,
                snippet: formatCoordinatePair(target.latitude, target.longitude),
              ),
            ),
          },
          onMapCreated: (controller) => _previewController = controller,
          onTap: widget.enabled ? (p) => unawaited(handleMapTap(p)) : null,
          mapToolbarEnabled: false,
          myLocationButtonEnabled: false,
          zoomControlsEnabled: false,
        ),
      ),
    );
  }
}
