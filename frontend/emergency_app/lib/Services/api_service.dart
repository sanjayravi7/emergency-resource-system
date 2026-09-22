import 'dart:convert';
import 'package:http/http.dart' as http;

class ApiService {
  static const String baseUrl = 'http://localhost:5000/api';

  static String? token;

  static Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (token != null) 'Authorization': 'Bearer $token',
      };

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

    final body = jsonDecode(response.body);

    if (response.statusCode != 200) {
      throw Exception(body['message'] ?? 'Login failed');
    }

    token = body['data']['token'];

    return body;
  }

  static Future<Map<String, dynamic>> createRequest({
    required String emergencyType,
    required String description,
    required String location,
    required String priority,
    required int resourceId,
    required int quantity,
  }) async {
    final response = await http.post(
      Uri.parse('$baseUrl/requests'),
      headers: _headers,
      body: jsonEncode({
        'emergencyType': emergencyType,
        'description': description,
        'location': location,
        'priority': priority,
        'requiredResources': [
          {
            'resourceId': resourceId,
            'quantity': quantity,
          }
        ],
      }),
    );

    final body = jsonDecode(response.body);

    if (response.statusCode != 201) {
      throw Exception(body['message'] ?? 'Failed to create request');
    }

    return body;
  }

   static Future<List<dynamic>> getMyRequests() async {
    final response = await http.get(
      Uri.parse('$baseUrl/requests/my'),
      headers: _headers,
    );

    final body = jsonDecode(response.body);

    if (response.statusCode != 200) {
      throw Exception(body['message'] ?? 'Failed to load requests');
    }

    return body['requests'] ?? [];
  }

  static Future<List<dynamic>> getResources() async {
    final response = await http.get(
      Uri.parse('$baseUrl/resources'),
      headers: _headers,
    );

    final body = jsonDecode(response.body);

    if (response.statusCode != 200) {
      throw Exception(
        body['message'] ?? 'Failed to load resources',
      );
    }

    return body['resources'] ?? [];
  }
    static Future<List<dynamic>> getResponders() async {
    final response = await http.get(
      Uri.parse('$baseUrl/responders'),
      headers: _headers,
    );

    final body = jsonDecode(response.body);

    if (response.statusCode != 200) {
      throw Exception(
        body['message'] ?? 'Failed to load responders',
      );
    }

    return body['responders'] ?? [];
  }
  static Future<List<dynamic>> getResponderResources() async {
  final response = await http.get(
    Uri.parse('$baseUrl/responder-resources'),
    headers: _headers,
  );

  final body = jsonDecode(response.body);

  if (response.statusCode != 200) {
    throw Exception(
      body['message'] ?? 'Failed to load responder resources',
    );
  }

  return body['resources'] ?? [];
}
}
