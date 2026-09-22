import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:codex_timezone/services/desktop_services.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(
    () => messenger.setMockMethodCallHandler(SystemChannels.platform, null),
  );
  test('clipboard success requires read-back of the exact IP', () async {
    String? clipboard;
    final calls = <String>[];
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      calls.add(call.method);
      if (call.method == 'Clipboard.setData') {
        clipboard = (call.arguments as Map)['text'] as String;
      }
      if (call.method == 'Clipboard.getData') return {'text': clipboard};
      return null;
    });
    await const SystemDesktopServices().copyVerified('2001:db8::1');
    expect(calls, ['Clipboard.setData', 'Clipboard.getData']);
    expect(clipboard, '2001:db8::1');
  });
  test('clipboard mismatch is surfaced as failure', () async {
    messenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async =>
          call.method == 'Clipboard.getData' ? {'text': 'different'} : null,
    );
    await expectLater(
      const SystemDesktopServices().copyVerified('192.0.2.1'),
      throwsStateError,
    );
  });
}
