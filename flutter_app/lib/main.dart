import 'package:flutter/widgets.dart';
import 'package:timezone/data/latest_all.dart' as timezone;

import 'app/application.dart';
import 'services/window_material.dart';

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  timezone.initializeTimeZones();
  final acrylic = await WindowMaterial.initialize(
    enabled: !arguments.contains('--solid-background'),
  );
  runApp(
    LauncherApplication(
      acrylicEnabled: acrylic,
      selectedSessionPath: arguments
          .where((a) => a.startsWith('--observe-session='))
          .map((a) => a.substring('--observe-session='.length))
          .firstOrNull,
      monitorEnabled: arguments.contains('--desktop-monitor'),
      // Test builds can exercise multiple automatic refreshes without long waits.
      monitorInterval: Duration(
        seconds: const int.fromEnvironment(
          'MONITOR_INTERVAL_SECONDS',
          defaultValue: 120,
        ),
      ),
      preview:
          arguments.contains('--preview') ||
          const bool.fromEnvironment('UI_PREVIEW'),
    ),
  );
}
