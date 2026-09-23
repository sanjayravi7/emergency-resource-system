import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'Services/api_service.dart';

void main() => runApp(const DispatchConsoleApp());

class DispatchConsoleApp extends StatelessWidget {
  const DispatchConsoleApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
  debugShowCheckedModeBanner: false,
  title: 'ERAS - Dispatch Console',
  theme: ThemeData(
    useMaterial3: true,
    fontFamily: 'IBM Plex Sans',
    scaffoldBackgroundColor: AppColors.bg,
    colorScheme: ColorScheme.fromSeed(seedColor: AppColors.teal),
  ),
  home: const LoginScreen(),
  );
  }
}

class AppColors {
  static const bg = Color(0xFFF5F6FA);
  static const surface = Color(0xFFFFFFFF);
  static const surface2 = Color(0xFFEEF1F8);
  static const border = Color(0xFFDCE1EE);
  static const text = Color(0xFF111A2E);
  static const textDim = Color(0xFF525C7A);
  static const textFaint = Color(0xFF8A93AE);
  static const teal = Color(0xFF0E9C8C);
  static const tealDim = Color(0xFFE1F7F2);
  static const amber = Color(0xFFB4740A);
  static const amberDim = Color(0xFFFDF0DA);
  static const red = Color(0xFFD6304A);
  static const redDim = Color(0xFFFCE7EA);
  static const blue = Color(0xFF3B63D6);
}
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final emailController = TextEditingController();
  final passwordController = TextEditingController();

  bool loading = false;
  String? errorMessage;

  Future<void> login() async {
  FocusScope.of(context).unfocus();

  if (emailController.text.trim().isEmpty ||
      passwordController.text.isEmpty) {
    setState(() {
      errorMessage = 'Please enter email and password';
    });
    return;
  }

  setState(() {
    loading = true;
    errorMessage = null;
  });

  try {
    await ApiService.login(
      emailController.text.trim(),
      passwordController.text,
    );

    if (!mounted) return;

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => const DispatchConsolePage(),
      ),
    );
  } catch (error) {
    if (mounted) {
      setState(() {
        errorMessage =
            error.toString().replaceFirst('Exception: ', '');
      });
    }
  } finally {
    if (mounted) {
      setState(() {
        loading = false;
      });
    }
  }
}

  @override
  void dispose() {
    emailController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: 420,
            ),
            child: Container(
              padding: const EdgeInsets.all(28),
              decoration: BoxDecoration(
                color: AppColors.surface,
                border: Border.all(
                  color: AppColors.border,
                ),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                      color: AppColors.teal,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),

                  const Text(
                    'ERAS',
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w700,
                      color: AppColors.text,
                    ),
                  ),

                  const SizedBox(height: 6),

                  const Text(
                    'Emergency Resource Allocation System',
                    style: TextStyle(
                      fontSize: 13,
                      color: AppColors.textDim,
                    ),
                  ),

                  const SizedBox(height: 28),

                  const Text(
                    'LOGIN',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      letterSpacing: .8,
                      color: AppColors.textDim,
                    ),
                  ),

                  const SizedBox(height: 12),

                  TextField(
                    controller: emailController,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(
                      labelText: 'Email',
                      border: OutlineInputBorder(),
                    ),
                  ),

                  const SizedBox(height: 14),

                  TextField(
                    controller: passwordController,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'Password',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) {
                      if (!loading) {
                        login();
                      }
                    },
                  ),

                  const SizedBox(height: 14),

                  if (errorMessage != null)
                    Container(
                      padding: const EdgeInsets.all(10),
                      margin: const EdgeInsets.only(bottom: 14),
                      decoration: BoxDecoration(
                        color: AppColors.redDim,
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: Text(
                        errorMessage!,
                        style: const TextStyle(
                          color: AppColors.red,
                          fontSize: 12,
                        ),
                      ),
                    ),

                  SizedBox(
                    height: 46,
                    child: FilledButton(
                      onPressed: loading ? null : login,
                      style: FilledButton.styleFrom(
                        backgroundColor: AppColors.teal,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(5),
                        ),
                      ),
                      child: loading
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Text(
                              'Login',
                              style: TextStyle(
                                fontSize: 14,
                              ),
                            ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
enum ConsoleView { board, newRequest, responders, log }

enum ResourceType { ambulance, blood, volunteer }

enum Urgency { critical, high, standard }

enum ResponderStatus { available, enroute, off }

enum RequestStatus {
  pending,
  enroute,
  partiallyAllocated,
  arrived,
  unmatched,
  closed,
}

class District {
  const District(this.name, this.point);
  final String name;
  final Offset point;
}

class ResourceMeta {
  const ResourceMeta(this.label, this.icon, this.bg, this.color);
  final String label;
  final IconData icon;
  final Color bg;
  final Color color;
}
class BackendResource {
  const BackendResource({
    required this.id,
    required this.name,
    required this.type,
    required this.totalQuantity,
    required this.availableQuantity,
    this.unit,
    this.location,
  });

  final int id;
  final String name;
  final String type;
  final int totalQuantity;
  final int availableQuantity;
  final String? unit;
  final String? location;

  factory BackendResource.fromJson(Map<String, dynamic> json) {
    return BackendResource(
      id: (json['id'] as num).toInt(),
      name: json['name']?.toString() ?? 'Unknown resource',
      type: json['type']?.toString() ?? '',
      totalQuantity: (json['totalQuantity'] as num?)?.toInt() ?? 0,
      availableQuantity:
          (json['availableQuantity'] as num?)?.toInt() ?? 0,
      unit: json['unit']?.toString(),
      location: json['location']?.toString(),
    );
  }
}
class Responder {
  Responder(
      {required this.id,
      required this.type,
      required this.district,
      required this.status});
  final String id;
  final ResourceType type;
  String district;
  ResponderStatus status;
}
class BackendResponderResource {
  const BackendResponderResource({
    required this.id,
    required this.responderId,
    required this.resourceId,
    required this.totalQuantity,
    required this.availableQuantity,
    required this.status,
    required this.responderName,
    required this.responderEmail,
    required this.responderStatus,
    required this.resourceName,
    required this.resourceType,
    this.unit,
    this.location,
  });

  final int id;
  final int responderId;
  final int resourceId;
  final int totalQuantity;
  final int availableQuantity;
  final String status;

  final String responderName;
  final String responderEmail;
  final String responderStatus;

  final String resourceName;
  final String resourceType;
  final String? unit;
  final String? location;

  factory BackendResponderResource.fromJson(
    Map<String, dynamic> json,
  ) {
    final responder =
        Map<String, dynamic>.from(json['responder'] ?? {});
    final resource =
        Map<String, dynamic>.from(json['resource'] ?? {});

    return BackendResponderResource(
      id: (json['id'] as num).toInt(),
      responderId: (json['responderId'] as num).toInt(),
      resourceId: (json['resourceId'] as num).toInt(),
      totalQuantity: (json['totalQuantity'] as num?)?.toInt() ?? 0,
      availableQuantity:
          (json['availableQuantity'] as num?)?.toInt() ?? 0,
      status: json['status']?.toString() ?? 'UNAVAILABLE',

      responderName:
          responder['name']?.toString() ?? 'Unknown responder',
      responderEmail:
          responder['email']?.toString() ?? '',
      responderStatus:
          responder['responderStatus']?.toString() ?? 'OFFLINE',

      resourceName:
          resource['name']?.toString() ?? 'Unknown resource',
      resourceType:
          resource['type']?.toString() ?? '',
      unit: resource['unit']?.toString(),
      location: resource['location']?.toString(),
    );
  }
}
class BackendResponder {
  const BackendResponder({
    required this.id,
    required this.name,
    required this.email,
    required this.status,
    this.phone,
    this.location,
    this.latitude,
    this.longitude,
    this.lastActiveAt,
  });

  final int id;
  final String name;
  final String email;
  final String status;
  final String? phone;
  final String? location;
  final double? latitude;
  final double? longitude;
  final DateTime? lastActiveAt;

  factory BackendResponder.fromJson(Map<String, dynamic> json) {
    return BackendResponder(
      id: (json['id'] as num).toInt(),
      name: json['name']?.toString() ?? 'Unknown responder',
      email: json['email']?.toString() ?? '',
      status: json['responderStatus']?.toString() ?? 'OFFLINE',
      phone: json['phone']?.toString(),
      location: json['location']?.toString(),
      latitude: (json['latitude'] as num?)?.toDouble(),
      longitude: (json['longitude'] as num?)?.toDouble(),
      lastActiveAt: DateTime.tryParse(
        json['lastActiveAt']?.toString() ?? '',
      ),
    );
  }
}
class EmergencyRequest {
  EmergencyRequest({
    required this.id,
    required this.type,
    required this.district,
    required this.urgency,
    required this.createdAt,
    this.status = RequestStatus.pending,
    this.resourceId,
    this.requiredQuantity,
  });
  final String id;
  final ResourceType type;
  final String district;
  final Urgency urgency;
  final DateTime createdAt;
  RequestStatus status;
  String? responder;
  double? distanceKm;
  int? etaMin;
  int? etaRemaining;
  int? totalSec;

  int? allocationId;
  int? allocatedQuantity;
  int? responderResourceId;
  int? resourceId;
  int? requiredQuantity;
}

class DispatchConsolePage extends StatefulWidget {
  const DispatchConsolePage({super.key});
  @override
  State<DispatchConsolePage> createState() => _DispatchConsolePageState();
}

class _DispatchConsolePageState extends State<DispatchConsolePage> {
  static const districts = <District>[
    District('North Ridge', Offset(150, 55)),
    District('Harbor District', Offset(470, 70)),
    District('Old Town', Offset(300, 130)),
    District('Riverside', Offset(100, 190)),
    District('Eastgate', Offset(520, 195)),
    District('Summit Heights', Offset(300, 40)),
  ];

  final responders = <Responder>[
    Responder(
        id: 'AMB-04',
        type: ResourceType.ambulance,
        district: 'Harbor District',
        status: ResponderStatus.available),
    Responder(
        id: 'AMB-11',
        type: ResourceType.ambulance,
        district: 'Riverside',
        status: ResponderStatus.available),
    Responder(
        id: 'AMB-19',
        type: ResourceType.ambulance,
        district: 'Summit Heights',
        status: ResponderStatus.off),
    Responder(
        id: 'BLU-02',
        type: ResourceType.blood,
        district: 'Old Town',
        status: ResponderStatus.available),
    Responder(
        id: 'BLU-07',
        type: ResourceType.blood,
        district: 'Eastgate',
        status: ResponderStatus.available),
    Responder(
        id: 'VOL-15',
        type: ResourceType.volunteer,
        district: 'Summit Heights',
        status: ResponderStatus.available),
    Responder(
        id: 'VOL-22',
        type: ResourceType.volunteer,
        district: 'North Ridge',
        status: ResponderStatus.available),
  ];

  final requests = <EmergencyRequest>[];
  final logEntries = <EmergencyRequest>[];
  final resources = <BackendResource>[];
  final backendResponders = <BackendResponder>[];
  final responderResources = <BackendResponderResource>[];
  final random = Random();


  ConsoleView activeView = ConsoleView.board;
  ResourceType selectedType = ResourceType.ambulance;
  String selectedDistrict = districts.first.name;
  Urgency selectedUrgency = Urgency.high;
  int reqSeq = 2280;
  late Timer clockTimer;
  late Timer incomingTimer;
  final List<Timer> _pendingTimers = [];
  DateTime now = DateTime.now();

  @override
void initState() {
  super.initState();

  loadInitialBackendData();

  clockTimer = Timer.periodic(
    const Duration(seconds: 1),
    (_) => setState(() => now = DateTime.now()),
  );
}

Future<void> loadInitialBackendData() async {
  await loadRequestsFromBackend();
  await loadResourcesFromBackend();
  await loadRespondersFromBackend();
  await loadResponderResourcesFromBackend();

  if (ApiService.currentRole == 'RESPONDER') {
    await loadAllocationsFromBackend();
  }
}

 @override
void dispose() {
  clockTimer.cancel();

  for (final t in _pendingTimers) {
    t.cancel();
  }

  _pendingTimers.clear();
  super.dispose();
}

 

  String newId() {
    reqSeq += 3;
    return 'ER-$reqSeq';
  }

  double distance(String a, String b) {
    final pa = districts.firstWhere((d) => d.name == a).point;
    final pb = districts.firstWhere((d) => d.name == b).point;
    return sqrt(pow(pa.dx - pb.dx, 2) + pow(pa.dy - pb.dy, 2)) / 22;
  }

  void addRequest(ResourceType type, String district, Urgency urgency,
      {bool silent = false}) {
    final request = EmergencyRequest(
        id: newId(),
        type: type,
        district: district,
        urgency: urgency,
        createdAt: DateTime.now());
    setState(() => requests.insert(0, request));
    if (!silent) showToast('${request.id} received - searching for a match...');
    final t = Timer(Duration(milliseconds: 1300 + random.nextInt(700)), () {
      if (!mounted) return;
      matchRequest(request.id);
    });
    _pendingTimers.add(t);
  }

  void matchRequest(String id) {
    final request = firstWhereOrNull(requests, (r) => r.id == id);
    if (request == null || request.status != RequestStatus.pending) {
      return;
    }
    final candidates = responders
        .where((r) =>
            r.type == request.type && r.status == ResponderStatus.available)
        .toList();
    if (candidates.isEmpty) {
      setState(() => request.status = RequestStatus.unmatched);
      showToast(
          '${request.id} - no available responder. Flagged for escalation.');
      return;
    }
    candidates.sort((a, b) => distance(a.district, request.district)
        .compareTo(distance(b.district, request.district)));
    final chosen = candidates.first;
    final km = distance(chosen.district, request.district);
    setState(() {
      request.status = RequestStatus.enroute;
      request.responder = chosen.id;
      request.distanceKm = km;
      request.etaMin = max(2, (km * 1.6).round());
      request.etaRemaining = request.etaMin;
      chosen.status = ResponderStatus.enroute;
    });
    showToast(
        '${request.id} matched to ${chosen.id} · ETA ${request.etaMin} min');
    tickEta(request.id);
  }

  void tickEta(String id) {
    final request = firstWhereOrNull(requests, (r) => r.id == id);
    if (request == null || request.status != RequestStatus.enroute) {
      return;
    }
    final t = Timer(const Duration(milliseconds: 900), () {
      if (!mounted) return;
      final current = firstWhereOrNull(requests, (r) => r.id == id);
      if (current == null || current.status != RequestStatus.enroute) {
        return;
      }
      setState(() => current.etaRemaining = (current.etaRemaining ?? 1) - 1);
      if ((current.etaRemaining ?? 0) <= 0) {
        setState(() => current.status = RequestStatus.arrived);
        showToast('${current.id} - responder arrived on scene.');
        final t2 =
            Timer(const Duration(milliseconds: 2600), () => closeRequest(id));
        _pendingTimers.add(t2);
      } else {
        tickEta(id);
      }
    });
    _pendingTimers.add(t);
  }

  void closeRequest(String id) {
    final index = requests.indexWhere((r) => r.id == id);
    if (index == -1) {
      return;
    }
    final request = requests[index];
    final responder =
        firstWhereOrNull(responders, (r) => r.id == request.responder);
    if (responder != null) {
      responder.status = ResponderStatus.available;
    }
    request.status = RequestStatus.closed;
    request.totalSec = DateTime.now().difference(request.createdAt).inSeconds;
    setState(() {
      logEntries.insert(0, request);
      requests.removeAt(index);
    });
  }

  void escalate(String id) {
    final request = firstWhereOrNull(requests, (r) => r.id == id);
    if (request == null) {
      return;
    }
    showToast('${request.id} escalated to regional coordination.');
    setState(() => request.status = RequestStatus.pending);
    Timer(const Duration(milliseconds: 1500), () => matchRequest(id));
  }

  void toggleResponder(String id) {
    final responder = firstWhereOrNull(responders, (r) => r.id == id);
    if (responder == null || responder.status == ResponderStatus.enroute) {
      return;
    }
    setState(() => responder.status =
        responder.status == ResponderStatus.available
            ? ResponderStatus.off
            : ResponderStatus.available);
  }

  void showToast(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message,
          style: const TextStyle(color: AppColors.text, fontSize: 13)),
      behavior: SnackBarBehavior.floating,
      duration: const Duration(milliseconds: 4200),
      backgroundColor: AppColors.surface2,
      elevation: 2,
      shape: const Border(left: BorderSide(color: AppColors.teal, width: 4)),
    ));
  }

  String get clockLabel {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(now.hour)}:${two(now.minute)}:${two(now.second)}';
  }

  String get viewTitle => switch (activeView) {
        ConsoleView.board => 'Dispatch Board',
        ConsoleView.newRequest => 'New Request',
        ConsoleView.responders => 'Responders',
        ConsoleView.log => 'Closed Log',
      };

  String get viewSubtitle => switch (activeView) {
        ConsoleView.board => 'Live requests across all districts',
        ConsoleView.newRequest => 'Create and auto-match a resource request',
        ConsoleView.responders => 'Duty status for all field assets',
        ConsoleView.log => 'Completed requests this session',
      };

  int get pendingCount =>
      requests.where((r) => r.status == RequestStatus.pending).length;
  int get activeCount =>
      requests.where((r) => r.status == RequestStatus.enroute).length;
  int get unmatchedCount =>
      requests.where((r) => r.status == RequestStatus.unmatched).length;
  Future<void> loadRequestsFromBackend() async {
  try {
    final backendRequests =
    ApiService.currentRole == 'RESPONDER'
        ? await ApiService.getCompatibleRequests()
        : await ApiService.getMyRequests();
    final activeRequests = <EmergencyRequest>[];
    final closedRequests = <EmergencyRequest>[];

    for (final item in backendRequests) {
      final data = Map<String, dynamic>.from(item as Map);

      final requiredResources =
          (data['requiredResources'] as List<dynamic>?) ?? [];
      int? backendResourceId;
      int requiredQuantity = 1;

      if (requiredResources.isNotEmpty) {
        final resource =
            Map<String, dynamic>.from(requiredResources.first as Map);

        backendResourceId =
            (resource['resourceId'] as num?)?.toInt();

        requiredQuantity =
            (resource['quantity'] as num?)?.toInt() ?? 1;
      }

     ResourceType type = ResourceType.ambulance;

final emergencyType =
    (data['emergencyType'] ?? '').toString().toUpperCase();

if (emergencyType == 'BLOOD') {
  type = ResourceType.blood;
} else if (emergencyType == 'VOLUNTEER') {
  type = ResourceType.volunteer;
} else if (emergencyType == 'AMBULANCE') {
  type = ResourceType.ambulance;
}
      Urgency urgency = Urgency.standard;

      switch ((data['priority'] ?? 'MEDIUM').toString()) {
        case 'CRITICAL':
          urgency = Urgency.critical;
          break;
        case 'HIGH':
          urgency = Urgency.high;
          break;
        case 'MEDIUM':
        default:
          urgency = Urgency.standard;
          break;
      }

      RequestStatus status;

      switch ((data['status'] ?? 'PENDING').toString()) {
        case 'COMPLETED':
        case 'CANCELLED':
          status = RequestStatus.closed;
          break;

        case 'ACCEPTED':
        case 'IN_PROGRESS':
          status = RequestStatus.enroute;
          break;

        case 'PARTIALLY_ALLOCATED':
          status = RequestStatus.partiallyAllocated;
          break;

        case 'PENDING':
        default:
          status = RequestStatus.pending;
          break;
      }

      final request = EmergencyRequest(
        id: 'DB-${data['id']}',
        type: type,
        district: data['location']?.toString() ?? 'Unknown',
        urgency: urgency,
        createdAt: DateTime.tryParse(
              data['createdAt']?.toString() ?? '',
            ) ??
            DateTime.now(),
        status: status,
        resourceId: backendResourceId,
        requiredQuantity: requiredQuantity,
      );

      if (status == RequestStatus.closed) {
        closedRequests.add(request);
      } else {
        activeRequests.add(request);
      }
    }

    activeRequests.sort(
      (a, b) => b.createdAt.compareTo(a.createdAt),
    );

    closedRequests.sort(
      (a, b) => b.createdAt.compareTo(a.createdAt),
    );

    if (!mounted) return;

    setState(() {
      requests
        ..clear()
        ..addAll(activeRequests);

      logEntries
        ..clear()
        ..addAll(closedRequests);
    });
  } catch (error) {
    if (!mounted) return;

    showToast(
      'Failed to load requests: ${error.toString().replaceFirst('Exception: ', '')}',
    );
  }
}
Future<void> loadAllocationsFromBackend() async {
  if (ApiService.currentRole != 'RESPONDER') {
    return;
  }

  try {
    final backendAllocations =
        await ApiService.getMyAllocations();

    if (!mounted) return;

    setState(() {
      for (final request in requests) {
        request.allocationId = null;
        request.allocatedQuantity = null;
        request.responderResourceId = null;

        final matches = backendAllocations.where((item) {
          final allocation = Map<String, dynamic>.from(item as Map);

          final sameRequest =
              (allocation['requestId'] as num?)?.toInt() ==
              int.tryParse(request.id.replaceFirst('DB-', ''));

          final active =
              allocation['status']?.toString().toUpperCase() != 'CANCELLED';

          return sameRequest && active;
        }).toList();

        if (matches.isEmpty) continue;

        final allocation =
            Map<String, dynamic>.from(matches.last as Map);

        request.allocationId =
            (allocation['id'] as num?)?.toInt();

        request.allocatedQuantity =
            (allocation['quantity'] as num?)?.toInt();

        request.responderResourceId =
            (allocation['responderResourceId'] as num?)?.toInt();
      }
    });
  } catch (error) {
    if (!mounted) return;

    showToast(
      'Failed to load allocations: '
      '${error.toString().replaceFirst('Exception: ', '')}',
    );
  }
}
Future<void> acceptRequestFromBackend(String displayId) async {
  try {
    // Flutter displays database IDs like DB-12.
    final match = RegExp(r'^DB-(\d+)$').firstMatch(displayId);

    if (match == null) {
      throw Exception('Invalid database request ID');
    }

    final requestId = int.parse(match.group(1)!);

    await ApiService.acceptEmergencyRequest(requestId);

    showToast('$displayId accepted successfully');

    await loadRequestsFromBackend();
  } catch (error) {
    if (!mounted) return;

    showToast(
      'Accept failed: '
      '${error.toString().replaceFirst('Exception: ', '')}',
    );
  }
}
Future<void> allocateRequestFromBackend(String displayId) async {
  try {
    final match = RegExp(r'^DB-(\d+)$').firstMatch(displayId);

    if (match == null) {
      throw Exception('Invalid database request ID');
    }

    final requestId = int.parse(match.group(1)!);

    final request = firstWhereOrNull(
      requests,
      (r) => r.id == displayId,
    );

    if (request == null) {
      throw Exception('Request not found');
    }

    if (ApiService.currentUserId == null) {
      throw Exception('Logged-in responder ID not available');
    }

    final resourceId = request.resourceId;

    if (resourceId == null) {
      throw Exception('Requested resource information not available');
    }

    final requiredQuantity = request.requiredQuantity ?? 1;
    final allocatedQuantity = request.allocatedQuantity ?? 0;
    final quantity = requiredQuantity - allocatedQuantity;

    if (quantity <= 0) {
      throw Exception('All required resources have already been allocated');
    }

    final matchingResources = responderResources.where(
      (item) =>
          item.responderId == ApiService.currentUserId &&
          item.resourceId == resourceId &&
          item.availableQuantity >= quantity,
    ).toList();

    if (matchingResources.isEmpty) {
      throw Exception(
        'You do not have enough available inventory for this request',
      );
    }

    final responderResource = matchingResources.first;

    await ApiService.createAllocation(
      requestId: requestId,
      responderResourceId: responderResource.id,
      resourceId: resourceId,
      quantity: quantity,
    );

    showToast(
      '$displayId allocated using ${responderResource.resourceName}',
    );

    await loadRequestsFromBackend();
    await loadResponderResourcesFromBackend();
    await loadAllocationsFromBackend();
  } catch (error) {
    if (!mounted) return;

    showToast(
      'Allocation failed: '
      '${error.toString().replaceFirst('Exception: ', '')}',
    );
  }
}
Future<void> cancelAllocationFromBackend(
  String displayId,
) async {
  try {
    final request = requests.firstWhere(
      (r) => r.id == displayId,
    );

    if (request.allocationId == null) {
      showToast('No allocation found for $displayId');
      return;
    }

    await ApiService.updateAllocationStatus(
      allocationId: request.allocationId!,
      status: 'CANCELLED',
    );

    showToast('Allocation cancelled successfully');

    await loadRequestsFromBackend();
    await loadResponderResourcesFromBackend();
    await loadAllocationsFromBackend();
  } catch (error) {
    if (!mounted) return;

    showToast(
      'Cancel failed: '
      '${error.toString().replaceFirst('Exception: ', '')}',
    );
  }
}
Future<void> loadResourcesFromBackend() async {
  try {
    final backendResources = await ApiService.getResources();

    final loadedResources = backendResources.map((item) {
      return BackendResource.fromJson(
        Map<String, dynamic>.from(item as Map),
      );
    }).toList();

    if (!mounted) return;

    setState(() {
      resources
        ..clear()
        ..addAll(loadedResources);
    });
  } catch (error) {
    if (!mounted) return;

    showToast(
      'Failed to load resources: '
      '${error.toString().replaceFirst('Exception: ', '')}',
    );
  }
}
Future<void> loadRespondersFromBackend() async {
  try {
    final backendResponders = await ApiService.getResponders();

    final loadedResponders = backendResponders.map((item) {
      return BackendResponder.fromJson(
        Map<String, dynamic>.from(item as Map),
      );
    }).toList();

    if (!mounted) return;

    setState(() {
      this.backendResponders
        ..clear()
        ..addAll(loadedResponders);
    });
  } catch (error) {
    if (!mounted) return;

    showToast(
      'Failed to load responders: '
      '${error.toString().replaceFirst('Exception: ', '')}',
    );
  }
}
Future<void> loadResponderResourcesFromBackend() async {
  try {
    final backendResources =
        await ApiService.getResponderResources();

    final loadedResources = backendResources.map((item) {
      return BackendResponderResource.fromJson(
        Map<String, dynamic>.from(item as Map),
      );
    }).toList();

    if (!mounted) return;

    setState(() {
      responderResources
        ..clear()
        ..addAll(loadedResources);
    });
  } catch (error) {
    if (!mounted) return;

    showToast(
      'Failed to load responder resources: '
      '${error.toString().replaceFirst('Exception: ', '')}',
    );
  }
}
 Future<void> submitRequestToBackend() async {
  try {
    BackendResource? selectedResource;

    // Find an available resource from PostgreSQL
    // matching the resource type selected in the UI.
    for (final resource in resources) {
      if (resource.type.toUpperCase() ==
              selectedType.name.toUpperCase() &&
          resource.availableQuantity > 0) {
        selectedResource = resource;
        break;
      }
    }

    if (selectedResource == null) {
      throw Exception(
        'No available ${selectedType.name} resource found in the database',
      );
    }

    final resourceId = selectedResource.id;

    final priority = switch (selectedUrgency) {
      Urgency.critical => 'CRITICAL',
      Urgency.high => 'HIGH',
      Urgency.standard => 'MEDIUM',
    };

    await ApiService.createRequest(
      emergencyType: selectedType.name.toUpperCase(),
      description:
          'Emergency ${selectedType.name} request from $selectedDistrict',
      location: selectedDistrict,
      priority: priority,
      latitude: null,
      longitude: null,
      requiredResources: [
        {
          'resourceId': resourceId,
          'quantity': 1,
        }
      ],
    );

    showToast('Emergency request created successfully');

    await loadRequestsFromBackend();

    setView(ConsoleView.board);
  } catch (error) {
    showToast(
      'Request failed: ${error.toString().replaceFirst('Exception: ', '')}',
    );
  }
}
  void setView(ConsoleView view) => setState(() => activeView = view);

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final isMobile = width < 720;

    if (isMobile) {
      return Scaffold(
        backgroundColor: AppColors.bg,
        appBar: _MobileAppBar(
          clock: clockLabel,
          pending: pendingCount,
          active: activeCount,
          unmatched: unmatchedCount,
          title: viewTitle,
        ),
        body: SafeArea(
          top: false,
          child: _buildMainContent(isMobile: true),
        ),
        bottomNavigationBar: _BottomNav(
          activeView: activeView,
          onViewChanged: setView,
          requests: requests,
          responders: responders,
        ),
      );
    }

    // Desktop layout
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Rail(
                activeView: activeView,
                onViewChanged: setView,
                requests: requests,
                responders: responders,
                clock: clockLabel),
            Expanded(
              child: Column(
                children: [
                  DesktopTopBar(
                    title: viewTitle,
                    subtitle: viewSubtitle,
                    pending: pendingCount,
                    active: activeCount,
                    unmatched: unmatchedCount,
                  ),
                  Expanded(child: _buildMainContent(isMobile: false)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMainContent({required bool isMobile}) {
    return ListView(
      padding: EdgeInsets.fromLTRB(isMobile ? 12 : 24, isMobile ? 12 : 22,
          isMobile ? 12 : 24, isMobile ? 80 : 60),
      children: [
        if (activeView == ConsoleView.board)
          BoardPanel(
            requests: requests,
            onEscalate: escalate,
            onAccept: acceptRequestFromBackend,
            onAllocate: allocateRequestFromBackend,
            onCancelAllocation: cancelAllocationFromBackend,
            isMobile: isMobile,
          ),
        if (activeView == ConsoleView.newRequest)
          NewRequestPanel(
            selectedType: selectedType,
            selectedDistrict: selectedDistrict,
            selectedUrgency: selectedUrgency,
            districts: districts.map((d) => d.name).toList(),
            onTypeChanged: (v) => setState(() => selectedType = v),
            onDistrictChanged: (v) => setState(() => selectedDistrict = v),
            onUrgencyChanged: (v) => setState(() => selectedUrgency = v),
            onSubmit: submitRequestToBackend,
          ),
        if (activeView == ConsoleView.responders) ...[
          BackendRespondersPanel(
            responders: backendResponders,
            isMobile: isMobile,
            ),

            const SizedBox(height: 22),

              ResponderResourcesPanel(
               resources: responderResources,
            ),

              const SizedBox(height: 22),

            ResourceCatalogPanel(
              resources: resources,
              isMobile: isMobile,
              ),
            ],
        if (activeView == ConsoleView.log)
          LogPanel(logEntries: logEntries, isMobile: isMobile),
        const SizedBox(height: 22),
        Panel(
          title: 'SECTOR MAP',
          hint: 'Districts, responders, and open requests',
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: AspectRatio(
                  aspectRatio: isMobile ? 360 / 200 : 640 / 260,
                  child: CustomPaint(
                      painter: SectorMapPainter(
                          districts: districts,
                          responders: responders,
                          requests: requests)),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                child: Wrap(
                  spacing: 12,
                  runSpacing: 6,
                  children: const [
                    LegendItem(color: AppColors.teal, label: 'Available'),
                    LegendItem(color: AppColors.blue, label: 'En route'),
                    LegendItem(color: AppColors.textFaint, label: 'Off duty'),
                    LegendItem(color: AppColors.amber, label: 'Pending'),
                    LegendItem(color: AppColors.red, label: 'Unmatched'),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ── Mobile App Bar ─────────────────────────────────────────────────────────────

class _MobileAppBar extends StatelessWidget implements PreferredSizeWidget {
  const _MobileAppBar(
      {required this.clock,
      required this.pending,
      required this.active,
      required this.unmatched,
      required this.title});
  final String clock;
  final int pending, active, unmatched;
  final String title;

  @override
  Size get preferredSize => const Size.fromHeight(96);

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.surface,
      padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top),
      child: Column(
        children: [
          // Brand strip
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: AppColors.border))),
            child: Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                      color: AppColors.teal,
                      borderRadius: BorderRadius.circular(2)),
                ),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text('ERAS · DISPATCH',
                      style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                          color: AppColors.text,
                          letterSpacing: .4)),
                ),
                Text(clock,
                    style: monoStyle(size: 12, color: AppColors.textDim)),
              ],
            ),
          ),
          // Stats strip
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            child: Row(
              children: [
                Expanded(
                    child: Text(title,
                        style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: AppColors.text))),
                _MiniStat(
                    label: 'Pend', value: pending, color: AppColors.amber),
                const SizedBox(width: 14),
                _MiniStat(label: 'Route', value: active, color: AppColors.blue),
                const SizedBox(width: 14),
                _MiniStat(
                    label: 'Unmatch', value: unmatched, color: AppColors.red),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniStat extends StatelessWidget {
  const _MiniStat(
      {required this.label, required this.value, required this.color});
  final String label;
  final int value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text('$value',
            style: monoStyle(size: 16, color: color, weight: FontWeight.w600)),
        Text(label,
            style: const TextStyle(
                fontSize: 9.5, color: AppColors.textFaint, letterSpacing: .5)),
      ],
    );
  }
}

// ── Bottom Navigation ──────────────────────────────────────────────────────────

class _BottomNav extends StatelessWidget {
  const _BottomNav(
      {required this.activeView,
      required this.onViewChanged,
      required this.requests,
      required this.responders});
  final ConsoleView activeView;
  final ValueChanged<ConsoleView> onViewChanged;
  final List<EmergencyRequest> requests;
  final List<Responder> responders;

  @override
  Widget build(BuildContext context) {
    final items = [
      _NavItem(
          view: ConsoleView.board,
          icon: Icons.view_list_rounded,
          label: 'Board',
          badge: '${requests.length}'),
      _NavItem(
          view: ConsoleView.newRequest,
          icon: Icons.add_circle_outline_rounded,
          label: 'New'),
      _NavItem(
          view: ConsoleView.responders,
          icon: Icons.radio_button_checked_rounded,
          label: 'Responders'),
      _NavItem(
          view: ConsoleView.log, icon: Icons.history_rounded, label: 'Log'),
    ];

    return Container(
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.border)),
      ),
      child: SafeArea(
        top: false,
        child: Row(
          children: items.map((item) {
            final active = item.view == activeView;
            return Expanded(
              child: InkWell(
                onTap: () => onViewChanged(item.view),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Icon(item.icon,
                              size: 22,
                              color: active
                                  ? AppColors.teal
                                  : AppColors.textFaint),
                          if (item.badge != null && item.badge != '0')
                            Positioned(
                              top: -4,
                              right: -8,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 4, vertical: 1),
                                decoration: BoxDecoration(
                                    color: AppColors.teal,
                                    borderRadius: BorderRadius.circular(8)),
                                child: Text(item.badge!,
                                    style: const TextStyle(
                                        fontSize: 9,
                                        color: Colors.white,
                                        fontWeight: FontWeight.w600)),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(item.label,
                          style: TextStyle(
                              fontSize: 10,
                              color:
                                  active ? AppColors.teal : AppColors.textFaint,
                              fontWeight: active
                                  ? FontWeight.w600
                                  : FontWeight.normal)),
                      if (active)
                        Container(
                            margin: const EdgeInsets.only(top: 3),
                            width: 16,
                            height: 2,
                            decoration: BoxDecoration(
                                color: AppColors.teal,
                                borderRadius: BorderRadius.circular(2))),
                    ],
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }
}

class _NavItem {
  const _NavItem(
      {required this.view,
      required this.icon,
      required this.label,
      this.badge});
  final ConsoleView view;
  final IconData icon;
  final String label;
  final String? badge;
}

// ── Desktop Rail ───────────────────────────────────────────────────────────────

class Rail extends StatelessWidget {
  const Rail(
      {super.key,
      required this.activeView,
      required this.onViewChanged,
      required this.requests,
      required this.responders,
      required this.clock});
  final ConsoleView activeView;
  final ValueChanged<ConsoleView> onViewChanged;
  final List<EmergencyRequest> requests;
  final List<Responder> responders;
  final String clock;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 220,
      color: AppColors.surface,
      padding: const EdgeInsets.fromLTRB(14, 20, 14, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Brand(),
          const SizedBox(height: 16),
          NavButton(
              label: 'Dispatch board',
              icon: Icons.view_list_rounded,
              active: activeView == ConsoleView.board,
              count: '${requests.length}',
              onTap: () => onViewChanged(ConsoleView.board)),
          NavButton(
              label: 'New request',
              icon: Icons.add_circle_outline_rounded,
              active: activeView == ConsoleView.newRequest,
              onTap: () => onViewChanged(ConsoleView.newRequest)),
          NavButton(
              label: 'Responders',
              icon: Icons.radio_button_checked_rounded,
              active: activeView == ConsoleView.responders,
              count:
                  '${responders.where((r) => r.status != ResponderStatus.off).length}/${responders.length}',
              onTap: () => onViewChanged(ConsoleView.responders)),
          NavButton(
              label: 'Closed log',
              icon: Icons.history_rounded,
              active: activeView == ConsoleView.log,
              onTap: () => onViewChanged(ConsoleView.log)),
          const Spacer(),
          Container(height: 1, color: AppColors.border),
          const SizedBox(height: 16),
          Text(clock, style: monoStyle(size: 13, color: AppColors.textDim)),
          const SizedBox(height: 4),
          const Text(
              'Demo build - in-memory data only.\nRefresh resets the board.',
              style: TextStyle(
                  color: AppColors.textFaint, fontSize: 11, height: 1.35)),
        ],
      ),
    );
  }
}

class Brand extends StatelessWidget {
  const Brand({super.key});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 20),
      decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: AppColors.border))),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: EdgeInsets.only(top: 5),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                      color: AppColors.teal,
                      borderRadius: BorderRadius.all(Radius.circular(2))),
                  child: SizedBox(width: 9, height: 9),
                ),
              ),
              SizedBox(width: 8),
              Expanded(
                  child: Text('EMERGENCY RESOURCE\nALLOCATION SYSTEM',
                      style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 13,
                          height: 1.2))),
            ],
          ),
          SizedBox(height: 4),
          Text('SECTOR 4 · DISPATCH',
              style: TextStyle(
                  color: AppColors.textFaint,
                  fontSize: 11,
                  fontFamily: 'IBM Plex Mono')),
        ],
      ),
    );
  }
}

