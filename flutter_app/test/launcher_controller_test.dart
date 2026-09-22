import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:codex_timezone/services/backend.dart';
import 'package:codex_timezone/state/launcher_controller.dart';

class FakeBackend implements LauncherBackend {
  bool failBootstrap = false, failSave = false;
  Completer<Map<String, dynamic>>? pending;
  final List<String> calls = [];
  @override
  Future<Map<String, dynamic>> call(
    String command, [
    Map<String, dynamic> payload = const {},
  ]) async {
    calls.add(command);
    if (command == 'bootstrap') {
      if (failBootstrap) throw StateError('损坏配置');
      return const PreviewBackend().call(command);
    }
    if (command == 'validate') return {'path': payload['path']};
    if (failSave) throw StateError('保存失败');
    if (pending != null) return pending!.future;
    return {'message': '完成'};
  }
}

void main() {
  test(
    'file chooser cancellation releases busy state without modifying draft',
    () async {
      final backend = FakeBackend();
      final controller = LauncherController(backend);
      addTearDown(controller.dispose);
      await controller.initialize();
      final selected = Completer<String?>();
      final browse = controller.browse(() => selected.future);
      expect(controller.busy, isTrue);
      expect(await controller.action('save'), isFalse);
      var secondOpened = false;
      await controller.browse(() async {
        secondOpened = true;
        return null;
      });
      expect(secondOpened, isFalse);
      selected.complete(null);
      await browse;
      expect(controller.busy, isFalse);
      expect(controller.dirty, isFalse);
      expect(backend.calls, ['bootstrap']);
    },
  );

  test(
    'file chooser updates draft only after native path validation',
    () async {
      final backend = FakeBackend();
      final controller = LauncherController(backend);
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.browse(() async => r'C:\测试 客户端\Codex.exe');
      expect(controller.settings.executable, r'C:\测试 客户端\Codex.exe');
      expect(controller.dirty, isTrue);
      expect(backend.calls, ['bootstrap', 'validate']);
    },
  );

  test(
    'closing the app during file selection does not validate or notify later',
    () async {
      final backend = FakeBackend();
      final controller = LauncherController(backend);
      await controller.initialize();
      final selected = Completer<String?>();
      final browse = controller.browse(() => selected.future);
      controller.dispose();
      selected.complete(r'C:\Codex.exe');
      await browse;
      expect(backend.calls, ['bootstrap']);
    },
  );
  test('failed bootstrap cannot save placeholders; retry recovers', () async {
    final backend = FakeBackend()..failBootstrap = true;
    final controller = LauncherController(backend);
    addTearDown(controller.dispose);
    await controller.initialize();
    expect(controller.bootstrapFailed, isTrue);
    expect(await controller.action('save'), isFalse);
    expect(backend.calls, ['bootstrap']);
    backend.failBootstrap = false;
    await controller.initialize();
    expect(controller.canSave, isTrue);
    expect(controller.dirty, isFalse);
  });

  test(
    'failed save retains draft and opening skin never marks it saved',
    () async {
      final backend = FakeBackend();
      final controller = LauncherController(backend);
      addTearDown(controller.dispose);
      await controller.initialize();
      controller.update(
        controller.settings.copyWith(zoneId: 'America/New_York'),
      );
      expect(controller.dirty, isTrue);
      backend.failSave = true;
      expect(await controller.action('save'), isFalse);
      expect(controller.dirty, isTrue);
      backend.failSave = false;
      await controller.action('launch_dream_skin');
      expect(controller.dirty, isTrue);
      await controller.action('save');
      expect(controller.dirty, isFalse);
    },
  );

  test('in-flight launch blocks duplicate requests and draft edits', () async {
    final backend = FakeBackend();
    final controller = LauncherController(backend);
    addTearDown(controller.dispose);
    await controller.initialize();
    backend.pending = Completer();
    final original = controller.settings;
    final launch = controller.action('launch');
    expect(controller.busy, isTrue);
    controller.update(original.copyWith(offset: -5));
    expect(controller.settings, original);
    expect(await controller.action('launch'), isFalse);
    backend.pending!.complete({'message': '完成'});
    expect(await launch, isTrue);
    expect(backend.calls.where((call) => call == 'launch'), hasLength(1));
  });

  test('unsupported network timezone is rejected before persistence', () async {
    final backend = FakeBackend();
    final controller = LauncherController(backend);
    addTearDown(controller.dispose);
    await controller.initialize();
    controller.update(controller.settings.copyWith(zoneId: 'Unsupported/Zone'));
    expect(controller.canSave, isFalse);
    expect(await controller.action('save'), isFalse);
    expect(backend.calls, ['bootstrap']);
  });
}
