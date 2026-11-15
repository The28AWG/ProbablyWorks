import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/app/di/injection_native.dart';
import 'package:probably_works/core/platform/client_info.dart';
import 'package:probably_works/core/settings/client_settings.dart';
import 'package:pw_agent/agent/api/agent_api.dart';
import 'package:pw_agent/agent/api/agent_settings_api.dart';
import 'package:pw_agent/agent/api/local_agent_api.dart';
import 'package:pw_agent/core/config/app_paths.dart';
import 'package:pw_agent/providers/ai/llm_provider_registry.dart';

void main() {
  test('root DI resolves agent implementations lazily', () async {
    final temp = Directory.systemTemp.createTempSync('pw_di');
    addTearDown(() async {
      await getIt.reset();
      temp.deleteSync(recursive: true);
    });
    getIt
      ..registerSingleton<AppPaths>(AppPaths.forSupport(temp))
      ..registerSingleton<ClientInfo>(const ClientInfo.fallback())
      ..registerSingleton<ClientSettings>(MemoryClientSettings());

    await configureDependencies();

    expect(getIt<AgentApi>(), isA<LocalAgentApi>());

    // Локальные модели: провайдер зарегистрирован, среда отвечает.
    final registry = getIt<LlmProviderRegistry>();
    expect(registry.descriptorById('llamadart'), isNotNull);
    final settings = getIt<AgentSettingsApi>();
    expect(settings.localModels.state.supported, isTrue);
  });
}