class NavButton extends StatelessWidget {
  const NavButton(
      {super.key,
      required this.label,
      required this.icon,
      required this.active,
      required this.onTap,
      this.count});
  final String label;
  final IconData icon;
  final bool active;
  final VoidCallback onTap;
  final String? count;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Material(
        color: active ? AppColors.surface2 : Colors.transparent,
        borderRadius: BorderRadius.circular(5),
        child: InkWell(
          borderRadius: BorderRadius.circular(5),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            decoration: BoxDecoration(
                border: active
                    ? const Border(
                        left: BorderSide(color: AppColors.teal, width: 2))
                    : null),
            child: Row(
              children: [
                Icon(icon,
                    size: 16,
                    color: active ? AppColors.text : AppColors.textDim),
                const SizedBox(width: 10),
                Expanded(
                    child: Text(label,
                        style: TextStyle(
                            fontSize: 13,
                            color:
                                active ? AppColors.text : AppColors.textDim))),
                if (count != null)
                  Text(count!,
                      style: monoStyle(size: 11, color: AppColors.textFaint)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Desktop Top Bar ────────────────────────────────────────────────────────────

class DesktopTopBar extends StatelessWidget {
  const DesktopTopBar(
      {super.key,
      required this.title,
      required this.subtitle,
      required this.pending,
      required this.active,
      required this.unmatched});
  final String title, subtitle;
  final int pending, active, unmatched;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: AppColors.border))),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(subtitle,
                    style: const TextStyle(
                        fontSize: 12, color: AppColors.textFaint)),
              ],
            ),
          ),
          Wrap(
            spacing: 20,
            children: [
              Stat(label: 'Pending', value: pending, color: AppColors.amber),
              Stat(label: 'En route', value: active, color: AppColors.blue),
              Stat(label: 'Unmatched', value: unmatched, color: AppColors.red),
            ],
          ),
        ],
      ),
    );
  }
}

