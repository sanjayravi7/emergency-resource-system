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

  static int? currentUserId;

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

    token = body['data']['token'];
    currentUserId = (body['data']['user']['id'] as num).toInt();
    currentRole = body['data']['user']['role'];
    currentUserName = body['data']['user']['name']?.toString();

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
    }
  }

  // ---------------------------------------------------------------------
  // EMERGENCY REQUESTS
  // ---------------------------------------------------------------------

  static Future<Map<String, dynamic>> createRequest({
    required String emergencyType,
    required String description,
    required String location,
    required String priority,
    required double? latitude,
    required double? longitude,
    required List<Map<String, int>> requiredResources,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/requests'),
      headers: _headers,
      body: jsonEncode({
        'emergencyType': emergencyType,
        'description': description,
        'location': location,
        'priority': priority,
        'latitude': latitude,
        'longitude': longitude,
        'requiredResources': requiredResources,
      }),
    );

    final body = _decode(response);

    if (response.statusCode != 201) {
      _fail(body, 'Failed to create request');
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

  /// Requesters may only cancel their own PENDING requests - the backend
  /// enforces this and is the final authority.
  static Future<Map<String, dynamic>> cancelMyRequest(int requestId) async {
    final response = await http.patch(
      Uri.parse('$baseUrl/requests/$requestId/cancel'),
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
