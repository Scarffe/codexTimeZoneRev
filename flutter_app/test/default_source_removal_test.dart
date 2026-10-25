import 'package:flutter_test/flutter_test.dart';
import 'package:codex_timezone/services/account_source_store.dart';
import 'package:codex_timezone/state/account_sources_controller.dart';
import 'package:codex_timezone/state/account_usage_controller.dart';

import 'account_sources_test.dart'
    show SyntheticSources, ForbiddenLegacy, sample;

void main() {
  final now = DateTime.utc(2026, 10, 24);

  test(
    'empty source catalog never queries or falls back to current account',
    () async {
      final service = SyntheticSources();
      final owner = AccountSourcesController(
        service,
        AccountSourceStore.memory(),
      );
      final usage = AccountUsageController(ForbiddenLegacy(), sources: owner);
      addTearDown(usage.dispose);
      addTearDown(owner.dispose);
      expect(owner.states, isEmpty);
      await owner.initialize(() => 'fixture-cli');
      expect(owner.selectedId, '');
      expect(owner.pinnedId, '');
      expect(owner.selected, isNull);
      expect(owner.pinned, isNull);
      await owner.refresh('current');
      await usage.query('another-cli');
      expect(service.calls, isEmpty);
      expect(usage.data, isNull);
      expect(usage.desktopSnapshot['remaining'], -1.0);
    },
  );

  test(
    'legacy current is ignored while managed cache and state survive',
    () async {
      final service = SyntheticSources();
      final store = AccountSourceStore.memory();
      await store.write({
        'selectedId': 'current',
        'pinnedId': 'current',
        'sources': [
          {
            'id': 'current',
            'alias': 'Old default',
            'usage': sample(now, 90).toCacheJson(),
          },
          {
            'id': 'profile-a',
            'alias': 'Work',
            'generation': 7,
            'usage': sample(now, 25).toCacheJson(),
            'errorKind': 'network',
            'failures': 1,
            'lastAttempt': now.millisecondsSinceEpoch,
            'nextRefreshAt': now
                .add(const Duration(seconds: 120))
                .millisecondsSinceEpoch,
          },
        ],
      });
      final owner = AccountSourcesController(service, store, now: () => now);
      addTearDown(owner.dispose);
      await owner.initialize(() => 'fixture-cli');
      expect(owner.catalogError, isNull);
      expect(owner.states.map((s) => s.id), ['profile-a']);
      expect(owner.selectedId, 'profile-a');
      expect(owner.pinnedId, 'profile-a');
      expect(owner.selected!.generation, 7);
      expect(owner.selected!.usage!.fetchedAt, now);
      expect(owner.selected!.errorKind, 'network');
      expect(owner.selected!.failures, 1);
      owner.sourceChanged('another-cli');
      expect(owner.selected!.generation, 7);
      expect(owner.selected!.usage!.fetchedAt, now);
      owner.rename('profile-a', 'Renamed');
      await owner.saved;
      final saved = await store.read();
      expect((saved['sources'] as List).map((s) => s['id']), ['profile-a']);
      expect(service.calls, isEmpty);
    },
  );

  test(
    'restore falls back past pending cleanup and preserves valid choices',
    () async {
      for (final selected in [
        'current',
        'missing',
        'profile-pending',
        'profile-b',
      ]) {
        final store = AccountSourceStore.memory();
        await store.write({
          'selectedId': selected,
          'pinnedId': selected,
          'sources': [
            {
              'id': 'profile-pending',
              'alias': 'Pending',
              'pendingRemoval': true,
            },
            {'id': 'profile-a', 'alias': 'Work'},
            {'id': 'profile-b', 'alias': 'Personal'},
          ],
        });
        final owner = AccountSourcesController(SyntheticSources(), store);
        await owner.initialize(() => 'fixture-cli');
        expect(owner.catalogError, isNull);
        expect(
          owner.selectedId,
          selected == 'profile-b' ? 'profile-b' : 'profile-a',
        );
        expect(
          owner.pinnedId,
          selected == 'profile-b' ? 'profile-b' : 'profile-a',
        );
        owner.dispose();
      }
    },
  );

  test(
    'first create selects and pins, later creates preserve user choice',
    () async {
      final service = SyntheticSources();
      final store = AccountSourceStore.memory();
      final owner = AccountSourcesController(service, store);
      addTearDown(owner.dispose);
      await owner.initialize(() => 'fixture-cli');
      final first = (await owner.create('Work'))!;
      expect(owner.selectedId, first);
      expect(owner.pinnedId, first);
      final second = (await owner.create('Personal'))!;
      expect(owner.selectedId, first);
      expect(owner.pinnedId, first);
      owner.select(second);
      await owner.create('Other');
      expect(owner.selectedId, second);
      expect(owner.pinnedId, first);
    },
  );

  test(
    'removal chooses remaining managed source then leaves reusable empty state',
    () async {
      final service = SyntheticSources();
      final store = AccountSourceStore.memory();
      final owner = AccountSourcesController(service, store);
      addTearDown(owner.dispose);
      await owner.initialize(() => 'fixture-cli');
      final first = (await owner.create('Work'))!;
      final second = (await owner.create('Personal'))!;
      await owner.remove(first);
      expect(owner.selectedId, second);
      expect(owner.pinnedId, second);
      await owner.remove(second);
      expect(owner.states, isEmpty);
      expect(owner.selectedId, '');
      expect(owner.pinnedId, '');
      await owner.saved;
      expect((await store.read())['sources'], isEmpty);
      final third = (await owner.create('Again'))!;
      expect(owner.selectedId, third);
      expect(owner.pinnedId, third);
    },
  );
}