class Stat extends StatelessWidget {
  const Stat(
      {super.key,
      required this.label,
      required this.value,
      required this.color});
  final String label;
  final int value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text('$value',
            style: monoStyle(size: 20, color: color, weight: FontWeight.w600)),
        Text(label.toUpperCase(),
            style: const TextStyle(
                fontSize: 10.5, color: AppColors.textFaint, letterSpacing: .6)),
      ],
    );
  }
}

// ── Panel ──────────────────────────────────────────────────────────────────────

class Panel extends StatelessWidget {
  const Panel(
      {super.key,
      required this.title,
      required this.hint,
      required this.child});
  final String title, hint;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
          color: AppColors.surface,
          border: Border.all(color: AppColors.border),
          borderRadius: BorderRadius.circular(6)),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Expanded(
                    child: Text(title,
                        style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textDim))),
                Flexible(
                    child: Text(hint,
                        style: const TextStyle(
                            fontSize: 11, color: AppColors.textFaint),
                        overflow: TextOverflow.ellipsis)),
              ],
            ),
          ),
          const Divider(height: 1, color: AppColors.border),
          child,
        ],
      ),
    );
  }
}

// ── Board Panel ────────────────────────────────────────────────────────────────

class BoardPanel extends StatelessWidget {
  const BoardPanel({
    super.key,
    required this.requests,
    required this.onEscalate,
    required this.onAccept,
    required this.onAllocate,
    required this.onCancelAllocation,
    this.isMobile = false,
  });

