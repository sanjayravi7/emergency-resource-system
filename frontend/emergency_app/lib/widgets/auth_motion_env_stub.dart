/// Web (and any platform without `dart:io`) fallback for test-environment
/// detection. Web builds never need this: it simply reports "not a test".
bool get isFlutterTestProcess => false;
