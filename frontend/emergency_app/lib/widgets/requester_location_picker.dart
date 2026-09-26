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
///   A. GPS -> reverse geocode -> place text filled automatically
///   B. search -> Google place prediction -> label + exact coordinates
///   C. nearby -> Google Places API (New) Nearby Search around the GPS
///      coordinates -> requester taps a real hospital / police station /
///      school / … -> its own name + exact coordinates become the location
///   D. (web only) tap the preview map -> reverse geocode the tapped point
///
/// Autocomplete (B) and Nearby Search (C) are deliberately separate features:
/// autocomplete answers "find this named place anywhere (biased near me)",
/// Nearby Search answers "which real places of this category are around me
/// right now".
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

  // Nearby places (Google Places API (New) Nearby Search).
  NearbyPlaceCategory? _nearbyCategory;
  bool _nearbyLoading = false;
  bool _nearbyUnavailable = false;
  List<NearbyPlace> _nearbyResults = const <NearbyPlace>[];
  GeoPoint? _nearbyCenter;
  String? _nearbyStatusMessage;
  int _nearbyToken = 0;

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

    // The requester's own location (re)appeared: refresh the nearby list
    // around it, but only when a category was already chosen (one request per
    // explicit action, never from responder Socket.IO updates).
    if (_nearbyCategory != null) {
      await _refreshNearbyPlaces(center: point);
    }

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
  // 2. Manual place search (Google Places autocomplete, location biased)
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

      // The requester's location changed to the selected place: re-query the
      // nearby list around the new center (only when a category is active).
      if (_nearbyCategory != null) {
        await _refreshNearbyPlaces(center: place.point);
      }
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
  // 3. Nearby places (Google Places API (New) Nearby Search)
  // ------------------------------------------------------------------
  /// Runs one Nearby Search (New) around [center] (the requester's current
  /// coordinates) for [category] — or the already selected category when
  /// [category] is null (the Refresh button).
  ///
  /// Call policy, kept deliberately restrictive to avoid excessive API
  /// requests — Nearby Search runs only when:
  ///   * the requester's current location is obtained,
  ///   * the requester selects/re-selects a category or taps Refresh,
  ///   * the requester changes location (map tap, searched place, nearby
  ///     place selection).
  /// It is never triggered by responder Socket.IO location updates or by
  /// typing in the search field.
  Future<void> _refreshNearbyPlaces({
    NearbyPlaceCategory? category,
    GeoPoint? center,
  }) async {
    final selected = category ?? _nearbyCategory;
    if (selected == null) return;

    final origin = center ??
        (widget.latitude != null && widget.longitude != null
            ? GeoPoint(widget.latitude!, widget.longitude!)
            : null);
    if (origin == null) return;

    // May be reached after awaits (e.g. from useCurrentLocation), so the
    // widget could have been disposed in the meantime.
    if (!mounted) return;

    final token = ++_nearbyToken;

    setState(() {
      _nearbyCategory = selected;
      _nearbyLoading = true;
      _nearbyUnavailable = false;
      _nearbyStatusMessage = null;
    });

    try {
      final results = await widget.locationService.searchNearbyPlaces(
        latitude: origin.latitude,
        longitude: origin.longitude,
        category: selected,
      );

      if (!mounted || token != _nearbyToken) return;
      setState(() {
        _nearbyLoading = false;
        _nearbyResults = results;
        _nearbyCenter = origin;
        _nearbyStatusMessage = results.isEmpty
            ? 'No ${selected.pluralLabel.toLowerCase()} found within '
                '${_radiusKilometersLabel()} of the current location. Try '
                'another category or search by name.'
            : null;
      });
    } on PlacesApiDisabledException {
      // Places API (New) disabled/not enabled: degrade gracefully. The map,
      // GPS and reverse geocoding use other APIs and keep working.
      if (!mounted || token != _nearbyToken) return;
      setState(() {
        _nearbyLoading = false;
        _nearbyUnavailable = true;
        _nearbyResults = const <NearbyPlace>[];
        _nearbyCenter = null;
      });
    } on LocationServiceException catch (error) {
      if (!mounted || token != _nearbyToken) return;
      setState(() {
        _nearbyLoading = false;
        _nearbyResults = const <NearbyPlace>[];
        _nearbyCenter = null;
        _nearbyStatusMessage = 'Nearby places unavailable: ${error.message}';
      });
    } catch (error) {
      if (!mounted || token != _nearbyToken) return;
      setState(() {
        _nearbyLoading = false;
        _nearbyResults = const <NearbyPlace>[];
        _nearbyCenter = null;
        _nearbyStatusMessage =
            'Nearby places failed to load. Tap Refresh to retry.';
      });
    }
  }

  /// The requester picks (or re-picks, = refresh) a nearby category chip.
  Future<void> selectNearbyCategory(NearbyPlaceCategory category) =>
      _refreshNearbyPlaces(category: category);

  /// The requester taps a nearby result: that real Google place becomes the
  /// request location. Its own name/address becomes the place label and its
  /// own coordinates become the canonical latitude/longitude — the search
  /// text is never used as a coordinate source. The preview marker and
  /// camera follow the new coordinates, so the request can be submitted.
  Future<void> selectNearbyPlace(NearbyPlace place) async {
    widget.placeController.text = place.label;
    widget.onLocationChanged(place.latitude, place.longitude);
    widget.onPlaceTextChanged?.call();

    _setStatus('Selected: ${place.name}');
    await _movePreviewCamera(place.latitude, place.longitude);

    // The location changed to the selected place: re-query the nearby list
    // around it so the distances stay truthful (only when a category is
    // active; one request per explicit tap).
    if (_nearbyCategory != null) {
      await _refreshNearbyPlaces(center: place.point);
    }
  }

  String _radiusKilometersLabel() =>
      '${(kNearbySearchRadiusMeters / 1000).round()} km';

  // ------------------------------------------------------------------
  // 4. Optional map pin selection
  // ------------------------------------------------------------------
  Future<void> handleMapTap(LatLng position) async {
    widget.onLocationChanged(position.latitude, position.longitude);
    _setStatus('Using selected map point…');
    await _movePreviewCamera(position.latitude, position.longitude);
    await _reverseGeocodeInto(
      GeoPoint(position.latitude, position.longitude),
      successMessage: 'Map point selected ✓',
    );

    // The requester changed the location by tapping the map: re-query the
    // nearby list around the new point (only when a category is active).
    if (_nearbyCategory != null) {
      await _refreshNearbyPlaces(
        center: GeoPoint(position.latitude, position.longitude),
      );
    }
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
    _nearbyToken++; // drop any in-flight nearby request
    setState(() {
      _predictions = const <PlacePrediction>[];
      _statusMessage = 'Location cleared.';
      _statusIsError = false;
      _nearbyResults = const <NearbyPlace>[];
      _nearbyCenter = null;
      _nearbyStatusMessage = null;
      _nearbyUnavailable = false;
      // The selected category is kept: re-detecting the current location
      // re-queries it around the new GPS position.
    });
  }

  // ------------------------------------------------------------------
  // 5. UI
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
        if (_hasCoordinates) ...[
          const SizedBox(height: 12),
          _nearbyPlacesSection(),
        ],
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

  // ------------------------------------------------------------------
  // Nearby places UI (shown once coordinates exist)
  // ------------------------------------------------------------------
  Widget _nearbyPlacesSection() {
    return Container(
      key: const Key('nearby-places-section'),
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface2,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.near_me_rounded,
                  size: 14, color: AppColors.teal),
              const SizedBox(width: 7),
              const Expanded(
                child: Text(
                  'NEARBY PLACES',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    letterSpacing: .8,
                    color: AppColors.textDim,
                  ),
                ),
              ),
              _nearbyRefreshButton(),
            ],
          ),
          const SizedBox(height: 5),
          const Text(
            'Real places around your current coordinates '
            '(Google Places API (New) Nearby Search, ranked by distance).',
            style: TextStyle(
                fontSize: 10.5, color: AppColors.textFaint, height: 1.35),
          ),
          const SizedBox(height: 9),
          if (_nearbyUnavailable)
            Container(
              key: const Key('nearby-unavailable-text'),
              width: double.infinity,
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
              decoration: BoxDecoration(
                color: AppColors.amberDim,
                borderRadius: BorderRadius.circular(5),
                border: Border.all(
                  color: AppColors.amber.withValues(alpha: .35),
                ),
              ),
              child: const Text(
                PlacesApiDisabledException.userMessage,
                style: TextStyle(
                  fontSize: 11.5,
                  height: 1.35,
                  color: AppColors.amber,
                ),
              ),
            )
          else ...[
            _nearbyCategoryChips(),
            if (_nearbyStatusMessage != null) ...[
              const SizedBox(height: 7),
              Text(
                _nearbyStatusMessage!,
                key: const Key('nearby-status-text'),
                style: const TextStyle(
                  fontSize: 11.5,
                  height: 1.35,
                  color: AppColors.amber,
                ),
              ),
            ],
            if (_nearbyLoading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 10),
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            if (_nearbyResults.isNotEmpty) _nearbyResultsList(),
          ],
        ],
      ),
    );
  }

  Widget _nearbyRefreshButton() {
    final canRefresh =
        widget.enabled && !_nearbyLoading && _nearbyCategory != null;

    return OutlinedButton.icon(
      key: const Key('nearby-refresh-button'),
      onPressed: canRefresh ? () => unawaited(_refreshNearbyPlaces()) : null,
      icon: _nearbyLoading
          ? const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.refresh, size: 14),
      label: const Text('Refresh'),
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.teal,
        side: const BorderSide(color: AppColors.border),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        textStyle: const TextStyle(fontSize: 11),
      ),
    );
  }

  Widget _nearbyCategoryChips() {
    final enabled = widget.enabled && !_nearbyLoading;

    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final category in NearbyPlaceCategory.values)
          ChoiceChip(
            key: Key('nearby-category-${category.name}'),
            label: Text(category.label),
            selected: _nearbyCategory == category,
            onSelected: enabled
                ? (_) => unawaited(selectNearbyCategory(category))
                : null,
            showCheckmark: false,
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            backgroundColor: AppColors.surface,
            selectedColor: AppColors.tealDim,
            side: BorderSide(
              color: _nearbyCategory == category
                  ? AppColors.teal.withValues(alpha: .4)
                  : AppColors.border,
            ),
            labelStyle: TextStyle(
              fontSize: 11.5,
              color: _nearbyCategory == category
                  ? AppColors.teal
                  : AppColors.textDim,
              fontWeight: _nearbyCategory == category
                  ? FontWeight.w600
                  : FontWeight.w400,
            ),
          ),
      ],
    );
  }

  Widget _nearbyResultsList() {
    final category = _nearbyCategory;
    if (category == null) return const SizedBox.shrink();

    final center = _nearbyCenter ??
        GeoPoint(widget.latitude!, widget.longitude!);
    final centerText =
        formatCoordinatePair(center.latitude, center.longitude);

    return Container(
      key: const Key('nearby-result-list'),
      margin: const EdgeInsets.only(top: 9),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border.all(color: AppColors.border),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 9, 12, 7),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  category.pluralLabel,
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: AppColors.text,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Within ${_radiusKilometersLabel()} of $centerText · '
                  'ranked by distance',
                  style: const TextStyle(
                      fontSize: 10.5, color: AppColors.textFaint),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: AppColors.border),
          for (var index = 0; index < _nearbyResults.length; index++) ...[
            if (index > 0) const Divider(height: 1, color: AppColors.border),
            _nearbyResultRow(_nearbyResults[index]),
          ],
        ],
      ),
    );
  }

  Widget _nearbyResultRow(NearbyPlace place) {
    return InkWell(
      key: Key('nearby-result-${place.placeId}'),
      onTap: widget.enabled
          ? () => unawaited(selectNearbyPlace(place))
          : null,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.place_outlined,
                size: 15, color: AppColors.textFaint),
            const SizedBox(width: 9),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    place.name,
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w600,
                      color: AppColors.text,
                    ),
                  ),
                  if (place.address.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        place.address,
                        style: const TextStyle(
                          fontSize: 11,
                          height: 1.3,
                          color: AppColors.textFaint,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            if (place.distanceLabel.isNotEmpty) ...[
              const SizedBox(width: 8),
              Text(
                place.distanceLabel,
                style: monoStyle(
                  size: 11,
                  color: AppColors.teal,
                  weight: FontWeight.w600,
                ),
              ),
            ],
          ],
        ),
      ),
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
