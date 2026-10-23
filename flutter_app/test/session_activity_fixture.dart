Map<String, dynamic> timelineFixture({int count = 4}) => {
  'version': 1,
  'coordinateKind': 'logged_turn_window',
  'startEpochMs': 100000,
  'endEpochMsExclusive': 110000,
  'spanMs': 10000,
  'boundsResolutionMs': 1000,
  'limit': 200,
  'order': 'start_end_id',
  'totalItems': count,
  'shownItems': count,
  'omittedItems': 0,
  'sourcePartial': false,
  'coverageInterpretation': 'approximate',
  'items': [
    for (var i = 0; i < count; i++)
      <String, dynamic>{
        'ordinal': i + 1,
        'category': ['message', 'reasoning', 'tool', 'other'][i % 4],
        'startedAtMs': 101000 + i * 10,
        'completedAtMs': 106000 + i * 10,
        'offsetStartMs': 1000 + i * 10,
        'offsetEndMs': 6000 + i * 10,
        'durationMs': 5000,
        'drawable': true,
        'reasons': <String>[],
      },
  ],
};
