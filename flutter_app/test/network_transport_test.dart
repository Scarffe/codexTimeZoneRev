import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:codex_timezone/services/network_transport.dart';

void main() {
  test('HTTP request reaches selected proxy, not the target host', () async {
    final proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => proxy.close(force: true));
    final received = Completer<String>();
    proxy.listen((request) async {
      received.complete(request.uri.toString());
      request.response.write('via system proxy');
      await request.response.close();
    });
    final transport = ProxyHttpTransport(
      (uri) async => 'PROXY 127.0.0.1:${proxy.port}',
    );
    addTearDown(transport.close);
    expect(
      await transport
          .get(Uri.parse('http://target.invalid/test'))
          .timeout(const Duration(seconds: 3)),
      'via system proxy',
    );
    expect(await received.future, contains('target.invalid/test'));
  });

  test('redirect resolves the proxy again for its destination', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      if (request.uri.path == '/start') {
        request.response.statusCode = 302;
        request.response.headers.set('location', '/end');
      } else {
        request.response.write('redirected');
      }
      await request.response.close();
    });
    final lookedUp = <Uri>[];
    final transport = ProxyHttpTransport((uri) async {
      lookedUp.add(uri);
      return 'DIRECT';
    });
    addTearDown(transport.close);
    expect(
      await transport.get(Uri.parse('http://127.0.0.1:${server.port}/start')),
      'redirected',
    );
    expect(lookedUp.map((uri) => uri.path), ['/start', '/end']);
  });

  test('cancel during proxy discovery never starts a request', () async {
    final lookup = Completer<String>();
    final transport = ProxyHttpTransport((uri) => lookup.future);
    final request = transport.get(Uri.parse('http://unreachable.invalid/'));
    final expectation = expectLater(request, throwsStateError);
    transport.close();
    lookup.complete('DIRECT');
    await expectation;
  });

  test('cancel aborts an active socket request', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final received = Completer<void>();
    server.listen((request) {
      received.complete();
    });
    final transport = ProxyHttpTransport((_) async => 'DIRECT');
    final request = transport.get(
      Uri.parse('http://127.0.0.1:${server.port}/'),
    );
    final expectation = expectLater(request, throwsA(isA<Exception>()));
    await received.future.timeout(const Duration(seconds: 3));
    transport.close();
    await expectation;
  });
}