  final List<EmergencyRequest> requests;
  final ValueChanged<String> onEscalate;
  final ValueChanged<String> onAccept;
  final ValueChanged<String> onAllocate;
  final ValueChanged<String> onCancelAllocation;
  final bool isMobile;

  @override
  Widget build(BuildContext context) {
    return Panel(
      title: 'ACTIVE REQUESTS',
      hint: isMobile ? '' : 'Sorted by time received',
      child: requests.isEmpty
          ? const EmptyState(
              'No active requests. Submit one from "New request."')
          : isMobile
              ? _MobileRequestList(
                  requests: requests,
                  onEscalate: onEscalate,
                  onAccept: onAccept,
                  onAllocate: onAllocate,
                  onCancelAllocation: onCancelAllocation,
                )
  
              : SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: DataTable(
                    headingTextStyle: tableHeadStyle(),
                    dataTextStyle:
                        const TextStyle(fontSize: 13, color: AppColors.text),
                    columns: const [
                      DataColumn(label: Text('ID')),
                      DataColumn(label: Text('Resource')),
                      DataColumn(label: Text('District')),
                      DataColumn(label: Text('Distance')),
                      DataColumn(label: Text('Status')),
                      DataColumn(label: Text('Responder')),
                      DataColumn(label: Text('ETA')),
                      DataColumn(label: Text('')),
                    ],
                    rows: requests
                        .map((r) => DataRow(cells: [
                              DataCell(Text(r.id,
                                  style: monoStyle(
                                      size: 12.5, color: AppColors.textDim))),
                              DataCell(ResourceLabel(type: r.type)),
                              DataCell(Text(r.district)),
                              DataCell(Text(
                                  r.distanceKm == null
                                      ? '-'
                                      : '${r.distanceKm!.toStringAsFixed(1)} km',
                                  style: const TextStyle(
                                      fontSize: 11.5,
                                      color: AppColors.textFaint))),
                              DataCell(StatusPill(status: r.status)),
                              DataCell(Text(r.responder ?? 'unassigned',
                                  style: TextStyle(
                                      fontSize: 12.5,
                                      color: r.responder == null
                                          ? AppColors.textFaint
                                          : AppColors.textDim))),
                              DataCell(Text(_etaText(r),
                                  style: monoStyle(
                                      size: 12.5,
                                      color: (r.etaRemaining ?? 99) <= 2
                                          ? AppColors.amber
                                          : AppColors.textDim))),
                              DataCell(
                                ApiService.currentRole == 'RESPONDER' &&
                                        r.allocationId != null
                                    ? OutlinedButton(
                                        onPressed: () =>
                                            onCancelAllocation(r.id),
                                        style: OutlinedButton.styleFrom(
                                          foregroundColor: AppColors.red,
                                          side: const BorderSide(
                                            color: AppColors.red,
                                          ),
                                          shape: RoundedRectangleBorder(
                                            borderRadius:
                                                BorderRadius.circular(4),
                                          ),
                                        ),
                                        child: const Text(
                                          'Cancel',
                                          style: TextStyle(fontSize: 11),
                                        ),
                                      )
                                    : ApiService.currentRole == 'RESPONDER' &&
                                            r.status == RequestStatus.pending
                                        ? OutlinedButton(
                                            onPressed: () => onAccept(r.id),
                                            style: OutlinedButton.styleFrom(
                                              foregroundColor: AppColors.teal,
                                              side: const BorderSide(
                                                color: AppColors.teal,
                                              ),
                                              shape: RoundedRectangleBorder(
                                                borderRadius:
                                                    BorderRadius.circular(4),
                                              ),
                                            ),
                                            child: const Text(
                                              'Accept',
                                              style: TextStyle(fontSize: 11),
                                            ),
                                          )
                                        : ApiService.currentRole ==
                                                    'RESPONDER' &&
                                                (r.status ==
                                                        RequestStatus.enroute ||
                                                    r.status ==
                                                        RequestStatus
                                                            .partiallyAllocated)
                                            ? OutlinedButton(
                                                onPressed: () =>
                                                    onAllocate(r.id),
                                                style:
                                                    OutlinedButton.styleFrom(
                                                  foregroundColor:
                                                      AppColors.teal,
                                                  side: const BorderSide(
                                                    color: AppColors.teal,
                                                  ),
                                                  shape: RoundedRectangleBorder(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                            4),
                                                  ),
                                                ),
                                                child: const Text(
                                                  'Allocate',
                                                  style:
                                                      TextStyle(fontSize: 11),
                                                ),
                                              )
                                            : r.status ==
                                                    RequestStatus.unmatched
                                                ? OutlinedButton(
                                                    onPressed: () =>
                                                        onEscalate(r.id),
                                                    style: OutlinedButton
                                                        .styleFrom(
                                                      foregroundColor:
                                                          AppColors.red,
                                                      side: const BorderSide(
                                                        color: AppColors.red,
                                                      ),
                                                      shape:
                                                          RoundedRectangleBorder(
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                                4),
                                                      ),
                                                    ),
                                                    child: const Text(
                                                      'Escalate',
                                                      style: TextStyle(
                                                          fontSize: 11),
                                                    ),
                                                  )
                                                : const SizedBox.shrink(),
                              ),
                            ]))
                        .toList(),
                  ),
                ),
    );
  }

  String _etaText(EmergencyRequest r) {
    if (r.status == RequestStatus.enroute) return '${r.etaRemaining} min';
    if (r.status == RequestStatus.arrived) {
      return 'on scene';
    }
    return '-';
  }
}

