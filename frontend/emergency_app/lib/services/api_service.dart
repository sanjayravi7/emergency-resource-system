import 'dart:convert';
import 'package:http/http.dart' as http;

/// Thin HTTP data layer for the ERAS backend.
///
/// Every HTTP mutation still goes through this class. Socket.IO push events
/// call the same reload methods without becoming a second lifecycle state
/// machine.
class ApiService {
  /// Override for a native simulator when needed:
  ///   flutter run --dart-define=ERAS_API_BASE_URL=http://10.0.2.2:5000/api
  /// Web builds use the same-origin API by default so the browser never calls
  /// a sandbox-localhost address.
  static const String baseUrl = String.fromEnvironment(
    'ERAS_API_BASE_URL',
    defaultValue: '/api',
  );

  static String? token;
  static String? currentRole;
  static String? currentUserName;
  static String? currentUserEmail;

  static int? currentUserId;

  /// Server-reported email verification state for the signed-in account.
  ///
  /// `null` means "not reported by this endpoint" (older backend or a session
  /// restored without a payload); Google accounts are always verified by
  /// Google, so `null` is treated as "no verification gate" by the UI.
  static bool? emailVerified;

  static bool get isRequester => currentRole == 'REQUESTER';
  static bool get isResponder => currentRole == 'RESPONDER';
  static bool get isAdmin => currentRole == 'ADMIN';

