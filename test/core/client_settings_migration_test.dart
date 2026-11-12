import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/core/settings/client_settings.dart';
import 'package:pw_agent/core/data/settings_repository.dart';
import 'package:pw_agent/core/db/app_database.dart';
import 'package:pw_agent/core/db/db_connection.dart';

void main() {
  late AppDatabase db;
  late SettingsRepository agent;

  setUp(() async {
    db = openInMemoryDatabase();
    agent = SettingsRepository(db);
    await agent.preload();
  });

  tearDown(() async {
    await db.close();
  });

  test('copies old UI keys without overwriting client values', () async {
    await agent.write(SettingsRepository.keyLanguage, 'ru');
    await agent.write(SettingsRepository.keyThemeMode, 'dark');
    await agent.write(SettingsRepository.keySidebarWidth, '320');
    await agent.write(ClientSettingsKeys.agentProfiles, '[{"id":"p-1"}]');
    final client = MemoryClientSettings({
      ClientSettingsKeys.themeMode: 'light',
    });

    await migrateClientSettings(client, agent);

    expect(client.values[ClientSettingsKeys.language], 'ru');
    expect(client.values[ClientSettingsKeys.themeMode], 'light');
    expect(client.values[ClientSettingsKeys.sidebarWidth], '320');
    expect(client.values[ClientSettingsKeys.agentProfiles], '[{"id":"p-1"}]');
  });
}