class _MobileRequestList extends StatelessWidget {
  const _MobileRequestList({
    required this.requests,
    required this.onEscalate,
    required this.onAccept,
    required this.onAllocate,
    required this.onCancelAllocation,
  });


  final List<EmergencyRequest> requests;
  final ValueChanged<String> onEscalate;
  final ValueChanged<String> onAccept;
  final ValueChanged<String> onAllocate;
  final ValueChanged<String> onCancelAllocation;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: requests.map((r) {
        final meta = typeMeta(r.type);
        String etaText = '-';
        if (r.status == RequestStatus.enroute) {
          etaText = '${r.etaRemaining} min';
        }
        if (r.status == RequestStatus.arrived) {
          etaText = 'on scene';
        }

        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: AppColors.border))),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(r.id,
                      style: monoStyle(
                          size: 12.5,
                          color: AppColors.textDim,
                          weight: FontWeight.w600)),
                  const SizedBox(width: 8),
                  StatusPill(status: r.status),
                  const Spacer(),
                  Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                        color: meta.bg, borderRadius: BorderRadius.circular(5)),
                    child: Icon(meta.icon, size: 15, color: meta.color),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                      child: _InfoChip(label: 'District', value: r.district)),
                  Expanded(
                      child: _InfoChip(
                          label: 'Responder',
                          value: r.responder ?? 'unassigned')),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                      child: _InfoChip(
                          label: 'Distance',
                          value: r.distanceKm == null
                              ? '-'
                              : '${r.distanceKm!.toStringAsFixed(1)} km')),
                  Expanded(child: _InfoChip(label: 'ETA', value: etaText)),
                ],
              ),
              if (ApiService.currentRole == 'RESPONDER' &&
    r.status == RequestStatus.pending) ...[
  const SizedBox(height: 10),
  SizedBox(
    width: double.infinity,
    child: OutlinedButton(
      onPressed: () => onAccept(r.id),
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.teal,
        side: const BorderSide(
          color: AppColors.teal,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(5),
        ),
        padding: const EdgeInsets.symmetric(vertical: 10),
      ),
      child: const Text(
        'Accept Emergency',
        style: TextStyle(fontSize: 12),
      ),
    ),
  ),
],
              if (ApiService.currentRole == 'RESPONDER' &&
                  (r.status == RequestStatus.enroute ||
                      r.status == RequestStatus.partiallyAllocated)) ...[
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: () => onAllocate(r.id),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.blue,
                      side: const BorderSide(
                        color: AppColors.blue,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(5),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 10),
                    ),
                    child: const Text(
                      'Allocate Resource',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                ),
              ],
              if (ApiService.currentRole == 'RESPONDER' &&
                  r.allocationId != null) ...[
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: () => onCancelAllocation(r.id),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.red,
                      side: const BorderSide(
                        color: AppColors.red,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    child: const Text(
                      'Cancel Allocation',
                      style: TextStyle(fontSize: 11),
                    ),
                  ),
                ),
              ],
              if (r.status == RequestStatus.unmatched) ...[
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: () => onEscalate(r.id),
                    style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.red,
                        side: const BorderSide(color: AppColors.red),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(5)),
                        padding: const EdgeInsets.symmetric(vertical: 10)),
                    child: const Text('Escalate to regional coordination',
                        style: TextStyle(fontSize: 12)),
                  ),
                ),
              ],
            ],
          ),
        );
      }).toList(),
    );
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({required this.label, required this.value});
  final String label, value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label.toUpperCase(),
              style: const TextStyle(
                  fontSize: 9.5,
                  color: AppColors.textFaint,
                  letterSpacing: .5)),
          const SizedBox(height: 1),
          Text(value,
              style: const TextStyle(fontSize: 12.5, color: AppColors.text),
              maxLines: 1,
              overflow: TextOverflow.ellipsis),
        ],
      ),
    );
  }
}

