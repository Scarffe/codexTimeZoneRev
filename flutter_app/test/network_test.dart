import 'package:flutter_test/flutter_test.dart';
import 'package:codex_timezone/services/network_info.dart';

void main() {
  test('provider parser handles JSONP, IPv6 trace and rejects non-IP', () {
    expect(parseIp('({"ip":"192.0.2.1"})', 'json'), '192.0.2.1');
    expect(parseIp('fl=123\nip=2001:db8::1\n', 'trace'), '2001:db8::1');
    expect(() => parseIp('unavailable', 'text'), throwsFormatException);
  });
  test('provider race waits for success after early failure', () async {
    final result = await firstSuccess([
      Future<String>.error(StateError('offline')),
      Future<String>.value('192.0.2.1'),
    ]);
    expect(result, '192.0.2.1');
  });
  test('all failed providers terminate with an error', () async {
    await expectLater(
      firstSuccess([
        Future<String>.error(StateError('a')),
        Future<String>.error(StateError('b')),
      ]),
      throwsStateError,
    );
  });
}