  static Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      };

  static Map<String, dynamic> _decode(http.Response response) {
    if (response.body.isEmpty) {
      return <String, dynamic>{};
    }

    final decoded = jsonDecode(response.body);

    if (decoded is Map<String, dynamic>) {
      return decoded;
    }

    return <String, dynamic>{'data': decoded};
  }

  static Never _fail(Map<String, dynamic> body, String fallback) {
    throw Exception(body['message']?.toString() ?? fallback);
  }

  // ---------------------------------------------------------------------
  // AUTH
  // ---------------------------------------------------------------------

  /// Public registration. The chosen role ('REQUESTER' or 'RESPONDER') is
  /// stored on the User record by the backend - it is never a client-only
  /// preference. The server validates the role and refuses to create ADMIN or
  /// any other value; public signup can only produce the two public roles.
  static Future<Map<String, dynamic>> register({
    required String name,
    required String email,
    required String password,
    required String role,
    String? phone,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/auth/register'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'name': name,
        'email': email,
        'password': password,
        'role': role,
        if (phone != null && phone.trim().isNotEmpty) 'phone': phone.trim(),
      }),
    );
    final body = _decode(response);
    if (response.statusCode != 201) {
      _fail(body, 'Registration failed');
    }
    return body;
  }

  static Future<Map<String, dynamic>> login(
    String email,
    String password,
  ) async {
    final response = await http.post(
      Uri.parse('$baseUrl/auth/login'),
      headers: {
        'Content-Type': 'application/json',
      },
      body: jsonEncode({
        'email': email,
        'password': password,
      }),
    );

    final body = _decode(response);

    if (response.statusCode != 200) {
      _fail(body, 'Login failed');
    }

    applySession(body);
    return body;
  }

  /// Stores the ERAS session carried by an auth response.
  ///
  /// Shared by password login and Google sign-in so both paths always populate
  /// exactly the same fields (token, role, name, id and the verification
  /// state). The server remains the role authority; this only mirrors it.
  static void applySession(Map<String, dynamic> body) {
    final data = body['data'];
    if (data is! Map) return;

    final user = data['user'];
    if (user is! Map) return;

    token = data['token']?.toString() ?? token;
    currentUserId = user['id'] is num ? (user['id'] as num).toInt() : null;
    currentRole = user['role']?.toString();
    currentUserName = user['name']?.toString();
    currentUserEmail = user['email']?.toString();
    emailVerified =
        user['emailVerified'] is bool ? user['emailVerified'] as bool : null;
  }

  /// Google sign-in through the EXISTING Firebase project.
  ///
  /// The Flutter side only obtains the Firebase ID token; the backend verifies
  /// it against Google's published certificates, resolves/links the ERAS user
  /// and returns the normal ERAS JWT. A client can therefore never grant
  /// itself ADMIN: the role always comes from PostgreSQL.
  static Future<Map<String, dynamic>> googleSignIn({
    required String idToken,
    String? role,
    String? name,
    String? phone,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/auth/google'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'idToken': idToken,
        if (role != null && role.isNotEmpty) 'role': role,
        if (name != null && name.trim().isNotEmpty) 'name': name.trim(),
        if (phone != null && phone.trim().isNotEmpty) 'phone': phone.trim(),
      }),
    );
    final body = _decode(response);
    if (response.statusCode != 200) {
      _fail(body, 'Google sign-in failed');
    }
    applySession(body);
    return body;
  }

  /// Re-reads the authoritative session record (used to refresh the email
  /// verification state without signing the user out).
  static Future<Map<String, dynamic>> fetchMe() async {
    final response = await http.get(
      Uri.parse('$baseUrl/auth/me'),
      headers: _headers,
    );
    final body = _decode(response);
    if (response.statusCode != 200) {
      _fail(body, 'Could not refresh the account state');
    }
    final user = body['data'];
    if (user is Map) {
      if (user['emailVerified'] is bool) {
        emailVerified = user['emailVerified'] as bool;
      }
      if (user['email'] != null) currentUserEmail = user['email'].toString();
    }
    return body;
  }

  /// Confirms the 6-digit code sent to the signed-in account's email.
  static Future<Map<String, dynamic>> verifyEmail(String code) async {
    final response = await http.post(
      Uri.parse('$baseUrl/auth/verify-email'),
      headers: _headers,
      body: jsonEncode({'code': code.trim()}),
    );
    final body = _decode(response);
    if (response.statusCode != 200) {
      _fail(body, 'Verification failed');
    }
    emailVerified = true;
    return body;
  }

  /// Requests a fresh verification code. Public (works before signing in) and
  /// answers generically, so it can never be used to discover which addresses
  /// have ERAS accounts.
  static Future<Map<String, dynamic>> resendVerification({
    String? email,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/auth/resend-verification'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        if (email != null && email.trim().isNotEmpty) 'email': email.trim(),
        if (token != null) 'token': token,
      }),
    );
    final body = _decode(response);
    if (response.statusCode != 200) {
      _fail(body, 'Could not send a verification email');
    }
    return body;
  }

  /// Step 1 of the forgot-password flow: request a 6-digit code by email.
  static Future<Map<String, dynamic>> requestPasswordReset(String email) async {
    final response = await http.post(
      Uri.parse('$baseUrl/auth/password/forgot'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'email': email.trim()}),
    );
    final body = _decode(response);
    if (response.statusCode != 200) {
      _fail(body, 'Could not start the password reset');
    }
    return body;
  }

  /// Step 2: verify the 6-digit code WITHOUT consuming it, so the user can go
  /// on to choose a new password. A wrong or expired code never reveals
  /// whether the address exists.
  static Future<Map<String, dynamic>> verifyPasswordResetCode({
    required String email,
    required String code,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/auth/password/verify-code'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'email': email.trim(), 'code': code.trim()}),
    );
    final body = _decode(response);
    if (response.statusCode != 200) {
      _fail(body, 'Invalid or expired code');
    }
    return body;
  }

  /// Step 3: set the new password. The backend consumes the code, hashes the
  /// password with the existing bcrypt policy and invalidates old sessions.
  static Future<Map<String, dynamic>> resetPassword({
    required String email,
    required String code,
    required String password,
    required String confirmPassword,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/auth/password/reset'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'email': email.trim(),
        'code': code.trim(),
        'password': password,
        'confirmPassword': confirmPassword,
      }),
    );
    final body = _decode(response);
    if (response.statusCode != 200) {
      _fail(body, 'Could not reset the password');
    }
    return body;
  }

  /// Mark a responder offline before clearing the local session. A failed
  /// network call must never strand the UI, so local credentials are cleared
  /// in all cases and no emergency/allocation is altered by logout.
  static Future<void> logout() async {
    try {
      if (isResponder && token != null) {
        await http.post(
          Uri.parse('$baseUrl/responders/logout'),
          headers: _headers,
        );
      }
    } finally {
      token = null;
      currentRole = null;
      currentUserId = null;
      currentUserName = null;
      currentUserEmail = null;
      emailVerified = null;
    }
  }

  /// ADMIN-only removal of an after-action log entry.
  ///
  /// The server archives the operational row (it is never destroyed) and writes
  /// a separate `ADMIN_DELETED_LOG` security audit record. The explicit
  /// `confirm: true` body is required by the endpoint, so an accidental call
  /// without a user confirmation cannot delete anything.
  static Future<Map<String, dynamic>> deleteAdminLog(int requestId) async {
    final response = await http.delete(
      Uri.parse('$baseUrl/admin/logs/$requestId'),
      headers: _headers,
      body: jsonEncode(<String, dynamic>{'confirm': true}),
    );
    final body = _decode(response);
    if (response.statusCode != 200) {
      _fail(body, 'Failed to delete the log entry');
    }
    return body;
  }

  // ---------------------------------------------------------------------
  // LOCATION
  // ---------------------------------------------------------------------

  /// Reverse geocodes only an explicitly selected requester location. The
  /// backend owns the Photon call so no browser geocoding key is required.
  static Future<Map<String, dynamic>> reverseGeocode({
    required double latitude,
    required double longitude,
  }) async {
    final response = await http.get(
      Uri.parse('$baseUrl/location/reverse').replace(queryParameters: {
        'latitude': latitude.toString(),
        'longitude': longitude.toString(),
      }),
      headers: _headers,
    );
    final body = _decode(response);
    if (response.statusCode != 200) {
      _fail(body, 'Could not determine an address for these coordinates');
    }
    final data = body['data'];
    if (data is! Map) _fail(body, 'Invalid reverse geocoding response');
    return Map<String, dynamic>.from(data);
  }

  // ---------------------------------------------------------------------
  // EMERGENCY REQUESTS
  // ---------------------------------------------------------------------

  static Map<String, dynamic> _requestPayload({
    required String emergencyType,
    required String? description,
    required String location,
    required String priority,
    required double? latitude,
    required double? longitude,
    required List<Map<String, int>> requiredResources,
  }) {
    final normalizedDescription =
        description == null || description.trim().isEmpty ? null : description;
    return <String, dynamic>{
      'emergencyType': emergencyType,
      // Include null when editing so a requester can deliberately clear an
      // existing optional description.
      'description': normalizedDescription,
      'location': location,
      'priority': priority,
      // A missing precise fix remains null. ERAS never substitutes 0,0.
      'latitude': latitude,
      'longitude': longitude,
      'requiredResources': requiredResources,
    };
  }

  static Future<Map<String, dynamic>> createRequest({
    required String emergencyType,
    required String? description,
    required String location,
    required String priority,
    required double? latitude,
    required double? longitude,
    required List<Map<String, int>> requiredResources,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/requests'),
      headers: _headers,
      body: jsonEncode(_requestPayload(
        emergencyType: emergencyType,
        description: description,
        location: location,
        priority: priority,
        latitude: latitude,
        longitude: longitude,
        requiredResources: requiredResources,
      )),
    );

    final body = _decode(response);

    if (response.statusCode != 201) {
      _fail(body, 'Failed to create request');
    }

    return body;
  }

  /// ADMIN creation uses the dedicated merged endpoint. The backend stores
  /// the new emergency as PENDING and remains the lifecycle authority.
  static Future<Map<String, dynamic>> createAdminRequest({
    required String emergencyType,
    required String? description,
    required String location,
    required String priority,
    required double? latitude,
    required double? longitude,
    required List<Map<String, int>> requiredResources,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/admin/requests'),
      headers: _headers,
      body: jsonEncode(_requestPayload(
        emergencyType: emergencyType,
        description: description,
        location: location,
        priority: priority,
        latitude: latitude,
        longitude: longitude,
        requiredResources: requiredResources,
      )),
    );
    final body = _decode(response);
    if (response.statusCode != 201) {
      _fail(body, 'Failed to create admin emergency');
    }
    return body;
  }

  /// REQUESTER PATCH of their own PENDING emergency. Button visibility is
  /// only a convenience; ownership and lifecycle are enforced by the server.
  static Future<Map<String, dynamic>> updateMyRequest({
    required int requestId,
    required String emergencyType,
    required String? description,
    required String location,
    required String priority,
    required double? latitude,
    required double? longitude,
    required List<Map<String, int>> requiredResources,
  }) async {
    final response = await http.patch(
      Uri.parse('$baseUrl/requests/$requestId'),
      headers: _headers,
      body: jsonEncode(_requestPayload(
        emergencyType: emergencyType,
        description: description,
        location: location,
        priority: priority,
        latitude: latitude,
        longitude: longitude,
        requiredResources: requiredResources,
      )),
    );
    final body = _decode(response);
    if (response.statusCode != 200) {
      _fail(body, 'Failed to update request');
    }
    return body;
  }

  static Future<List<dynamic>> getMyRequests() async {
    final response = await http.get(
      Uri.parse('$baseUrl/requests/my'),
      headers: _headers,
    );

    final body = _decode(response);

    if (response.statusCode != 200) {
      _fail(body, 'Failed to load requests');
    }

    return body['requests'] ?? [];
  }

  /// PENDING requests this responder is actually able to serve.
  static Future<List<dynamic>> getCompatibleRequests() async {
    final response = await http.get(
      Uri.parse('$baseUrl/requests/compatible'),
      headers: _headers,
    );

    final body = _decode(response);

    if (response.statusCode != 200) {
      _fail(body, 'Failed to load compatible requests');
    }

    return body['requests'] ?? [];
  }

  /// Requests this responder already accepted (their own workload).
  static Future<List<dynamic>> getAssignedRequests() async {
    final response = await http.get(
      Uri.parse('$baseUrl/requests/assigned'),
      headers: _headers,
    );

    final body = _decode(response);

    if (response.statusCode != 200) {
      _fail(body, 'Failed to load assigned requests');
    }

    return body['requests'] ?? [];
  }

  static Future<List<dynamic>> getAllRequests() async {
    final response = await http.get(
      Uri.parse('$baseUrl/requests'),
      headers: _headers,
    );

    final body = _decode(response);

    if (response.statusCode != 200) {
      _fail(body, 'Failed to load all requests');
    }

    return body['requests'] ?? [];
  }

  /// ADMIN view of every emergency request in PostgreSQL.
  static Future<List<dynamic>> getAdminRequests() async {
    final response = await http.get(
      Uri.parse('$baseUrl/admin/requests'),
      headers: _headers,
    );

    final body = _decode(response);

    if (response.statusCode != 200) {
      _fail(body, 'Failed to load requests');
    }

    return body['requests'] ?? [];
  }

  static Future<Map<String, dynamic>> acceptEmergencyRequest(
    int requestId,
  ) async {
    final response = await http.patch(
      Uri.parse('$baseUrl/requests/$requestId/accept'),
      headers: _headers,
    );

    final body = _decode(response);

    if (response.statusCode != 200) {
      _fail(body, 'Failed to accept emergency request');
    }

    return body;
  }

  /// ADMIN assigns the selected responder; the admin is never passed as the
  /// accepting identity. Compatibility is rechecked atomically by the backend.
  static Future<Map<String, dynamic>> assignAdminRequest({
    required int requestId,
    required int responderId,
  }) async {
    final response = await http.patch(
      Uri.parse('$baseUrl/admin/requests/$requestId/assign/$responderId'),
      headers: _headers,
    );
    final body = _decode(response);
    if (response.statusCode != 200) {
      _fail(body, 'Failed to assign responder');
    }
    return body;
  }

  static Future<Map<String, dynamic>> cancelAdminRequest(int requestId) async {
    final response = await http.patch(
      Uri.parse('$baseUrl/admin/requests/$requestId/cancel'),
      headers: _headers,
    );
    final body = _decode(response);
    if (response.statusCode != 200) {
      _fail(body, 'Failed to cancel admin request');
    }
    return body;
  }

  /// Responder starts active response for a resource-free emergency.
  static Future<Map<String, dynamic>> startEmergencyResponse(
    int requestId,
  ) async {
    final response = await http.post(
      Uri.parse('$baseUrl/requests/$requestId/start'),
      headers: _headers,
    );

    final body = _decode(response);

    if (response.statusCode != 200) {
      _fail(body, 'Failed to start emergency response');
    }

    return body;
  }

  /// Responder completes response for a resource-free emergency.
  static Future<Map<String, dynamic>> completeEmergencyResponse(
    int requestId,
  ) async {
    final response = await http.post(
      Uri.parse('$baseUrl/requests/$requestId/complete'),
      headers: _headers,
    );

    final body = _decode(response);

    if (response.statusCode != 200) {
      _fail(body, 'Failed to complete emergency response');
    }

    return body;
  }

  /// End only the signed-in responder's ACTIVE assignment. An unfinished own
  /// allocation remains on the board through the backend participation rule.
  static Future<Map<String, dynamic>> endMyAssignment(int requestId) async {
    final response = await http.patch(
      Uri.parse('$baseUrl/requests/$requestId/assignment/end'),
      headers: _headers,
    );
    final body = _decode(response);
    if (response.statusCode != 200) {
      _fail(body, 'Failed to end assignment');
    }
    return body;
  }

  /// Requester cancellation uses the merged DELETE contract. The backend
  /// changes status to CANCELLED; it never physically deletes operational
  /// history. Ownership and lifecycle checks remain server-side.
  static Future<Map<String, dynamic>> cancelMyRequest(int requestId) async {
    final response = await http.delete(
      Uri.parse('$baseUrl/requests/$requestId'),
      headers: _headers,
    );

    final body = _decode(response);

    if (response.statusCode != 200) {
      _fail(body, 'Failed to cancel request');
    }

    return body;
  }

  // ---------------------------------------------------------------------
  // RESOURCE CATALOG (PostgreSQL is the source of truth)
  // ---------------------------------------------------------------------

  static Future<List<dynamic>> getResources({
    bool includeInactive = false,
  }) async {
    final response = await http.get(
      Uri.parse(
        '$baseUrl/resources?includeInactive=${includeInactive ? 'true' : 'false'}',
      ),
      headers: _headers,
    );

    final body = _decode(response);

    if (response.statusCode != 200) {
      _fail(body, 'Failed to load resources');
    }

    return body['resources'] ?? [];
  }

  /// Live availability for every active resource. SERVICE resources come
  /// back with `availableResponders` (a responder count); CONSUMABLE
  /// resources come back with `availableQuantity` (real inventory). The UI
  /// never computes either number itself - PostgreSQL is the source of
  /// truth for both.
  static Future<List<dynamic>> getResourceAvailability() async {
    final response = await http.get(
      Uri.parse('$baseUrl/resources/availability'),
      headers: _headers,
    );

    final body = _decode(response);

    if (response.statusCode != 200) {
      _fail(body, 'Failed to load resource availability');
    }

    return body['resources'] ?? [];
  }

  static Future<List<dynamic>> getLowStockResources() async {
    final response = await http.get(
      Uri.parse('$baseUrl/resources/low-stock'),
      headers: _headers,
    );

    final body = _decode(response);

    if (response.statusCode != 200) {
      _fail(body, 'Failed to load low stock resources');
    }

    return body['resources'] ?? [];
  }

  static Future<Map<String, dynamic>> createResource(
    Map<String, dynamic> data,
  ) async {
    final response = await http.post(
      Uri.parse('$baseUrl/resources'),
      headers: _headers,
      body: jsonEncode(data),
    );

    final body = _decode(response);

    if (response.statusCode != 201 && response.statusCode != 200) {
      _fail(body, 'Failed to create resource');
    }

    return body;
  }

  static Future<Map<String, dynamic>> updateResource(
    int resourceId,
    Map<String, dynamic> data,
  ) async {
    final response = await http.patch(
      Uri.parse('$baseUrl/resources/$resourceId'),
      headers: _headers,
      body: jsonEncode(data),
    );

    final body = _decode(response);

    if (response.statusCode != 200) {
      _fail(body, 'Failed to update resource');
    }

    return body;
  }

  static Future<Map<String, dynamic>> setResourceActive(
    int resourceId,
    bool isActive,
  ) async {
    final action = isActive ? 'restore' : 'deactivate';

    final response = await http.patch(
      Uri.parse('$baseUrl/resources/$resourceId/$action'),
      headers: _headers,
    );

    final body = _decode(response);

    if (response.statusCode != 200) {
      _fail(body, 'Failed to update resource state');
    }

    return body;
  }

  // ---------------------------------------------------------------------
  // RESPONDERS AND THEIR INVENTORY
  // ---------------------------------------------------------------------

  static Future<List<dynamic>> getResponders() async {
    final response = await http.get(
      Uri.parse('$baseUrl/responders'),
      headers: _headers,
    );

    final body = _decode(response);

    if (response.statusCode != 200) {
      _fail(body, 'Failed to load responders');
    }

    return body['responders'] ?? [];
  }

  /// Rich ADMIN responder list for the assignment picker. It includes the
  /// backend-computed compatible request ids plus enabled help types and
  /// inventory/resource availability.
  static Future<List<dynamic>> getAdminResponders() async {
    final response = await http.get(
      Uri.parse('$baseUrl/admin/responders'),
      headers: _headers,
    );
    final body = _decode(response);
    if (response.statusCode != 200) {
      _fail(body, 'Failed to load assignment candidates');
    }
    return body['responders'] ?? [];
  }

  /// Canonical emergency categories and this responder's durable selections.
  /// Categories come from the backend so Flutter never owns a divergent list.
  static Future<Map<String, dynamic>> getResponderHelpTypes() async {
    final response = await http.get(
      Uri.parse('$baseUrl/responders/help-types'),
      headers: _headers,
    );
    final body = _decode(response);
    if (response.statusCode != 200) {
      _fail(body, 'Failed to load help types');
    }
    return body;
  }

  static Future<Map<String, dynamic>> updateResponderHelpTypes(
    Iterable<String> helpTypes,
  ) async {
    final response = await http.put(
      Uri.parse('$baseUrl/responders/help-types'),
      headers: _headers,
      body: jsonEncode(<String, dynamic>{'helpTypes': helpTypes.toList()}),
    );
    final body = _decode(response);
    if (response.statusCode != 200) {
      _fail(body, 'Failed to update help types');
    }
    return body;
  }

  static Future<List<dynamic>> getResponderResources() async {
    final response = await http.get(
      Uri.parse('$baseUrl/responder-resources/my'),
      headers: _headers,
    );

    final body = _decode(response);

    if (response.statusCode != 200) {
      _fail(body, 'Failed to load responder resources');
    }

    return body['resources'] ?? [];
  }

  static Future<Map<String, dynamic>> createResponderResource(
    Map<String, dynamic> data,
  ) async {
    final response = await http.post(
      Uri.parse('$baseUrl/responder-resources'),
      headers: _headers,
      body: jsonEncode(data),
    );
    final body = _decode(response);
    if (response.statusCode != 201) {
      _fail(body, 'Failed to add responder resource');
    }
    return body;
  }

  static Future<Map<String, dynamic>> updateResponderResource(
    int responderResourceId,
    Map<String, dynamic> data,
  ) async {
    final response = await http.patch(
      Uri.parse('$baseUrl/responder-resources/$responderResourceId'),
      headers: _headers,
      body: jsonEncode(data),
    );
    final body = _decode(response);
    if (response.statusCode != 200) {
      _fail(body, 'Failed to update help type');
    }
    return body;
  }

  static Future<void> setResponderStatus(String status) async {
    final response = await http.patch(
      Uri.parse('$baseUrl/responders/status'),
      headers: _headers,
      body: jsonEncode(<String, dynamic>{'status': status}),
    );
    if (response.statusCode != 200) {
      _fail(_decode(response), 'Failed to update responder status');
    }
  }

  /// Lightweight activity signal; a failed heartbeat intentionally has no
  /// local availability side effect.
  static Future<void> responderHeartbeat() async {
    final response = await http.post(
      Uri.parse('$baseUrl/responders/heartbeat'),
      headers: _headers,
    );
    if (response.statusCode != 200) {
      _fail(_decode(response), 'Heartbeat failed');
    }
  }

  // ---------------------------------------------------------------------
  // PUSH DEVICE TOKENS (FCM)
  // ---------------------------------------------------------------------

  /// Register (or refresh) this device's FCM token so pushes about new
  /// compatible emergencies reach the app while it is backgrounded. The
  /// backend stores one row per device; the emergency request itself remains
  /// the source of truth, so a failed registration never affects dispatch.
  static Future<void> registerDeviceToken(
    String token, {
    String? platform,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/responders/device-tokens'),
      headers: _headers,
      body: jsonEncode(<String, dynamic>{
        'token': token,
        if (platform != null && platform.trim().isNotEmpty)
          'platform': platform.trim(),
      }),
    );
    if (response.statusCode != 201) {
      _fail(_decode(response), 'Failed to register device token');
    }
  }

  /// Remove this device's FCM token (logout). Best-effort by design: the
  /// backend keeps every pending compatible request either way.
  static Future<void> unregisterDeviceToken(String token) async {
    final response = await http.delete(
      Uri.parse('$baseUrl/responders/device-tokens'),
      headers: _headers,
      body: jsonEncode(<String, dynamic>{'token': token}),
    );
    if (response.statusCode != 200) {
      _fail(_decode(response), 'Failed to remove device token');
    }
  }

  // ---------------------------------------------------------------------
  // ALLOCATIONS
  // ---------------------------------------------------------------------

  static Future<Map<String, dynamic>> createAllocation({
    required int requestId,
    required int responderResourceId,
    required int resourceId,
    required int quantity,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/allocations'),
      headers: _headers,
      body: jsonEncode({
        'requestId': requestId,
        'responderResourceId': responderResourceId,
        'resourceId': resourceId,
        'quantity': quantity,
      }),
    );

    final body = _decode(response);

    if (response.statusCode != 201) {
      _fail(body, 'Failed to create allocation');
    }

    return body;
  }

  static Future<List<dynamic>> getMyAllocations() async {
    final response = await http.get(
      Uri.parse('$baseUrl/allocations/my'),
      headers: _headers,
    );

    final body = _decode(response);

    if (response.statusCode != 200) {
      _fail(body, 'Failed to load allocations');
    }

    return body['allocations'] ?? [];
  }

  static Future<Map<String, dynamic>> updateAllocationStatus({
    required int allocationId,
    required String status,
  }) async {
    final response = await http.patch(
      Uri.parse('$baseUrl/allocations/$allocationId/status'),
      headers: _headers,
      body: jsonEncode({
        'status': status,
      }),
    );

    final body = _decode(response);

    if (response.statusCode != 200) {
      _fail(body, 'Failed to update allocation status');
    }

    return body;
  }

  static Future<Map<String, dynamic>> confirmAllocationReceived(
    int allocationId,
  ) async {
    final response = await http.patch(
      Uri.parse('$baseUrl/allocations/$allocationId/received'),
      headers: _headers,
    );
    final body = _decode(response);
    if (response.statusCode != 200) {
      _fail(body, 'Failed to confirm resource receipt');
    }
    return body;
  }
}
