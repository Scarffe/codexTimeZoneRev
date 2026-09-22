import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'backend.dart';

abstract interface class NetworkTransport {
  Future<String> get(Uri uri);
  void close();
}

typedef ProxyLookup = Future<String> Function(Uri uri);
typedef TransportFactory = NetworkTransport Function();

class SystemProxyResolver {
  SystemProxyResolver({this._backend = const NativeBackend()});
  final LauncherBackend _backend;
  final Map<Uri, Future<String>> _inFlight = {};

  Future<String> resolve(Uri uri) => _inFlight.putIfAbsent(uri, () async {
    try {
      final data = await Future.sync(
        () => _backend.call('proxy_for_url', {'url': uri.toString()}),
      );
      final proxy = data['proxy'];
      if (proxy is! String || proxy.isEmpty) throw StateError('系统代理解析未返回有效结果。');
      return proxy;
    } finally {
      _inFlight.remove(uri);
    }
  });
}

final _proxyResolver = SystemProxyResolver();
NetworkTransport desktopTransport() {
  if (Platform.isMacOS) return MacNetworkTransport();
  if (Platform.isWindows) return ProxyHttpTransport(_proxyResolver.resolve);
  throw UnsupportedError('仅支持 Windows 和 macOS。');
}

/// The proxy is resolved for every destination, including redirect targets.
/// One instance belongs to one provider race and is closed on cancellation.
class ProxyHttpTransport implements NetworkTransport {
  ProxyHttpTransport(this.lookup);
  final ProxyLookup lookup;
  final HttpClient _client = HttpClient();
  bool _closed = false;

  @override
  Future<String> get(Uri uri) async {
    for (var redirects = 0; redirects <= 5; redirects++) {
      if (_closed) throw StateError('网络请求已取消。');
      if (!['http', 'https'].contains(uri.scheme) ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty) {
        throw const FormatException('仅支持不含认证信息的 HTTP(S) URL');
      }
      final proxy = await lookup(uri);
      if (_closed) throw StateError('网络请求已取消。');
      _client.findProxy = (_) => proxy;
      final request = await _client.getUrl(uri);
      request.followRedirects = false;
      request.headers.set(HttpHeaders.cacheControlHeader, 'no-cache');
      final response = await request.close();
      if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        if (location == null || redirects == 5) {
          throw const HttpException('无效或过多的网络重定向');
        }
        await response.drain<void>();
        uri = uri.resolve(location);
        continue;
      }
      if (response.statusCode != 200) {
        throw HttpException('HTTP ${response.statusCode}');
      }
      final bytes = <int>[];
      await for (final chunk in response) {
        if (bytes.length + chunk.length > 1024 * 1024) {
          throw const HttpException('网络响应过大');
        }
        bytes.addAll(chunk);
      }
      return utf8.decode(bytes);
    }
    throw const HttpException('过多的网络重定向');
  }

  @override
  void close() {
    _closed = true;
    _client.close(force: true);
  }
}

/// URLSession uses macOS's system HTTP/SOCKS/PAC configuration and TLS store.
class MacNetworkTransport implements NetworkTransport {
  static const channel = MethodChannel('codex_timezone/network');
  static int _nextId = 0;
  final Set<int> _pending = {};
  bool _closed = false;

  @override
  Future<String> get(Uri uri) async {
    if (_closed) throw StateError('网络请求已取消。');
    final id = ++_nextId;
    _pending.add(id);
    try {
      final value = await channel.invokeMethod<String>('get', {
        'id': id,
        'url': uri.toString(),
      });
      if (_closed) throw StateError('网络请求已取消。');
      if (value == null) throw StateError('系统网络通道未返回数据。');
      return value;
    } finally {
      _pending.remove(id);
    }
  }

  @override
  void close() {
    _closed = true;
    for (final id in _pending) {
      unawaited(
        channel
            .invokeMethod<void>('cancel', {'id': id})
            .catchError((Object _) {}),
      );
    }
    _pending.clear();
  }
}
