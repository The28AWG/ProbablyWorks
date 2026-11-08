import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/agent/domain/chat_models.dart';
import 'package:probably_works/agent/policy/command_classifier.dart';
import 'package:probably_works/agent/policy/policy_engine.dart';
import 'package:probably_works/agent/tools/tool_catalog.dart';
import 'package:probably_works/agent/tools/tool_effect.dart';
import 'package:probably_works/core/domain/host.dart';
import 'package:probably_works/providers/ai/llm_port.dart';

void main() {
  final policy = PolicyEngine(
    classifier: CommandClassifier(denylist: const []),
    mode: PolicyMode.yolo,
  );

  ToolEffect effect(
    String name,
    Map<String, dynamic> args, {
    HostKind kind = HostKind.local,
    String? workspace = '/ws',
  }) => toolEffectFor(
    LlmToolCall(id: '1', name: name, arguments: jsonEncode(args)),
    workspace: workspace,
    policy: policy,
    hostKind: kind,
  );

  test('path key joins the workspace and collapses dot segments', () {
    expect(toolPathKey('/ws', 'a/../b'), '/ws/b');
    expect(toolPathKey('/ws', '/abs/x'), '/abs/x');
    expect(toolPathKey('/ws', '~/secret'), '~/secret');
    expect(toolPathKey('/ws', r'C:\proj\a'), r'C:/proj/a');
    expect(hostToolPath('/ws', 'a'), '/ws/a');
    expect(hostToolPath(null, 'a'), 'a');
  });

  test('reads of different files do not conflict', () {
    final left = effect(ToolNames.readFile, {'path': 'a'});
    final right = effect(ToolNames.readFile, {'path': 'b'});
    expect(left.conflictsWith(right), isFalse);
  });

  test('a write conflicts with a later read of the same file only', () {
    final write = effect(ToolNames.writeFile, {'path': 'a/../note.txt'});
    expect(
      write.conflictsWith(effect(ToolNames.readFile, {'path': 'note.txt'})),
      isTrue,
    );
    expect(
      write.conflictsWith(effect(ToolNames.readFile, {'path': 'other.txt'})),
      isFalse,
    );
    expect(
      write.conflictsWith(effect(ToolNames.editFile, {'path': 'other.txt'})),
      isFalse,
    );
  });

  test(
    'a file write conflicts with the parent listing and an ancestor grep',
    () {
      final write = effect(ToolNames.writeFile, {'path': 'src/app.dart'});
      expect(
        write.conflictsWith(effect(ToolNames.listDir, {'path': 'src'})),
        isTrue,
      );
      expect(
        write.conflictsWith(effect(ToolNames.listDir, {'path': '.'})),
        isFalse,
      );
      expect(
        write.conflictsWith(
          effect(ToolNames.grep, {'path': 'src', 'pattern': 'x'}),
        ),
        isTrue,
      );
    },
  );

  test('commands use the whole host, and a denied command has no effect', () {
    final read = effect(ToolNames.readFile, {'path': 'a'});
    final listing = effect(ToolNames.runCommand, {'command': 'ls'});
    final make = effect(ToolNames.runCommand, {'command': 'mkdir build'});
    final sudo = effect(ToolNames.runCommand, {'command': 'sudo ls'});
    expect(listing.conflictsWith(read), isFalse);
    expect(listing.conflictsWith(make), isTrue);
    expect(make.conflictsWith(read), isTrue);
    expect(sudo.conflictsWith(read), isFalse);
  });

  test('background on a virtual host is refused before it touches the fs', () {
    final background = effect(ToolNames.runCommand, {
      'command': 'mkdir build',
      'background': true,
    }, kind: HostKind.virtual);
    expect(
      background.conflictsWith(effect(ToolNames.readFile, {'path': 'a'})),
      isFalse,
    );
  });

  test('session writes share one revision and ignore host files', () {
    final pin = effect(ToolNames.pinFact, {'text': 'keep'});
    final goal = effect(ToolNames.setGoal, {'goal': 'ship'});
    final history = effect(ToolNames.listStateRevisions, {});
    expect(pin.conflictsWith(goal), isTrue);
    expect(pin.conflictsWith(history), isTrue);
    expect(
      pin.conflictsWith(effect(ToolNames.readFile, {'path': 'a'})),
      isFalse,
    );
  });

  test('host registry and settings are different resources', () {
    final add = effect(ToolNames.hostAdd, {'name': 'box', 'address': 'h'});
    final list = effect(ToolNames.hostList, {});
    final check = effect(ToolNames.hostTest, {'id': '1'});
    final settings = effect(ToolNames.settingsUpdate, {'key': 'theme'});
    final read = effect(ToolNames.settingsRead, {});
    expect(add.conflictsWith(list), isTrue);
    expect(check.conflictsWith(list), isTrue);
    expect(add.conflictsWith(settings), isFalse);
    expect(settings.conflictsWith(read), isTrue);
  });

  test(
    'skills see writes under their trees and not the rest of the workspace',
    () {
      final skills = effect(ToolNames.listSkills, {});
      expect(
        skills.conflictsWith(
          effect(ToolNames.writeFile, {
            'path': '.probablyworks/skills/a/SKILL.md',
          }),
        ),
        isTrue,
      );
      expect(
        skills.conflictsWith(
          effect(ToolNames.writeFile, {'path': 'src/a.dart'}),
        ),
        isFalse,
      );
    },
  );

  test('ask_user and a broken payload do not take a host resource', () {
    final ask = effect(ToolNames.askUser, {'question': 'now?'});
    final broken = toolEffectFor(
      const LlmToolCall(id: '1', name: ToolNames.writeFile, arguments: '{'),
      workspace: '/ws',
      policy: policy,
      hostKind: HostKind.local,
    );
    expect(
      ask.conflictsWith(effect(ToolNames.writeFile, {'path': 'a'})),
      isFalse,
    );
    expect(
      broken.conflictsWith(effect(ToolNames.readFile, {'path': 'a'})),
      isFalse,
    );
  });
}
