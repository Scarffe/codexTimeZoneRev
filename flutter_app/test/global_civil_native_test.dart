import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:codex_timezone/services/backend.dart';
import 'package:codex_timezone/services/global_workbench.dart';
import 'package:codex_timezone/services/global_workbench_service.dart';
import 'package:codex_timezone/services/session_rhythm_projection.dart';
import 'package:codex_timezone/state/global_workbench_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final host = Platform.environment['CTZ_GLOBAL_CIVIL_NATIVE_HOST'];
  final library = Platform.environment['CTZ_GLOBAL_CIVIL_NATIVE_LIBRARY'];
  test(
    'released native index and Dart agree on UTC+8 midnight and unknown-time totals',
    () async {
      final fixture = await Directory.systemTemp.createTemp(
        'ctz-global-civil-',
      );
      Process? process;
      StreamIterator<String>? output;
      GlobalWorkbenchController? controller;
      try {
        final sessions = Directory('${fixture.path}/sessions/2026/10/26');
        await sessions.create(recursive: true);
        Map<String, dynamic> usage(
          String response,
          String? timestamp,
          int output,
        ) => {
          'type': 'token_usage_record',
          'timestamp': ?timestamp,
          'payload': {
            'thread_id': 'civil-fixture',
            'session_id': 'fixture-transport',
            'turn_id': response,
            'response_id': response,
            'usage': {
              'input_tokens': 100,
              'cached_input_tokens': 20,
              'cache_write_input_tokens': 0,
              'output_tokens': output,
              'reasoning_output_tokens': 5,
              'total_tokens': 100 + output,
            },
          },
        };
        final records = [
          {
            'type': 'session_meta',
            'payload': {
              'id': 'civil-fixture',
              'session_id': 'fixture-transport',
              'cwd': 'C:/synthetic/civil-project',
              'source': 'vscode',
            },
          },
          usage('before-midnight', '2026-10-26T15:59:00Z', 20),
          usage('after-midnight', '2026-10-26T16:01:00Z', 30),
          usage('unknown-time', null, 7),
        ];
        await File('${sessions.path}/rollout-civil-fixture.jsonl')
            .writeAsString('${records.map(jsonEncode).join('\n')}\n');
        process = await Process.start(
          host!,
          [library!],
          workingDirectory: File(host).parent.path,
          includeParentEnvironment: false,
          environment: {
            for (final key in ['SystemRoot', 'WINDIR', 'TEMP', 'TMP', 'PATH'])
              if (Platform.environment[key] != null)
                key: Platform.environment[key]!,
          },
        );
        unawaited(process.stderr.drain<void>());
        output = StreamIterator(
          process.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter()),
        );
        final backend = _OwnedGlobalHost(process, output);
        final calendar = RhythmCalendar(
          toLocal: (t) => t.add(const Duration(hours: 8)),
          localDate: (y, m, d) =>
              DateTime.utc(y, m, d).subtract(const Duration(hours: 8)),
        );
        controller = GlobalWorkbenchController(
          service: GlobalWorkbenchService(backend),
          roots: [fixture.path],
          calendar: calendar,
          now: () => DateTime.utc(2026, 10, 27, 8),
        );
        await controller.initialize();
        await controller.setRange(GlobalRange.all);
        expect(controller.error, isNull);
        final data = controller.snapshot!;
        expect(data.dailyBasis, 'local');
        expect(data.totals.tokens.outputTokens, 57);
        expect(data.totals.unknownTime, 1);
        expect(data.daily.map((b) => b.tokens.outputTokens), [20, 30]);
        expect(data.daily.map((b) => b.fromMs), [
          DateTime.utc(2026, 10, 25, 16).millisecondsSinceEpoch,
          DateTime.utc(2026, 10, 26, 16).millisecondsSinceEpoch,
        ]);
        expect(data.projects.single.tokens.outputTokens, 57);
        expect(data.models.single.tokens.outputTokens, 57);
        expect(controller.query.fromMs, isNull);
        expect(controller.query.toMs, isNull);
        expect(backend.commands.toSet(), {'global_monitor'});
      } finally {
        await controller?.shutdown();
        controller?.dispose();
        if (process != null) {
          await process.stdin.close();
          await process.exitCode.timeout(
            const Duration(seconds: 10),
            onTimeout: () {
              process!.kill();
              return -1;
            },
          );
        }
        await output?.cancel();
        // This exact fixture is newly created and owned by this test.
        final temporaryRoot = await Directory.systemTemp.resolveSymbolicLinks();
        final resolved = await fixture.resolveSymbolicLinks();
        assert(resolved.startsWith('$temporaryRoot${Platform.pathSeparator}'));
        await Directory(resolved).delete(recursive: true);
      }
    },
    skip: !Platform.isWindows || host == null || library == null
        ? 'Requires explicit owned host and released native library; no real accounts.'
        : false,
  );
}

class _OwnedGlobalHost implements LauncherBackend {
  _OwnedGlobalHost(this.process, this.output);
  final Process process;
  final StreamIterator<String> output;
  final commands = <String>[];
  @override
  Future<Map<String, dynamic>> call(
    String command, [
    Map<String, dynamic> payload = const {},
  ]) async {
    if (command != 'global_monitor') {
      throw StateError('fixture_allows_only_global_monitor');
    }
    commands.add(command);
    process.stdin.writeln(
      jsonEncode({'version': 1, 'command': command, 'payload': payload}),
    );
    await process.stdin.flush();
    if (!await output.moveNext().timeout(const Duration(seconds: 30))) {
      throw StateError('owned_host_closed');
    }
    final response = jsonDecode(output.current) as Map<String, dynamic>;
    if (response['ok'] != true) throw StateError('native_global_call_failed');
    return Map<String, dynamic>.from(response['data'] as Map);
  }
}
