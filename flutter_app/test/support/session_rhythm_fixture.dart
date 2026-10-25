import 'package:codex_timezone/services/session_rhythm.dart';

final rhythmFixtureNow = DateTime.utc(2026, 10, 25, 12);
final rhythmFixtureSources = List.generate(
  8,
  (i) => RhythmSource(
    path: 'C:/synthetic/rhythm-$i.jsonl',
    sessionId: 'rhythm-$i',
    title: ['编译与验证', '文档整理', '交互检查', '离线样本', '缓存验证', '活动观察', '边界检查', '合成来源'][i],
  ),
);
RhythmCache rhythmFixtureCache({int sources = 3}) {
  final selected = rhythmFixtureSources.take(sources).toList();
  return RhythmCache(
    sources: selected,
    lastReadMs: {
      for (final s in selected)
        s.key: rhythmFixtureNow.millisecondsSinceEpoch - 60000,
    },
    turns: [
      for (var source = 0; source < selected.length; source++)
        for (var i = 0; i < 9; i++)
          RhythmTurn(
            sourceKey: selected[source].key,
            order: i + 1,
            turnId: 'turn-$source-$i',
            status: i == 8 ? RhythmStatus.cancelled : RhythmStatus.completed,
            startedAtMs: rhythmFixtureNow
                .subtract(Duration(hours: i * 9 + source + 1, minutes: 12))
                .millisecondsSinceEpoch,
            completedAtMs: rhythmFixtureNow
                .subtract(Duration(hours: i * 9 + source + 1))
                .millisecondsSinceEpoch,
            durationMs: i == 8 ? null : (i + 1) * (source + 1) * 45000,
            firstTokenMs: 1200,
            timeResolutionMs: 1000,
            activityAvailable: i != 7,
            partial: i == 7,
            reasons: i == 7 ? ['missing_activity'] : [],
            activityIntervals: i == 7
                ? []
                : [
                    RhythmInterval(
                      rhythmFixtureNow
                          .subtract(
                            Duration(hours: i * 9 + source + 1, minutes: 10),
                          )
                          .millisecondsSinceEpoch,
                      rhythmFixtureNow
                          .subtract(Duration(hours: i * 9 + source + 1))
                          .millisecondsSinceEpoch,
                    ),
                  ],
          ),
      RhythmTurn(
        sourceKey: selected.first.key,
        order: 100,
        turnId: 'undated',
        status: RhythmStatus.unknown,
        partial: true,
        reasons: ['missing_time'],
      ),
    ],
  );
}
