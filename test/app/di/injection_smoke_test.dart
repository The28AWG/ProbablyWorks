import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/app/di/injection.dart';
import 'package:pw_agent/agent/api/agent_api.dart';
import 'package:pw_agent/agent/api/local_agent_api.dart';
import 'package:pw_agent/core/config/app_paths.dart';

void main() {
  test('root DI resolves agent implementations lazily', () async {
    final temp = Directory.systemTemp.createTempSync('pw_di');
    addTearDown(() async {
      await getIt.reset();
      temp.deleteSync(recursive: true);
    });
    getIt.registerSingleton<AppPaths>(AppPaths.forSupport(temp));

    await configureDependencies();

    expect(getIt<AgentApi>(), isA<LocalAgentApi>());
  });
}
