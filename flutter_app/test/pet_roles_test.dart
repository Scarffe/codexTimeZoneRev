import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:codex_timezone/services/pet_roles.dart';

import 'pet_animation_test.dart' show AnimationUsage;

import 'package:codex_timezone/state/account_usage_controller.dart';

Future<Uint8List> fixture({bool opaque = false}) async {
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawRect(
    ui.Rect.fromLTWH(0, 0, opaque ? 8 : 4, 8),
    ui.Paint()..color = const ui.Color(0xff66bfe8),
  );
  final picture = recorder.endRecording();
  final image = await picture.toImage(8, 8);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  picture.dispose();
  return data!.buffer.asUint8List();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('role import persists metadata and selected copy, default remains available', () async {
    final dir = await Directory.systemTemp.createTemp('pet-role-test-');
    addTearDown(() => dir.delete(recursive: true));
    final library = PetRoleLibrary(directory: dir);
    final bytes = await fixture();
    await library.importPng(
      bytes,
      name: '测试角色',
      author: '测试作者',
      outfit: '工作服',
      source: '自有测试像素',
    );
    expect(await File(library.imagePath).readAsBytes(), bytes);
    final restored = PetRoleLibrary(directory: dir);
    await restored.load();
    expect(restored.current!.name, '测试角色');
    expect(restored.current!.outfit, '工作服');
    expect(restored.current!.source, '自有测试像素');
    await restored.select(null);
    final again = PetRoleLibrary(directory: dir);
    await again.load();
    expect(again.current, isNull);
    expect(again.roles, hasLength(1));
    await library.importPng(bytes, name: '更新元数据');
    expect(library.roles, hasLength(1));
    library.dispose();
    restored.dispose();
    again.dispose();
  });
  test('invalid or opaque imports preserve the previous selection', () async {
    final dir = await Directory.systemTemp.createTemp('pet-role-invalid-');
    addTearDown(() => dir.delete(recursive: true));
    final library = PetRoleLibrary(directory: dir);
    await library.importPng(await fixture(), name: '合法角色');
    final selected = library.selected;
    await expectLater(
      library.importPng(Uint8List(24), name: '损坏'),
      throwsFormatException,
    );
    await expectLater(
      library.importPng(await fixture(opaque: true), name: '无透明'),
      throwsFormatException,
    );
    final tooWide = Uint8List.fromList(await fixture());
    ByteData.sublistView(tooWide).setUint32(16, 3000);
    await expectLater(
      library.importPng(tooWide, name: '超尺寸'),
      throwsFormatException,
    );
    expect(library.selected, selected);
    library.dispose();
  });
  test(
    'missing art falls back, unsafe index cannot escape artwork directory',
    () async {
      final dir = await Directory.systemTemp.createTemp('pet-role-missing-');
      addTearDown(() => dir.delete(recursive: true));
      final library = PetRoleLibrary(directory: dir);
      await library.importPng(await fixture(), name: '缺失');
      await File(library.imagePath).delete();
      final missing = PetRoleLibrary(directory: dir);
      await missing.load();
      expect(missing.imagePath, '');
      final index = File('${dir.path}/library-v1.json');
      const invalid = '{"version":1,"roles":[{"id":"../escape"}]}';
      await index.writeAsString(invalid);
      final unsafe = PetRoleLibrary(directory: dir);
      await unsafe.load();
      expect(unsafe.error, isNotNull);
      expect(await index.readAsString(), invalid);
      await unsafe.select(null);
      expect(
        dir.listSync().whereType<File>().where((f) => f.path.endsWith('.bak')),
        hasLength(1),
      );
      library.dispose();
      missing.dispose();
      unsafe.dispose();
    },
  );
  test('role appearance changes do not query or change usage', () async {
    final dir = await Directory.systemTemp.createTemp('pet-role-usage-');
    addTearDown(() => dir.delete(recursive: true));
    final controller = AccountUsageController(
      AnimationUsage(),
      roleLibrary: PetRoleLibrary(directory: dir),
    );
    final before = controller.desktopSnapshot;
    await controller.roles.importPng(await fixture(), name: '只改外观');
    expect(controller.attempts, 0);
    expect(controller.desktopSnapshot['remaining'], before['remaining']);
    controller.dispose();
  });
}
