import 'dart:convert';
import 'dart:io';

import 'global_workbench.dart';

/// Only display preferences live in Dart; native owns index/cache persistence.
class GlobalPreferences {
  const GlobalPreferences({
    this.range = GlobalRange.days7,
    this.project,
    this.model,
    this.status,
    this.search = '',
    this.sort = 'recent',
  });
  final GlobalRange range;
  final String? project, model, status;
  final String search, sort;
  Map<String, dynamic> toJson() => {
    'version': 1,
    'range': range.name,
    'project': project,
    'model': model,
    'status': status,
    'search': search,
    'sort': sort,
  };
  factory GlobalPreferences.fromJson(Map<String, dynamic> json) {
    if (json['version'] != 1) {
      throw const FormatException('invalid_global_preferences');
    }
    String? optional(String key) {
      final value = json[key];
      if (value != null && (value is! String || value.length > 32768)) {
        throw const FormatException('invalid_global_preference_value');
      }
      return value as String?;
    }

    return GlobalPreferences(
      range:
          GlobalRange.values
              .where((v) => v.name == json['range'])
              .firstOrNull ??
          GlobalRange.days7,
      project: optional('project'),
      model: optional('model'),
      status: optional('status'),
      search: optional('search') ?? '',
      sort: json['sort'] == 'tokens' ? 'tokens' : 'recent',
    );
  }
}

class GlobalWorkbenchStore {
  GlobalWorkbenchStore(this.file);
  GlobalWorkbenchStore.memory() : file = null;
  factory GlobalWorkbenchStore.portable() => GlobalWorkbenchStore(
    File(
      '${File(Platform.resolvedExecutable).parent.path}/global-workbench-prefs-v1.json',
    ),
  );
  final File? file;
  GlobalPreferences? _memory;
  Future<void> _writes = Future.value();
  Future<GlobalPreferences?> read() async {
    await _writes;
    if (file == null) return _memory;
    if (!await file!.exists()) return null;
    return GlobalPreferences.fromJson(
      Map<String, dynamic>.from(jsonDecode(await file!.readAsString()) as Map),
    );
  }

  Future<void> write(GlobalPreferences value) {
    final validated = GlobalPreferences.fromJson(value.toJson());
    final operation = _writes.then((_) async {
      if (file == null) {
        _memory = validated;
        return;
      }
      await file!.parent.create(recursive: true);
      final temporary = File('${file!.path}.tmp');
      await temporary.writeAsString(
        jsonEncode(validated.toJson()),
        flush: true,
      );
      await temporary.rename(file!.path);
    });
    _writes = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> flush() => _writes;
}
