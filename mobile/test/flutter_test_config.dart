import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Runs around every test file: each test starts with an empty in-memory
/// SharedPreferences (the offline cache), so nothing leaks between tests and
/// nothing waits on a platform plugin that isn't there.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  await testMain();
}
