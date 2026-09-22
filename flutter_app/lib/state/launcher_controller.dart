import 'package:flutter/foundation.dart';

import '../domain/settings.dart';
import '../services/backend.dart';

class LauncherController extends ChangeNotifier {
  LauncherController(this.backend, {this.preview = false});
  final LauncherBackend backend;
  final bool preview;
  LauncherSettings settings = const LauncherSettings();
  LauncherSettings? _saved;
  List<Zone> zones = [];
  String detected = '';
  String platform = 'windows';
  String message = '正在读取设置并查找 Codex…';
  String? error;
  String? busyCommand;
  bool initializing = true;
  bool bootstrapFailed = false;
  bool _disposed = false;
  bool _loading = false;

  bool get busy => busyCommand != null;
  bool get editable => !initializing && !bootstrapFailed && !busy;
  bool get dirty => _saved != null && settings != _saved;
  String get effectivePath => settings.executable.trim().isEmpty
      ? detected
      : settings.executable.trim();
  String? get validationError {
    if (settings.mode == 'zone') {
      return zones.any((zone) => zone.id == settings.zoneId)
          ? null
          : '请选择支持的地区时区。';
    }
    if (settings.mode != 'offset' ||
        settings.offset < -12 ||
        settings.offset > 14) {
      return '请选择 −12 至 +14 小时的 UTC 偏移。';
    }
    return null;
  }

  bool get canSave => editable && validationError == null && !preview;
  bool get canLaunch => canSave && effectivePath.isNotEmpty;

  void _emit() {
    if (!_disposed) notifyListeners();
  }

  void update(LauncherSettings next) {
    if (!editable) return;
    settings = next;
    _emit();
  }

  void report(String summary, {String? detail}) {
    message = summary;
    error = detail;
    _emit();
  }

  Future<void> initialize() async {
    if (_loading || busy) return;
    _loading = true;
    initializing = true;
    bootstrapFailed = false;
    report('正在读取设置并查找 Codex…');
    try {
      final data = await backend.call('bootstrap');
      final loaded = LauncherSettings.fromJson(
        data['settings'] as Map<String, dynamic>,
      );
      final loadedZones = (data['zones'] as List)
          .map((value) => Zone.fromJson(value as Map<String, dynamic>))
          .toList();
      settings = loaded;
      zones = loadedZones;
      _saved = loaded;
      detected = data['detected'] as String? ?? '';
      platform = data['platform'] as String? ?? 'windows';
      message = preview
          ? '演示模式：系统操作已禁用。'
          : detected.isEmpty
          ? '设置已读取，请选择 Codex 客户端。'
          : '设置已读取，客户端已自动找到。';
    } catch (e) {
      bootstrapFailed = true;
      message = '读取设置失败，请重试。';
      error = e.toString();
    } finally {
      initializing = false;
      _loading = false;
      _emit();
    }
  }

  Future<void> browse(Future<String?> Function() choosePath) async {
    if (!editable || preview) return;
    busyCommand = 'browse';
    _emit();
    try {
      final path = await choosePath();
      if (path == null || _disposed) return;
      final data = await backend.call('validate', {'path': path});
      settings = settings.copyWith(executable: data['path'] as String);
      report('客户端路径已更新，尚未保存。');
    } catch (e) {
      report('无法使用所选客户端路径。', detail: e.toString());
    } finally {
      busyCommand = null;
      _emit();
    }
  }

  Future<bool> action(String command) async {
    if (!editable || preview) return false;
    if (![
      'save',
      'launch',
      'create_shortcut',
      'launch_dream_skin',
    ].contains(command)) {
      return false;
    }
    if (['save', 'launch'].contains(command) && validationError != null) {
      report('时区设置无效。', detail: validationError);
      return false;
    }
    if (command == 'launch' && effectivePath.isEmpty) {
      report('未找到 Codex，请选择程序路径。');
      return false;
    }
    final submitted = settings;
    busyCommand = command;
    report(switch (command) {
      'save' => '正在保存设置…',
      'launch' => '正在保存设置并启动 Codex…',
      'create_shortcut' => '正在创建桌面快捷方式…',
      _ => '正在打开 Dream Skin…',
    });
    try {
      final data = await backend.call(command, {
        'settings': submitted.toJson(),
      });
      if (command == 'save' || command == 'launch') _saved = submitted;
      report(data['message'] as String? ?? '操作已完成。');
      return true;
    } catch (e) {
      report('操作失败。', detail: e.toString());
      return false;
    } finally {
      busyCommand = null;
      _emit();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
