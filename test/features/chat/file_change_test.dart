import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/app/ui/file_change_view.dart';
import 'package:probably_works/features/chat/presentation/file_change.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/tools/tool_catalog.dart';

ToolRun _run({
  required String tool,
  Map<String, Object?> args = const {},
  String? rawArgs,
  String? command,
}) => ToolRun(
  id: 'r',
  chatId: 'c',
  messageId: 'm',
  toolName: tool,
  argsJson: rawArgs ?? jsonEncode(args),
  command: command,
  status: ToolRunStatus.done,
  startedAt: DateTime.utc(2026),
);

void main() {
  test(
    'write_file is a new file and a trailing newline is not an extra line',
    () {
      final change = fileChangeOf(
        _run(
          tool: ToolNames.writeFile,
          args: {'path': 'lib/a.dart', 'content': 'alpha\nbeta\n'},
          command: 'write /work/lib/a.dart',
        ),
      );

      expect(change, isNotNull);
      final file = change!;
      expect(file.kind, FileChangeKind.created);
      expect(file.path, '/work/lib/a.dart');
      expect(file.added, 2);
      expect(file.removed, 0);
      expect(file.hunkHeader, '@@ -0,0 +1,2 @@');
      expect(file.copyText, 'alpha\nbeta\n');
      expect(file.lines, hasLength(2));
      expect(file.lines.first.kind, FileChangeLineKind.addition);
      expect(file.lines.first.text, 'alpha');
      expect(file.lines.first.newNumber, 1);
      expect(file.lines.first.oldNumber, isNull);
      expect(file.lines.last.text, 'beta');
      expect(file.lines.last.newNumber, 2);
    },
  );

  test('edit_file keeps context and numbers the fragment from 1', () {
    final change = fileChangeOf(
      _run(
        tool: ToolNames.editFile,
        args: {
          'path': 'lib/a.dart',
          'old_string': 'keep\nold\n',
          'new_string': 'keep\nnew\n',
          'replace_all': true,
        },
        command: 'write /work/lib/a.dart',
      ),
    );

    expect(change, isNotNull);
    final file = change!;
    expect(file.kind, FileChangeKind.edited);
    expect(file.replaceAll, isTrue);
    expect(file.added, 1);
    expect(file.removed, 1);
    expect(file.hunkHeader, '@@ -1,2 +1,2 @@');
    expect(file.copyText, '@@ -1,2 +1,2 @@\n keep\n-old\n+new');
    expect(file.lines.map((line) => line.kind), [
      FileChangeLineKind.context,
      FileChangeLineKind.removal,
      FileChangeLineKind.addition,
    ]);
    expect(file.lines.first.oldNumber, 1);
    expect(file.lines.first.newNumber, 1);
    expect(file.lines[1].oldNumber, 2);
    expect(file.lines[1].newNumber, isNull);
    expect(file.lines[2].newNumber, 2);
    expect(file.lines[2].oldNumber, isNull);
  });

  test('apply_patch is an edited file with a parsed unified diff', () {
    const patch = '@@ -1,2 +1,3 @@\n keep\n-old\n+new\n+extra';
    final change = fileChangeOf(
      _run(
        tool: ToolNames.applyPatch,
        args: {'path': 'lib/a.dart', 'patch': patch},
        command: 'write /work/lib/a.dart',
      ),
    );

    expect(change, isNotNull);
    final file = change!;
    expect(file.kind, FileChangeKind.edited);
    expect(file.added, 2);
    expect(file.removed, 1);
    expect(file.hunkHeader, '@@ -1,2 +1,3 @@');
    expect(file.copyText, patch);
    expect(file.lines.map((line) => line.kind), [
      FileChangeLineKind.context,
      FileChangeLineKind.removal,
      FileChangeLineKind.addition,
      FileChangeLineKind.addition,
    ]);
  });

  test('a long write keeps full counts and draws only the first lines', () {
    final change = fileChangeOf(
      _run(tool: ToolNames.writeFile, args: {'content': 'a\nb\nc'}),
      maxLines: 1,
    );

    expect(change, isNotNull);
    final file = change!;
    expect(file.lines, hasLength(1));
    expect(file.lines.single.text, 'a');
    expect(file.added, 3);
    expect(file.totalLines, 3);
    expect(file.truncated, isTrue);
    expect(file.path, '');
  });

  test(
    'escapes in the written text are stripped before the lines are split',
    () {
      final change = fileChangeOf(
        _run(tool: ToolNames.writeFile, args: {'content': 'a\u001b[31mb'}),
      );

      expect(change?.lines.single.text, 'ab');
      expect(change?.copyText, 'ab');
    },
  );

  test('other tools and broken arguments do not become a file change', () {
    expect(
      fileChangeOf(_run(tool: ToolNames.runCommand, args: {'command': 'ls'})),
      isNull,
    );
    expect(
      fileChangeOf(
        _run(tool: ToolNames.writeFile, rawArgs: '{', args: const {}),
      ),
      isNull,
    );
    expect(
      fileChangeOf(_run(tool: ToolNames.writeFile, args: {'path': 'a'})),
      isNull,
    );
    expect(
      fileChangeOf(_run(tool: ToolNames.editFile, args: {'old_string': 'a'})),
      isNull,
    );
  });
}
