import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/features/chat/presentation/widgets/mention_query.dart';
import 'package:probably_works/features/chat/presentation/widgets/mention_text_controller.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/domain/workspace_entry.dart';

void main() {
  MentionRef mention({
    String path = 'src/app.dart',
    int start = 7,
    int end = 16,
  }) => MentionRef(kind: MentionKind.file, path: path, start: start, end: end);

  MentionTextController controller({String text = 'Смотри @app.dart'}) =>
      MentionTextController(text: text, mentions: [mention()]);

  test('insertion before a mention shifts its range', () {
    final value = controller()
      ..value = const TextEditingValue(
        text: 'Смотри ещё @app.dart',
        selection: TextSelection.collapsed(offset: 12),
      );
    expect(value.mentions.single.start, 11);
    expect(value.mentions.single.end, 20);
    expect(value.mentions.single.path, 'src/app.dart');
  });

  test('editing inside the token drops the mention', () {
    final value = controller()
      ..value = const TextEditingValue(
        text: 'Смотри @app.dar',
        selection: TextSelection.collapsed(offset: 15),
      );
    expect(value.mentions, isEmpty);
  });

  test('a letter after an unquoted token drops the mention', () {
    final value = controller()
      ..value = const TextEditingValue(
        text: 'Смотри @app.dartX',
        selection: TextSelection.collapsed(offset: 17),
      );
    expect(value.mentions, isEmpty);
  });

  test('punctuation after a token keeps it', () {
    final value = controller()
      ..value = const TextEditingValue(
        text: 'Смотри @app.dart, пожалуйста',
        selection: TextSelection.collapsed(offset: 17),
      );
    expect(value.mentions.single.path, 'src/app.dart');
  });

  test('deleting the token drops it', () {
    final value = controller()
      ..value = const TextEditingValue(
        text: 'Смотри ',
        selection: TextSelection.collapsed(offset: 7),
      );
    expect(value.mentions, isEmpty);
  });

  test('applySelection adds a mention to a pasted token', () {
    final value = MentionTextController(text: 'Смотри @app.dart');
    const token = MentionQuery(start: 7, end: 16, value: 'app.dart');
    value.applySelection(
      token,
      const WorkspaceEntry(path: 'src/app.dart', isDirectory: false),
    );
    expect(value.mentions.single.path, 'src/app.dart');
    expect(value.mentions.single.start, 7);
    expect(value.mentions.single.end, 16);
    expect(value.text, 'Смотри @app.dart ');
  });

  test('choosing the same basename updates only the path', () {
    final value = controller()
      ..onMentionsChanged = ((mentions) {
        expect(mentions.single.path, 'lib/app.dart');
      });
    const token = MentionQuery(start: 7, end: 16, value: 'app.dart');
    value.applySelection(
      token,
      const WorkspaceEntry(path: 'lib/app.dart', isDirectory: false),
    );
    expect(value.text, 'Смотри @app.dart');
    expect(value.mentions.single.path, 'lib/app.dart');
  });

  test('resetDraft replaces text and mentions without tracking', () {
    final value = controller()..resetDraft('новый текст', const []);
    expect(value.text, 'новый текст');
    expect(value.mentions, isEmpty);
  });

  test('quoted token is kept when typing after the quote', () {
    final value =
        MentionTextController(
            text: 'Смотри @"my file.txt"',
            mentions: const [
              MentionRef(
                kind: MentionKind.file,
                path: 'docs/my file.txt',
                start: 7,
                end: 21,
              ),
            ],
          )
          ..value = const TextEditingValue(
            text: 'Смотри @"my file.txt", пожалуйста',
            selection: TextSelection.collapsed(offset: 22),
          );
    expect(value.mentions.single.path, 'docs/my file.txt');
  });
}
