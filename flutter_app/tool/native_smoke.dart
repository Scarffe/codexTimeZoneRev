import 'dart:io';

import 'package:codex_timezone/services/backend.dart';

// Read-only native integration check: never save, launch, create a shortcut,
// or bootstrap (bootstrap may migrate an old user's settings).
Future<void> main() async {
  const backend = NativeBackend();
  final discovered = await backend.call('discover');
  if (discovered['path'] is! String) {
    throw StateError('Invalid discover response');
  }
  for (var i = 0; i < 10; i++) {
    try {
      await backend.call('unknown_smoke_command');
      throw Exception('Expected native error');
    } on StateError catch (error) {
      if (!error.toString().contains('未知命令')) rethrow;
    }
  }
  stdout.writeln(
    'Native smoke passed: discovery, background isolate calls, UTF-8 errors, 10 response allocations/releases.',
  );
}
