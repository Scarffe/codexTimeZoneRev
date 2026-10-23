import 'dart:io';

import 'package:path/path.dart' as p;

/// Opens only the shipped document beside this executable. No URL fallback.
Future<void> openMonitoringGuide() async {
  final file = File(
    p.join(p.dirname(Platform.resolvedExecutable), 'docs', 'monitoring.md'),
  );
  if (!await file.exists()) {
    throw const FileSystemException('候选包中未找到 docs/monitoring.md');
  }
  final resolved = await file.resolveSymbolicLinks();
  if (!p.equals(p.normalize(file.absolute.path), p.normalize(resolved))) {
    throw const FileSystemException('本地说明路径不符合候选包位置');
  }
  if (Platform.isWindows) {
    await Process.start(
      p.join(
        Platform.environment['SystemRoot'] ?? r'C:\Windows',
        'explorer.exe',
      ),
      [file.absolute.path],
      mode: ProcessStartMode.detached,
    );
  } else {
    await Process.start(
      Platform.isMacOS ? '/usr/bin/open' : '/usr/bin/xdg-open',
      [file.absolute.path],
      mode: ProcessStartMode.detached,
    );
  }
}
