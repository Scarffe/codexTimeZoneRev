import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

class PetRole {
  const PetRole(this.id, this.name, this.author, this.outfit, this.source);
  final String id, name, author, outfit, source;
  Map<String, String> toJson() => {
    'id': id,
    'name': name,
    'author': author,
    'outfit': outfit,
    'source': source,
  };
}

/// Local artwork only. Roles never select models, read credentials or query usage.
class PetRoleLibrary extends ChangeNotifier {
  PetRoleLibrary({Directory? directory})
    : directory =
          directory ??
          Directory(
            p.join(File(Platform.resolvedExecutable).parent.path, 'pet-roles'),
          );
  final Directory directory;
  final List<PetRole> _roles = [];
  List<PetRole> get roles => List.unmodifiable(_roles);
  String? selected;
  String? error;
  Future<void> _pending = Future.value();
  bool _disposed = false;
  PetRole? get current {
    for (final role in _roles) {
      if (role.id == selected) return role;
    }
    return null;
  }

  String get imagePath =>
      current == null ? '' : p.join(directory.path, '${current!.id}.png');
  File get _index => File(p.join(directory.path, 'library-v1.json'));
  Future<void> get saved => _pending;
  static String _text(Object? value, {int max = 200}) {
    final s = value is String ? value.trim() : '';
    if (s.length > max) throw const FormatException('角色信息过长');
    return s;
  }

  Future<void> load() async {
    try {
      if (!await _index.exists()) return;
      final value =
          jsonDecode(await _index.readAsString()) as Map<String, dynamic>;
      if (value['version'] != 1 || value['roles'] is! List) {
        throw const FormatException();
      }
      final loaded = <PetRole>[];
      for (final entry in (value['roles'] as List).take(50)) {
        final v = entry as Map<String, dynamic>;
        final id = _text(v['id']);
        if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(id)) {
          throw const FormatException();
        }
        if (!await File(p.join(directory.path, '$id.png')).exists()) continue;
        loaded.add(
          PetRole(
            id,
            _text(v['name']),
            _text(v['author']),
            _text(v['outfit']),
            _text(v['source'], max: 1000),
          ),
        );
      }
      if (_disposed) return;
      _roles
        ..clear()
        ..addAll(loaded);
      selected = value['selected'] is String
          ? value['selected'] as String
          : null;
      if (current == null) selected = null;
      error = null;
    } catch (_) {
      error = '角色资料读取失败，已使用默认鲸鱼；原文件未改动。';
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> importPng(
    Uint8List bytes, {
    required String name,
    String author = '',
    String outfit = '',
    String source = '',
  }) async {
    name = _text(name);
    author = _text(author);
    outfit = _text(outfit);
    source = _text(source, max: 1000);
    if (name.isEmpty) throw const FormatException('请填写角色名称');
    if (bytes.length > 8 * 1024 * 1024 ||
        bytes.length < 24 ||
        !listEquals(bytes.take(8).toList(), [
          137,
          80,
          78,
          71,
          13,
          10,
          26,
          10,
        ])) {
      throw const FormatException('请选择 8 MiB 以内的透明 PNG');
    }
    final header = ByteData.sublistView(bytes);
    final width = header.getUint32(16), height = header.getUint32(20);
    if (width == 0 || height == 0 || width > 2048 || height > 2048) {
      throw const FormatException('图片尺寸须在 1–2048 像素之间');
    }
    final codec = await ui.instantiateImageCodec(bytes);
    try {
      final frame = await codec.getNextFrame();
      try {
        final rgba = await frame.image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        bool transparent = false, visible = false;
        for (int i = 3; i < rgba!.lengthInBytes; i += 4) {
          final a = rgba.getUint8(i);
          transparent |= a < 255;
          visible |= a > 0;
        }
        if (!transparent || !visible) {
          throw const FormatException('需要同时包含可见角色和透明背景');
        }
      } finally {
        frame.image.dispose();
      }
    } finally {
      codec.dispose();
    }
    if (_disposed) return;
    final id = sha256.convert(bytes).toString();
    if (_roles.length >= 50 && !_roles.any((r) => r.id == id)) {
      throw const FormatException('首版最多保存 50 个角色');
    }
    await directory.create(recursive: true);
    await File(p.join(directory.path, '$id.png'))
        .writeAsBytes(bytes, flush: true);
    if (_disposed) return;
    _roles.removeWhere((r) => r.id == id);
    _roles.add(PetRole(id, name, author, outfit, source));
    selected = id;
    await _save();
    if (!_disposed) notifyListeners();
  }

  Future<void> select(String? id) async {
    if (_disposed || (id != null && !_roles.any((r) => r.id == id))) return;
    selected = id;
    await _save();
    if (!_disposed) notifyListeners();
  }

  Future<void> _save() {
    final snapshot = jsonEncode({
      'version': 1,
      'selected': selected,
      'roles': _roles.map((r) => r.toJson()).toList(),
    });
    _pending = _pending.then((_) async {
      try {
        await directory.create(recursive: true);
        if (error != null && await _index.exists()) {
          await _index.copy(
            '${_index.path}.invalid-${DateTime.now().microsecondsSinceEpoch}.bak',
          );
        }
        final temp = File('${_index.path}.tmp');
        await temp.writeAsString(snapshot, flush: true);
        await temp.rename(_index.path);
        error = null;
      } catch (_) {
        error = '角色已生效，但保存失败，请检查当前文件夹权限。';
      }
    });
    return _pending;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