// ── New Request Panel ──────────────────────────────────────────────────────────

class NewRequestPanel extends StatelessWidget {
  const NewRequestPanel({
    super.key,
    required this.selectedType,
    required this.selectedDistrict,
    required this.selectedUrgency,
    required this.districts,
    required this.onTypeChanged,
    required this.onDistrictChanged,
    required this.onUrgencyChanged,
    required this.onSubmit,
  });
  final ResourceType selectedType;
  final String selectedDistrict;
  final Urgency selectedUrgency;
  final List<String> districts;
  final ValueChanged<ResourceType> onTypeChanged;
  final ValueChanged<String> onDistrictChanged;
  final ValueChanged<Urgency> onUrgencyChanged;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    return Panel(
      title: 'SUBMIT REQUEST',
      hint: 'Auto-matched against available responders',
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final narrow = constraints.maxWidth < 600;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (narrow) ...[
                  _FieldLabel('Resource type'),
                  const SizedBox(height: 6),
                  _typeDropdown(double.infinity),
                  const SizedBox(height: 12),
                  _FieldLabel('District'),
                  const SizedBox(height: 6),
                  _districtDropdown(double.infinity),
                  const SizedBox(height: 12),
                  _FieldLabel('Urgency'),
                  const SizedBox(height: 6),
                  _urgencyDropdown(double.infinity),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: onSubmit,
                      style: FilledButton.styleFrom(
                          backgroundColor: AppColors.teal,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(5)),
                          padding: const EdgeInsets.symmetric(vertical: 14)),
                      child: const Text('Submit request',
                          style: TextStyle(fontSize: 14)),
                    ),
                  ),
                ] else ...[
                  Row(
                    children: [
                      Expanded(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                            _FieldLabel('Resource type'),
                            const SizedBox(height: 6),
                            _typeDropdown(double.infinity)
                          ])),
                      const SizedBox(width: 12),
                      Expanded(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                            _FieldLabel('District'),
                            const SizedBox(height: 6),
                            _districtDropdown(double.infinity)
                          ])),
                      const SizedBox(width: 12),
                      Expanded(
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                            _FieldLabel('Urgency'),
                            const SizedBox(height: 6),
                            _urgencyDropdown(double.infinity)
                          ])),
                      const SizedBox(width: 12),
                      Expanded(
                          child: Padding(
                        padding: const EdgeInsets.only(top: 22),
                        child: FilledButton(
                          onPressed: onSubmit,
                          style: FilledButton.styleFrom(
                              backgroundColor: AppColors.teal,
                              shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(5)),
                              padding:
                                  const EdgeInsets.symmetric(vertical: 14)),
                          child: const Text('Submit request'),
                        ),
                      )),
                    ],
                  ),
                ],
                const SizedBox(height: 12),
                const Text(
                  'The matcher scores available responders by resource type and straight-line distance to the district, then dispatches the closest match. If none are free, the request is flagged unmatched for escalation.',
                  style: TextStyle(
                      fontSize: 11.5, color: AppColors.textFaint, height: 1.5),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _typeDropdown(double width) =>
    DropdownButtonFormField<ResourceType>(
      initialValue: selectedType,
      isExpanded: true,
      decoration: fieldDecoration(),
      items: ResourceType.values
          .map(
            (type) => DropdownMenuItem<ResourceType>(
              value: type,
              child: Text(titleCase(type.name)),
            ),
          )
          .toList(),
      onChanged: (v) {
        if (v != null) {
          onTypeChanged(v);
        }
      },
    );
    Widget _districtDropdown(double width) =>
    DropdownButtonFormField<String>(
      initialValue: selectedDistrict,
      isExpanded: true,
      decoration: fieldDecoration(),
      items: districts
          .map(
            (d) => DropdownMenuItem<String>(
              value: d,
              child: Text(d),
            ),
          )
          .toList(),
      onChanged: (v) {
        if (v != null) {
          onDistrictChanged(v);
        }
      },
    );
  Widget _urgencyDropdown(double width) => DropdownButtonFormField<Urgency>(
        initialValue: selectedUrgency,
        isExpanded: true,
        decoration: fieldDecoration(),
        items: Urgency.values
            .map((u) =>
                DropdownMenuItem(value: u, child: Text(titleCase(u.name))))
            .toList(),
        onChanged: (v) {
          if (v != null) {
            onUrgencyChanged(v);
          }
        },
      );
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Text(text.toUpperCase(),
      style: const TextStyle(
          fontSize: 11, color: AppColors.textFaint, letterSpacing: .5));
}

