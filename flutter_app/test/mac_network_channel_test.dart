import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:codex_timezone/services/network_transport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('macOS cancellation targets the matching URLSession task', () async {
    final pending = Completer<String>();
    final requested = Completer<int>();
    final cancelled = Completer<int>();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(MacNetworkTransport.channel, (
      call,
    ) async {
      final id = (call.arguments as Map)['id'] as int;
      if (call.method == 'get') {
        requested.complete(id);
        return pending.future;
      }
      cancelled.complete(id);
      pending.complete('late response');
      return null;
    });
    addTearDown(
      () =>
          messenger.setMockMethodCallHandler(MacNetworkTransport.channel, null),
    );
    final transport = MacNetworkTransport();
    final response = transport.get(Uri.parse('https://example.invalid/'));
    final expectation = expectLater(response, throwsStateError);
    final id = await requested.future;
    transport.close();
    expect(await cancelled.future, id);
    await expectation;
  });
}
