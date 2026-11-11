import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/loop/tool_scheduler.dart';
import 'package:pw_agent/agent/policy/command_classifier.dart';
import 'package:pw_agent/agent/policy/policy_engine.dart';
import 'package:pw_agent/agent/tools/tool_catalog.dart';
import 'package:pw_agent/agent/tools/tool_executor.dart';
import 'package:pw_agent/core/domain/host.dart';
import 'package:pw_agent/core/util/cancel_token.dart';
import 'package:pw_agent/providers/ai/llm_port.dart';

void main() {
  final policy = PolicyEngine(
    classifier: CommandClassifier(denylist: const []),
    mode: PolicyMode.yolo,
  );

  LlmToolCall call(String id, String name, Map<String, dynamic> args) =>
      LlmToolCall(id: id, name: name, arguments: jsonEncode(args));

  Future<void> drop(LlmToolCall _, ToolResult _) => Future<void>.value();

  Future<void> idle() async {
    for (var i = 0; i < 30; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  test('independent calls start together and commit in call order', () async {
    final entered = <String>[];
    final committed = <String>[];
    final gates = {'a': Completer<ToolResult>(), 'b': Completer<ToolResult>()};
    final done = ToolScheduler.run(
      calls: [
        call('a', ToolNames.readFile, {'path': 'a'}),
        call('b', ToolNames.readFile, {'path': 'b'}),
      ],
      workspace: '/ws',
      policy: policy,
      hostKind: HostKind.local,
      cancel: CancelToken(),
      execute: (tool) {
        entered.add(tool.id);
        return gates[tool.id]!.future;
      },
      commit: (tool, result) async {
        committed.add('${tool.id}:${result.text}');
      },
    );
    await idle();
    expect(entered, ['a', 'b']);
    expect(committed, isEmpty);

    gates['b']!.complete(const ToolResult('bee'));
    await idle();
    expect(committed, isEmpty, reason: 'b finishes first but waits for a');

    gates['a']!.complete(const ToolResult('ay'));
    expect(await done, ToolScheduleEnd.done);
    expect(committed, ['a:ay', 'b:bee']);
  });

  test(
    'a confirming read waits for the write, an unrelated read does not',
    () async {
      final entered = <String>[];
      final write = Completer<ToolResult>();
      final done = ToolScheduler.run(
        calls: [
          call('w', ToolNames.writeFile, {'path': 'note.txt', 'content': 'hi'}),
          call('same', ToolNames.readFile, {'path': 'note.txt'}),
          call('other', ToolNames.readFile, {'path': 'other.txt'}),
        ],
        workspace: '/ws',
        policy: policy,
        hostKind: HostKind.local,
        cancel: CancelToken(),
        execute: (tool) {
          entered.add(tool.id);
          if (tool.id == 'w') return write.future;
          return Future.value(ToolResult(tool.id));
        },
        commit: drop,
      );
      await idle();
      expect(entered, ['w', 'other']);

      write.complete(const ToolResult('wrote'));
      expect(await done, ToolScheduleEnd.done);
      expect(entered, ['w', 'other', 'same']);
    },
  );

  test('two asks are entered before either approval returns', () async {
    final entered = <String>[];
    final gates = {'a': Completer<ToolResult>(), 'b': Completer<ToolResult>()};
    final done = ToolScheduler.run(
      calls: [
        call('a', ToolNames.writeFile, {'path': 'a', 'content': '1'}),
        call('b', ToolNames.writeFile, {'path': 'b', 'content': '2'}),
      ],
      workspace: '/ws',
      policy: policy,
      hostKind: HostKind.local,
      cancel: CancelToken(),
      execute: (tool) {
        entered.add(tool.id);
        return gates[tool.id]!.future;
      },
      commit: drop,
    );
    await idle();
    expect(entered, ['a', 'b']);
    gates['a']!.complete(const ToolResult('a'));
    gates['b']!.complete(const ToolResult('b'));
    expect(await done, ToolScheduleEnd.done);
  });

  test(
    'edit of a file waits until the earlier write of that file settles',
    () async {
      final entered = <String>[];
      final write = Completer<ToolResult>();
      final done = ToolScheduler.run(
        calls: [
          call('w', ToolNames.writeFile, {'path': 'a', 'content': '1'}),
          call('e', ToolNames.editFile, {
            'path': 'a',
            'old_string': '1',
            'new_string': '2',
          }),
        ],
        workspace: '/ws',
        policy: policy,
        hostKind: HostKind.local,
        cancel: CancelToken(),
        execute: (tool) {
          entered.add(tool.id);
          if (tool.id == 'w') return write.future;
          return Future.value(const ToolResult('edited'));
        },
        commit: drop,
      );
      await idle();
      expect(entered, ['w']);
      write.complete(const ToolResult('wrote'));
      expect(await done, ToolScheduleEnd.done);
      expect(entered, ['w', 'e']);
    },
  );

  test('a command is a host barrier for a later file read', () async {
    final entered = <String>[];
    final command = Completer<ToolResult>();
    final done = ToolScheduler.run(
      calls: [
        call('c', ToolNames.runCommand, {'command': 'mkdir build'}),
        call('r', ToolNames.readFile, {'path': 'a'}),
      ],
      workspace: '/ws',
      policy: policy,
      hostKind: HostKind.local,
      cancel: CancelToken(),
      execute: (tool) {
        entered.add(tool.id);
        if (tool.id == 'c') return command.future;
        return Future.value(const ToolResult('file'));
      },
      commit: drop,
    );
    await idle();
    expect(entered, ['c']);
    command.complete(const ToolResult('made'));
    expect(await done, ToolScheduleEnd.done);
    expect(entered, ['c', 'r']);
  });

  test(
    'background settlement holds later host reads but not the tool text',
    () async {
      final entered = <String>[];
      final committed = <String>[];
      final settled = Completer<void>();
      final done = ToolScheduler.run(
        calls: [
          call('c', ToolNames.runCommand, {'command': 'mkdir build'}),
          call('r', ToolNames.readFile, {'path': 'a'}),
        ],
        workspace: '/ws',
        policy: policy,
        hostKind: HostKind.local,
        cancel: CancelToken(),
        execute: (tool) {
          entered.add(tool.id);
          if (tool.id == 'c') {
            return Future.value(
              ToolResult('started', whenSettled: settled.future),
            );
          }
          return Future.value(const ToolResult('file'));
        },
        commit: (tool, _) async {
          committed.add(tool.id);
        },
      );
      await idle();
      expect(entered, ['c']);
      expect(committed, ['c']);

      settled.complete();
      expect(await done, ToolScheduleEnd.done);
      expect(entered, ['c', 'r']);
      expect(committed, ['c', 'r']);
    },
  );

  test('history search starts once earlier results are committed', () async {
    final entered = <String>[];
    final settled = Completer<void>();
    final done = ToolScheduler.run(
      calls: [
        call('r', ToolNames.readFile, {'path': 'a'}),
        call('s', ToolNames.chatHistorySearch, {'query': 'a'}),
      ],
      workspace: '/ws',
      policy: policy,
      hostKind: HostKind.local,
      cancel: CancelToken(),
      execute: (tool) {
        entered.add(tool.id);
        if (tool.id == 'r') {
          return Future.value(ToolResult('file', whenSettled: settled.future));
        }
        return Future.value(const ToolResult('hits'));
      },
      commit: drop,
    );
    await idle();
    expect(entered, ['r', 's']);
    settled.complete();
    expect(await done, ToolScheduleEnd.done);
  });

  test('finish waits for earlier calls and does not start the tail', () async {
    final entered = <String>[];
    final committed = <String>[];
    final head = Completer<ToolResult>();
    final done = ToolScheduler.run(
      calls: [
        call('a', ToolNames.readFile, {'path': 'a'}),
        call('f', ToolNames.finish, {'summary': 'done'}),
        call('b', ToolNames.readFile, {'path': 'b'}),
      ],
      workspace: '/ws',
      policy: policy,
      hostKind: HostKind.local,
      cancel: CancelToken(),
      execute: (tool) {
        entered.add(tool.id);
        if (tool.id == 'a') return head.future;
        return Future.value(ToolResult(tool.id, finish: tool.id == 'f'));
      },
      commit: (tool, result) async {
        committed.add('${tool.id}:${result.text}');
      },
    );
    await idle();
    expect(entered, ['a']);
    head.complete(const ToolResult('ay'));
    expect(await done, ToolScheduleEnd.finish);
    expect(entered, ['a', 'f']);
    expect(committed, ['a:ay', 'f:f', 'b:not executed: the task was finished']);
  });

  test(
    'cancel records in-flight results and does not start dependents',
    () async {
      final entered = <String>[];
      final committed = <String>[];
      final write = Completer<ToolResult>();
      final cancel = CancelToken();
      final done = ToolScheduler.run(
        calls: [
          call('w', ToolNames.writeFile, {'path': 'a', 'content': '1'}),
          call('r', ToolNames.readFile, {'path': 'a'}),
        ],
        workspace: '/ws',
        policy: policy,
        hostKind: HostKind.local,
        cancel: cancel,
        execute: (tool) {
          entered.add(tool.id);
          return write.future;
        },
        commit: (tool, result) async {
          committed.add('${tool.id}:${result.text}');
        },
      );
      await idle();
      expect(entered, ['w']);
      cancel.cancel();
      write.complete(const ToolResult('wrote'));
      expect(await done, ToolScheduleEnd.cancelled);
      expect(committed, ['w:wrote', 'r:cancelled by the user']);
    },
  );

  test('a command refreshes path keys before later tools start', () async {
    final entered = <String>[];
    final command = Completer<ToolResult>();
    final write = Completer<ToolResult>();
    var linked = false;
    final done = ToolScheduler.run(
      calls: [
        call('c', ToolNames.runCommand, {'command': 'ls'}),
        call('w', ToolNames.writeFile, {'path': 'link/a.txt', 'content': 'x'}),
        call('r', ToolNames.readFile, {'path': '/real/a.txt'}),
      ],
      workspace: '/ws',
      policy: policy,
      hostKind: HostKind.local,
      cancel: CancelToken(),
      canonicalize: (path) async {
        if (!linked) return path;
        if (path == '/ws/link/a.txt' || path == '/real/a.txt') {
          return '/real/a.txt';
        }
        return path;
      },
      execute: (tool) {
        entered.add(tool.id);
        if (tool.id == 'c') return command.future;
        if (tool.id == 'w') return write.future;
        return Future.value(const ToolResult('file'));
      },
      commit: drop,
    );
    await idle();
    expect(entered, ['c']);

    linked = true;
    command.complete(const ToolResult('listed'));
    await idle();
    expect(entered, ['c', 'w']);

    write.complete(const ToolResult('wrote'));
    expect(await done, ToolScheduleEnd.done);
    expect(entered, ['c', 'w', 'r']);
  });

  test('session mutations run one after another', () async {
    final entered = <String>[];
    final first = Completer<ToolResult>();
    final done = ToolScheduler.run(
      calls: [
        call('p', ToolNames.pinFact, {'text': 'keep'}),
        call('g', ToolNames.setGoal, {'goal': 'ship'}),
      ],
      workspace: '/ws',
      policy: policy,
      hostKind: HostKind.local,
      cancel: CancelToken(),
      execute: (tool) {
        entered.add(tool.id);
        if (tool.id == 'p') return first.future;
        return Future.value(const ToolResult('goal'));
      },
      commit: drop,
    );
    await idle();
    expect(entered, ['p']);
    first.complete(const ToolResult('pinned'));
    expect(await done, ToolScheduleEnd.done);
    expect(entered, ['p', 'g']);
  });

  test('cancel closes a restored card that has not started yet', () async {
    final committed = <String>[];
    final cancel = CancelToken()..cancel();
    var resumed = false;
    final done = ToolScheduler.run(
      calls: [
        call('q', ToolNames.askUser, {'question': 'there?'}),
      ],
      workspace: '/ws',
      policy: policy,
      hostKind: HostKind.local,
      cancel: cancel,
      resumed: {
        'q': () async {
          resumed = true;
          return const ToolResult('User did not answer');
        },
      },
      execute: (tool) => Future.value(ToolResult(tool.id)),
      commit: (tool, result) async {
        committed.add('${tool.id}:${result.text}');
      },
    );
    expect(await done, ToolScheduleEnd.cancelled);
    expect(resumed, isTrue);
    expect(committed, ['q:User did not answer']);
  });

  test('an already answered call only unblocks what follows it', () async {
    final entered = <String>[];
    final done = ToolScheduler.run(
      calls: [
        call('a', ToolNames.readFile, {'path': 'a'}),
        call('b', ToolNames.readFile, {'path': 'b'}),
      ],
      workspace: '/ws',
      policy: policy,
      hostKind: HostKind.local,
      cancel: CancelToken(),
      alreadyAnswered: {'a'},
      execute: (tool) async {
        entered.add(tool.id);
        return ToolResult(tool.id);
      },
      commit: drop,
    );
    expect(await done, ToolScheduleEnd.done);
    expect(entered, ['b']);
  });
}
