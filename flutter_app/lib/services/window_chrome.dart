import 'package:flutter/services.dart';

enum WindowChromeStatus { applied, partial, unsupported, failed }

class WindowChromeResult {
  const WindowChromeResult(this.status, [this.hresults = const {}]);
  final WindowChromeStatus status;
  final Map<String, int> hresults;
}

/// Synchronizes only this app's native frame, independently of blur/material.
/// Each application owner gets a queue so late native replies cannot reorder
/// a newer palette. Unsupported runners keep their normal system frame.
class WindowChrome {
  WindowChrome({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('codex_timezone/window');

  final MethodChannel _channel;
  Future<void> _pending = Future<void>.value();
  (bool, int, int, int)? _lastAppearance;
  WindowChromeResult? _lastResult;

  Future<WindowChromeResult> apply({
    required bool dark,
    required int captionArgb,
    required int textArgb,
    required int borderArgb,
  }) {
    final appearance = (
      dark,
      captionArgb & 0xffffffff,
      textArgb & 0xffffffff,
      borderArgb & 0xffffffff,
    );
    final next = _pending.then((_) => _apply(appearance));
    _pending = next.then<void>((_) {});
    return next;
  }

  Future<WindowChromeResult> _apply((bool, int, int, int) appearance) async {
    if (_lastAppearance == appearance && _lastResult != null) {
      return _lastResult!;
    }
    // A failed/ambiguous native call may have changed part of the frame. Do not
    // reuse the previous palette's success when returning to that palette.
    _lastAppearance = null;
    _lastResult = null;
    try {
      final reply = await _channel.invokeMapMethod<String, Object?>(
        'setAppearance',
        {
          'dark': appearance.$1,
          'captionArgb': appearance.$2,
          'textArgb': appearance.$3,
          'borderArgb': appearance.$4,
        },
      );
      final status = switch (reply?['status']) {
        'applied' => WindowChromeStatus.applied,
        'partial' => WindowChromeStatus.partial,
        'unsupported' => WindowChromeStatus.unsupported,
        _ => WindowChromeStatus.failed,
      };
      final hresults = <String, int>{};
      for (final field in ['dark', 'caption', 'text', 'border']) {
        final value = reply?['${field}Hresult'];
        if (value is int) hresults[field] = value;
      }
      if ((status == WindowChromeStatus.applied ||
              status == WindowChromeStatus.partial) &&
          hresults.length != 4) {
        return const WindowChromeResult(WindowChromeStatus.failed);
      }
      final result = WindowChromeResult(status, Map.unmodifiable(hresults));
      if (status != WindowChromeStatus.failed) {
        _lastAppearance = appearance;
        _lastResult = result;
      }
      return result;
    } on MissingPluginException {
      return const WindowChromeResult(WindowChromeStatus.unsupported);
    } on PlatformException {
      return const WindowChromeResult(WindowChromeStatus.failed);
    } on Object {
      // Malformed/unavailable platform replies must never break app theming.
      return const WindowChromeResult(WindowChromeStatus.failed);
    }
  }
}