// ── Responders Panel ───────────────────────────────────────────────────────────
class BackendRespondersPanel extends StatelessWidget {
  const BackendRespondersPanel({
    super.key,
    required this.responders,
    this.isMobile = false,
  });

  final List<BackendResponder> responders;
  final bool isMobile;

  Color statusColor(String status) {
    switch (status) {
      case 'AVAILABLE':
        return AppColors.teal;
      case 'BUSY':
        return AppColors.amber;
      default:
        return AppColors.textFaint;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Panel(
      title: 'LIVE RESPONDERS',
      hint: 'Responders loaded from PostgreSQL',
      child: responders.isEmpty
          ? const EmptyState(
              'No responders found in the database.',
            )
          : Padding(
              padding: const EdgeInsets.fromLTRB(0, 6, 0, 0),
              child: Column(
                children: responders.map((r) {
                  final color = statusColor(r.status);

                  return Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: isMobile ? 14 : 16,
                      vertical: 12,
                    ),
                    decoration: const BoxDecoration(
                      border: Border(
                        bottom: BorderSide(
                          color: AppColors.border,
                        ),
                      ),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment:
                                CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${r.name}  •  ID ${r.id}',
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                r.email,
                                style: const TextStyle(
                                  fontSize: 11.5,
                                  color: AppColors.textFaint,
                                ),
                              ),
                              if (r.location != null &&
                                  r.location!.isNotEmpty) ...[
                                const SizedBox(height: 3),
                                Text(
                                  r.location!,
                                  style: const TextStyle(
                                    fontSize: 11.5,
                                    color: AppColors.textDim,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                        Text(
                          r.status,
                          style: monoStyle(
                            size: 11,
                            color: color,
                            weight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ),
            ),
    );
  }
}
class ResourceCatalogPanel extends StatelessWidget {
  const ResourceCatalogPanel({
    super.key,
    required this.resources,
    this.isMobile = false,
  });

  final List<BackendResource> resources;
  final bool isMobile;

  @override
  Widget build(BuildContext context) {
    return Panel(
      title: 'RESOURCE CATALOG',
      hint: 'Live resources from PostgreSQL',
      child: resources.isEmpty
          ? const EmptyState(
              'No resources found in the database.',
            )
          : Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: resources.map((resource) {
                  return Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 12,
                    ),
                    decoration: const BoxDecoration(
                      border: Border(
                        bottom: BorderSide(
                          color: AppColors.border,
                        ),
                      ),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            resource.name,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        Text(
                          'ID ${resource.id}',
                          style: monoStyle(
                            size: 11,
                            color: AppColors.textFaint,
                          ),
                        ),
                        const SizedBox(width: 18),
                        Text(
                          '${resource.availableQuantity}/${resource.totalQuantity}',
                          style: monoStyle(
                            size: 12,
                            color: AppColors.textDim,
                          ),
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ),
            ),
    );
  }
}
class ResponderResourcesPanel extends StatelessWidget {
  const ResponderResourcesPanel({
    super.key,
    required this.resources,
  });

  final List<BackendResponderResource> resources;

  @override
  Widget build(BuildContext context) {
    return Panel(
      title: 'RESPONDER INVENTORY',
      hint: 'Live inventory from PostgreSQL',
      child: resources.isEmpty
          ? const EmptyState(
              'No responder resources found in the database.',
            )
          : Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: resources.map((item) {
                  return Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 14,
                    ),
                    decoration: const BoxDecoration(
                      border: Border(
                        bottom: BorderSide(
                          color: AppColors.border,
                        ),
                      ),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment:
                                CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${item.responderName}  •  ID ${item.responderId}',
                                style: const TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                item.resourceName,
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: AppColors.textDim,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Text(
                          '${item.availableQuantity}/${item.totalQuantity}',
                          style: monoStyle(
                            size: 12,
                            color: AppColors.textDim,
                          ),
                        ),
                        const SizedBox(width: 16),
                        Text(
                          item.status,
                          style: monoStyle(
                            size: 11,
                            color: AppColors.textDim,
                            weight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ),
            ),
    );
  }
}
// ── Log Panel ──────────────────────────────────────────────────────────────────

class LogPanel extends StatelessWidget {
  const LogPanel({super.key, required this.logEntries, this.isMobile = false});
  final List<EmergencyRequest> logEntries;
  final bool isMobile;

  @override
  Widget build(BuildContext context) {
    return Panel(
      title: 'CLOSED / AFTER-ACTION LOG',
      hint: 'Completed requests this session',
      child: logEntries.isEmpty
          ? const EmptyState('Nothing closed out yet.')
          : isMobile
              ? _MobileLogList(logEntries: logEntries)
              : SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: DataTable(
                    headingTextStyle: tableHeadStyle(),
                    columns: const [
                      DataColumn(label: Text('ID')),
                      DataColumn(label: Text('Resource')),
                      DataColumn(label: Text('District')),
                      DataColumn(label: Text('Responder')),
                      DataColumn(label: Text('Total time')),
                    ],
                    rows: logEntries
                        .take(25)
                        .map((e) => DataRow(cells: [
                              DataCell(Text(e.id,
                                  style: monoStyle(
                                      size: 12.5, color: AppColors.textDim))),
                              DataCell(Text(typeMeta(e.type).label)),
                              DataCell(Text(e.district)),
                              DataCell(Text(e.responder ?? '-')),
                              DataCell(Text('${e.totalSec ?? 0}s (sim)',
                                  style: monoStyle(
                                      size: 12.5, color: AppColors.textDim))),
                            ]))
                        .toList(),
                  ),
                ),
    );
  }
}

class _MobileLogList extends StatelessWidget {
  const _MobileLogList({required this.logEntries});
  final List<EmergencyRequest> logEntries;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: logEntries.take(25).map((e) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: AppColors.border))),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(e.id,
                        style: monoStyle(
                            size: 12.5,
                            color: AppColors.textDim,
                            weight: FontWeight.w600)),
                    const SizedBox(height: 3),
                    Text('${typeMeta(e.type).label} · ${e.district}',
                        style: const TextStyle(
                            fontSize: 12, color: AppColors.textDim)),
                    const SizedBox(height: 2),
                    Text('Responder: ${e.responder ?? '-'}',
                        style: const TextStyle(
                            fontSize: 11.5, color: AppColors.textFaint)),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                    color: AppColors.surface2,
                    borderRadius: BorderRadius.circular(4)),
                child: Text('${e.totalSec ?? 0}s',
                    style: monoStyle(size: 12, color: AppColors.textDim)),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }
}

// ── Utility Widgets ────────────────────────────────────────────────────────────

class EmptyState extends StatelessWidget {
  const EmptyState(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(32),
        child: Center(
            child: Text(text,
                style:
                    const TextStyle(fontSize: 13, color: AppColors.textFaint),
                textAlign: TextAlign.center)),
      );
}

class LegendItem extends StatelessWidget {
  const LegendItem({super.key, required this.color, required this.label});
  final Color color;
  final String label;
  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 5),
          Text(label,
              style: const TextStyle(fontSize: 11.5, color: AppColors.textDim)),
        ],
      );
}

class ResourceLabel extends StatelessWidget {
  const ResourceLabel({super.key, required this.type});
  final ResourceType type;
  @override
  Widget build(BuildContext context) {
    final meta = typeMeta(type);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
            width: 20,
            height: 20,
            decoration: BoxDecoration(
                color: meta.bg, borderRadius: BorderRadius.circular(4)),
            child: Icon(meta.icon, size: 13, color: meta.color)),
        const SizedBox(width: 7),
        Text(meta.label),
      ],
    );
  }
}

