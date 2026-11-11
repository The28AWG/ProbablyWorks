import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/core/data/settings_repository.dart';
import 'package:probably_works/core/db/app_database.dart';
import 'package:probably_works/core/db/db_connection.dart';
import 'package:probably_works/core/domain/chat_usage.dart';

void main() {
  late AppDatabase db;
  late SettingsRepository settings;

  setUp(() async {
    db = openInMemoryDatabase();
    settings = SettingsRepository(db);
    await settings.preload();
  });

  tearDown(() => db.close());

  test('usage is accumulated per chat and day', () async {
    final day = DateTime(2026, 11, 11);
    await settings.addDailyUsage(
      'c1',
      promptTokens: 10,
      completionTokens: 5,
      costUsd: 0.01,
      day: day,
    );
    final next = await settings.addDailyUsage(
      'c1',
      promptTokens: 20,
      completionTokens: 7,
      costUsd: 0.02,
      day: day,
    );

    expect(next.promptTokens, 30);
    expect(next.completionTokens, 12);
    expect(next.costUsd, closeTo(0.03, 0.000001));
    expect(next.requests, 2);
    expect(
      (await settings.readDailyUsage(
        'c1',
        day: day.add(const Duration(days: 1)),
      )).totalTokens,
      0,
    );
  });

  test('daily budget is stored per chat and zero means no limit', () async {
    await settings.saveDailyBudget('c1', 2.5);
    expect(await settings.readDailyBudget('c1'), 2.5);
    expect(await settings.readDailyBudget('c2'), isNull);

    await settings.saveDailyBudget('c1', 0);
    expect(await settings.readDailyBudget('c1'), isNull);
  });

  test('compaction info round-trips and broken data is ignored', () async {
    expect(await settings.readCompactionInfo('c2'), isNull);
    final info = ChatCompactionInfo(
      at: DateTime(2026, 11, 11, 14, 5),
      reason: 'forced',
      cutoffSeq: 7,
      summaryChars: 320,
    );
    await settings.saveCompactionInfo('c1', info);

    final read = await settings.readCompactionInfo('c1');
    expect(read?.at, info.at);
    expect(read?.reason, 'forced');
    expect(read?.cutoffSeq, 7);
    expect(read?.summaryChars, 320);

    await settings.write(SettingsRepository.compactionInfoKey('c1'), 'oops');
    expect(await settings.readCompactionInfo('c1'), isNull);
  });
}
