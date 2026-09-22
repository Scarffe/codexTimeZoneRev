import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_acrylic/flutter_acrylic.dart';

/// Native desktop blur; never changes the opacity of text or controls.
class WindowMaterial {
  static Future<bool> initialize({required bool enabled}) async {
    if (!enabled || !(Platform.isWindows || Platform.isMacOS)) return false;
    try {
      await Window.initialize();
      await apply(
        WidgetsBinding.instance.platformDispatcher.platformBrightness ==
            Brightness.dark,
      );
      return true;
    } catch (error) {
      debugPrint('Native acrylic unavailable; using solid background: $error');
      return false;
    }
  }

  static Future<void> apply(bool dark) => Window.setEffect(
    effect: WindowEffect.acrylic,
    dark: dark,
    color: dark ? const Color(0xb8202024) : const Color(0xb8f5f5f7),
  );
}