class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.status});
  final RequestStatus status;
  @override
  Widget build(BuildContext context) {
    final colors = statusColors(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
          color: colors.background, borderRadius: BorderRadius.circular(20)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
              width: 5,
              height: 5,
              decoration:
                  BoxDecoration(color: colors.text, shape: BoxShape.circle)),
          const SizedBox(width: 5),
          Text(statusLabel(status),
              style: monoStyle(
                  size: 11, color: colors.text, weight: FontWeight.w500)),
        ],
      ),
    );
  }
}

// ── Sector Map ─────────────────────────────────────────────────────────────────

class SectorMapPainter extends CustomPainter {
  SectorMapPainter(
      {required this.districts,
      required this.responders,
      required this.requests});
  final List<District> districts;
  final List<Responder> responders;
  final List<EmergencyRequest> requests;

  @override
  void paint(Canvas canvas, Size size) {
    final scaleX = size.width / 640;
    final scaleY = size.height / 260;
    Offset mapPoint(Offset p) => Offset(p.dx * scaleX, p.dy * scaleY);

    final linePaint = Paint()
      ..color = const Color(0xFFC7CEE2).withValues(alpha: .35)
      ..strokeWidth = 1;
    for (var i = 0; i < districts.length; i++) {
      for (var j = i + 1; j < districts.length; j++) {
        canvas.drawLine(mapPoint(districts[i].point),
            mapPoint(districts[j].point), linePaint);
      }
    }

    final textPainter = TextPainter(
        textDirection: TextDirection.ltr, textAlign: TextAlign.center);
    for (final d in districts) {
      final p = mapPoint(d.point);
      canvas.drawCircle(p, 3, Paint()..color = AppColors.textFaint);
      textPainter.text = TextSpan(
          text: d.name, style: monoStyle(size: 9, color: AppColors.textDim));
      textPainter.layout();
      textPainter.paint(
          canvas, Offset(p.dx - textPainter.width / 2, p.dy - 20));
    }

    final byDistrict = <String, List<Responder>>{};
    for (final r in responders) {
      byDistrict.putIfAbsent(r.district, () => []).add(r);
    }
    byDistrict.forEach((name, grouped) {
      final base = mapPoint(districts.firstWhere((d) => d.name == name).point);
      for (var i = 0; i < grouped.length; i++) {
        final angle = (i / grouped.length) * pi * 2;
        final p = Offset(base.dx + cos(angle) * 16 * scaleX,
            base.dy + sin(angle) * 16 * scaleY + 16 * scaleY);
        canvas.drawCircle(
            p, 4, Paint()..color = responderStatusColor(grouped[i].status));
      }
    });

    for (final r in requests) {
      if (r.status != RequestStatus.pending &&
          r.status != RequestStatus.unmatched) {
        continue;
      }
      final p =
          mapPoint(districts.firstWhere((d) => d.name == r.district).point);
      final color =
          r.status == RequestStatus.unmatched ? AppColors.red : AppColors.amber;
      canvas.drawCircle(
          p,
          9,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..color = color.withValues(alpha: .6));
      canvas.drawCircle(p, 4, Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(covariant SectorMapPainter old) => true;
}

// ── Helpers ────────────────────────────────────────────────────────────────────

ResourceMeta typeMeta(ResourceType type) => switch (type) {
      ResourceType.ambulance => const ResourceMeta(
          'Ambulance', Icons.local_hospital, AppColors.redDim, AppColors.red),
      ResourceType.blood => const ResourceMeta(
          'Blood unit', Icons.water_drop, Color(0xFFFCE4F3), Color(0xFFC23E96)),
      ResourceType.volunteer => const ResourceMeta(
          'Volunteer team', Icons.groups, AppColors.tealDim, AppColors.teal),
    };

class PillColors {
  const PillColors(this.background, this.text);
  final Color background, text;
}

PillColors statusColors(RequestStatus s) => switch (s) {
      RequestStatus.pending =>
        const PillColors(AppColors.amberDim, AppColors.amber),
      RequestStatus.enroute =>
        const PillColors(Color(0xFFE7EDFB), AppColors.blue),
      RequestStatus.partiallyAllocated =>
        const PillColors(Color(0xFFE7EDFB), AppColors.blue),
      RequestStatus.arrived =>
        const PillColors(AppColors.tealDim, AppColors.teal),
      RequestStatus.unmatched =>
        const PillColors(AppColors.redDim, AppColors.red),
      RequestStatus.closed =>
        const PillColors(AppColors.surface2, AppColors.textFaint),
    };

String statusLabel(RequestStatus s) => switch (s) {
      RequestStatus.pending => 'Pending',
      RequestStatus.enroute => 'En route',
      RequestStatus.partiallyAllocated => 'PARTIAL',
      RequestStatus.arrived => 'Arrived',
      RequestStatus.unmatched => 'Unmatched',
      RequestStatus.closed => 'Closed',
    };

String responderStatusLabel(ResponderStatus s) => switch (s) {
      ResponderStatus.available => 'AVAILABLE',
      ResponderStatus.enroute => 'EN ROUTE',
      ResponderStatus.off => 'OFF DUTY',
    };

Color responderStatusColor(ResponderStatus s) => switch (s) {
      ResponderStatus.available => AppColors.teal,
      ResponderStatus.enroute => AppColors.blue,
      ResponderStatus.off => AppColors.textFaint,
    };

InputDecoration fieldDecoration() => InputDecoration(
      isDense: true,
      filled: true,
      fillColor: AppColors.surface2,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      enabledBorder: OutlineInputBorder(
          borderSide: const BorderSide(color: AppColors.border),
          borderRadius: BorderRadius.circular(5)),
      focusedBorder: OutlineInputBorder(
          borderSide: const BorderSide(color: AppColors.blue, width: 2),
          borderRadius: BorderRadius.circular(5)),
    );

TextStyle monoStyle(
        {required double size, required Color color, FontWeight? weight}) =>
    TextStyle(
        fontFamily: 'IBM Plex Mono',
        fontSize: size,
        color: color,
        fontWeight: weight);

TextStyle tableHeadStyle() => const TextStyle(
    fontSize: 10.5,
    color: AppColors.textFaint,
    letterSpacing: .6,
    fontWeight: FontWeight.w500);

String titleCase(String value) =>
    value.substring(0, 1).toUpperCase() + value.substring(1);

T? firstWhereOrNull<T>(Iterable<T> items, bool Function(T) test) {
  for (final item in items) {
    if (test(item)) return item;
  }
  return null;
}
