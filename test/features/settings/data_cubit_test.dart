import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/features/settings/presentation/bloc/data_cubit.dart';
import 'package:pw_agent/agent/api/data_api.dart';
import 'package:pw_agent/agent/api/state_events_api.dart';
import 'package:pw_agent/agent/state/shared_state.dart';

const _usage = DataUsage(
  chats: 2,
  subagentChats: 1,
  messages: 10,
  toolRuns: 3,
  scheduledTasks: 1,
  completedTasks: 2,
  failedTasks: 0,
  cancelledTasks: 0,
  chatFilesBytes: 1024,
  databaseBytes: 2048,
);

final class _FakeDataApi implements DataApi, StateEventsApi {
  _FakeDataApi({this.fail = false});

  bool fail;
  int? clearedDays;
  var resets = 0;
  var usageCalls = 0;
  final _events = StreamController<SharedResource>.broadcast();

  @override
  Stream<SharedResource> get sharedStateChanges => _events.stream;

  /// Рассылает событие так же, как сервер через SSE.
  void publish(SharedResource resource) => _events.add(resource);

  Future<void> close() => _events.close();

  @override
  Future<DataUsage> usage() async {
    usageCalls++;
    if (fail) throw StateError('usage failed');
    return _usage;
  }

  @override
  Future<HistoryClearResult> clearHistory({int? olderThanDays}) async {
    if (fail) throw StateError('clear failed');
    clearedDays = olderThanDays;
    return const HistoryClearResult(deletedChats: 2, freedBytes: 512);
  }

  @override
  Future<void> resetSettings() async {
    if (fail) throw StateError('reset failed');
    resets++;
  }
}

void main() {
  test('loads usage and clears history with the chosen age', () async {
    final api = _FakeDataApi();
    final cubit = DataCubit(api);
    addTearDown(cubit.close);

    await cubit.load();
    expect(cubit.state.usage, _usage);
    expect(cubit.state.loading, isFalse);

    final result = await cubit.clearHistory(olderThanDays: 30);

    expect(result?.deletedChats, 2);
    expect(api.clearedDays, 30);
    expect(cubit.state.clearing, isFalse);
    expect(cubit.state.error, isNull);
  });

  test('keeps the error and returns null when clearing fails', () async {
    final api = _FakeDataApi(fail: true);
    final cubit = DataCubit(api);
    addTearDown(cubit.close);

    await cubit.load();
    expect(cubit.state.error, contains('usage failed'));

    final result = await cubit.clearHistory();

    expect(result, isNull);
    expect(cubit.state.error, contains('clear failed'));
    expect(cubit.state.clearing, isFalse);
  });

  test('reset reports success and refreshes usage', () async {
    final api = _FakeDataApi();
    final cubit = DataCubit(api);
    addTearDown(cubit.close);

    expect(await cubit.resetSettings(), isTrue);
    expect(api.resets, 1);
    expect(cubit.state.usage, _usage);
    expect(cubit.state.resetting, isFalse);
  });

  test('reloads usage only when the data resource changes', () async {
    final api = _FakeDataApi();
    final cubit = DataCubit(api);
    addTearDown(cubit.close);
    addTearDown(api.close);
    await cubit.load();
    final calls = api.usageCalls;

    // Список чатов меняется на каждое сообщение: сводка не должна обходить
    // папку чатов так часто.
    api.publish(SharedResource.chats);
    await pumpEventQueue();
    expect(api.usageCalls, calls);

    api.publish(SharedResource.data);
    await pumpEventQueue();
    expect(api.usageCalls, calls + 1);
  });
}
