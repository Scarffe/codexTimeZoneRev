import 'dart:io';

import 'monitor_preferences.dart';

/// Independent portable selection file; never races with quota preference saves.
class SessionSelectionStore extends MonitorPreferencesStore {
  SessionSelectionStore(super.file);
  factory SessionSelectionStore.portable() => SessionSelectionStore(
    File(
      '${File(Platform.resolvedExecutable).parent.path}/session-selection-v1.json',
    ),
  );
}
