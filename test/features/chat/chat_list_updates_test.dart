import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/features/chat/presentation/bloc/chat_list_updates.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';

ChatMessage _message(String id, int seq) => ChatMessage(
  id: id,
  chatId: 'c',
  seq: seq,
  role: MessageRole.assistant,
  createdAt: DateTime(2026),
);

ToolRun _run(
  String id, {
  required ToolRunStatus status,
  required DateTime startedAt,
}) => ToolRun(
  id: id,
  chatId: 'c',
  messageId: 'm',
  toolName: 'run_command',
  argsJson: '{}',
  status: status,
  startedAt: startedAt,
);

void main() {
  group('withMessage', () {
    test('appends a newer message at the end', () {
      final list = withMessage([_message('a', 1)], _message('b', 2));

      expect(list.map((m) => m.id), ['a', 'b']);
    });

    test('inserts a late message by seq', () {
      final list = withMessage([
        _message('a', 1),
        _message('c', 3),
      ], _message('b', 2));

      expect(list.map((m) => m.id), ['a', 'b', 'c']);
    });

    test('a repeated id is not added twice', () {
      final list = withMessage([_message('a', 1)], _message('a', 1));

      expect(list.map((m) => m.id), ['a']);
    });
  });

  group('withRun', () {
    final t0 = DateTime(2026, 1, 1, 10);

    test('updates a known run in place', () {
      final runs = [_run('r1', status: ToolRunStatus.running, startedAt: t0)];

      final next = withRun(
        runs,
        _run('r1', status: ToolRunStatus.done, startedAt: t0),
      );

      expect(next, hasLength(1));
      expect(next.single.status, ToolRunStatus.done);
    });

    test('sorts by startedAt, not by arrival order', () {
      final late = _run(
        'late',
        status: ToolRunStatus.running,
        startedAt: t0.add(const Duration(minutes: 2)),
      );
      final early = _run('early', status: ToolRunStatus.done, startedAt: t0);

      final next = withRun([late], early);

      expect(next.map((r) => r.id), ['early', 'late']);
    });
  });

  group('liveWithRuns', () {
    final t0 = DateTime(2026, 1, 1, 10);

    test('keeps output of the run that is still active', () {
      final runs = [_run('r1', status: ToolRunStatus.running, startedAt: t0)];

      final live = liveWithRuns({'r1': 'tail'}, runs, runs.single);

      expect(live, {'r1': 'tail'});
    });

    test('drops output of a run that has just finished', () {
      final runs = [_run('r1', status: ToolRunStatus.running, startedAt: t0)];
      final finished = _run('r1', status: ToolRunStatus.done, startedAt: t0);

      final live = liveWithRuns({'r1': 'tail'}, runs, finished);

      expect(live, isEmpty);
    });

    test('keeps output of other active runs untouched', () {
      final other = _run('r2', status: ToolRunStatus.running, startedAt: t0);
      final changed = _run('r1', status: ToolRunStatus.done, startedAt: t0);

      final live = liveWithRuns(
        {'r1': 'a', 'r2': 'b'},
        [changed, other],
        changed,
      );

      expect(live, {'r2': 'b'});
    });
  });
}
