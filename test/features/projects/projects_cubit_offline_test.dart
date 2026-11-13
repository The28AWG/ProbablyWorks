import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/features/projects/presentation/bloc/projects_cubit.dart';
import 'package:pw_agent/agent/api/agent_api.dart';
import 'package:pw_agent/agent/api/projects_api.dart';
import 'package:pw_agent/agent/domain/project.dart';
import 'package:pw_agent/core/domain/host.dart';

void main() {
  test('stops loading when the backend goes offline', () async {
    final statuses = StreamController<AgentStatus>.broadcast();
    final cubit = ProjectsCubit(
      _FakeProjects(),
      initialStatus: AgentStatus.online,
      statusChanges: statuses.stream,
    );
    addTearDown(() async {
      await cubit.close();
      await statuses.close();
    });

    expect(cubit.state.loading, isTrue);
    statuses.add(AgentStatus.offline);
    await Future<void>.delayed(Duration.zero);
    expect(cubit.state.loading, isFalse);
  });

  test('does not start loading when created while offline', () {
    final cubit = ProjectsCubit(
      _FakeProjects(),
      initialStatus: AgentStatus.offline,
    );
    addTearDown(cubit.close);

    expect(cubit.state.loading, isFalse);
  });
}

final class _FakeProjects implements ProjectsApi {
  @override
  Stream<List<Project>> watchProjects() => const Stream.empty();

  @override
  Stream<Map<String, int>> watchChatCounts() => const Stream.empty();

  @override
  Stream<List<Host>> watchHosts() => const Stream.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('ProjectsApi is not used in this test');
}
