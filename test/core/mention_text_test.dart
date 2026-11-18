import 'package:flutter_test/flutter_test.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/core/util/mention_text.dart';

void main() {
  group('display tokens', () {
    test('file uses only the last path segment', () {
      expect(
        MentionText.displayToken('src/app.dart', MentionKind.file),
        '@app.dart',
      );
    });

    test('directory keeps a trailing slash', () {
      expect(
        MentionText.displayToken('lib/features', MentionKind.directory),
        '@features/',
      );
    });

    test('spaces are quoted and escaped', () {
      expect(
        MentionText.displayToken('docs/my file.txt', MentionKind.file),
        '@"my file.txt"',
      );
      expect(
        MentionText.displayToken('docs/a"b.txt', MentionKind.file),
        '@"a\\"b.txt"',
      );
    });
  });

  group('resolve', () {
    test('replaces a mention range with the full path', () {
      const text = 'Смотри @app.dart';
      const mention = MentionRef(
        kind: MentionKind.file,
        path: 'src/app.dart',
        start: 7,
        end: 16,
      );
      expect(
        MentionText.resolve(text, const [mention]),
        'Смотри @src/app.dart',
      );
    });

    test('resolves each of two identical basenames by its own range', () {
      const text = '@app.dart и @app.dart';
      const mentions = [
        MentionRef(
          kind: MentionKind.file,
          path: 'src/app.dart',
          start: 0,
          end: 9,
        ),
        MentionRef(
          kind: MentionKind.file,
          path: 'lib/app.dart',
          start: 12,
          end: 21,
        ),
      ];
      expect(
        MentionText.resolve(text, mentions),
        '@src/app.dart и @lib/app.dart',
      );
    });

    test('quotes a full path with spaces', () {
      const text = 'Смотри @"my file.txt"';
      const mention = MentionRef(
        kind: MentionKind.file,
        path: 'docs/my file.txt',
        start: 7,
        end: 21,
      );
      expect(
        MentionText.resolve(text, const [mention]),
        'Смотри @"docs/my file.txt"',
      );
    });

    test('ignores an unsafe or broken range', () {
      const text = '@app.dart';
      const unsafe = MentionRef(
        kind: MentionKind.file,
        path: '../app.dart',
        start: 0,
        end: 9,
      );
      const broken = MentionRef(
        kind: MentionKind.file,
        path: 'app.dart',
        start: 2,
        end: 99,
      );
      expect(MentionText.resolve(text, const [unsafe, broken]), text);
    });

    test('trim shifts a mention and drops one outside the trimmed text', () {
      const text = '  Смотри @app.dart  ';
      const mention = MentionRef(
        kind: MentionKind.file,
        path: 'src/app.dart',
        start: 9,
        end: 18,
      );
      final shifted = MentionText.shiftForTrimmed(text, text.trim(), const [
        mention,
      ]);
      expect(shifted.single.start, 7);
      expect(shifted.single.end, 16);
      expect(
        MentionText.shiftForTrimmed('  @a  ', '', const [mention]),
        isEmpty,
      );
    });

    test('safe path rejects absolute, home and parent segments', () {
      expect(MentionText.isSafePath('src/app.dart'), isTrue);
      expect(MentionText.isSafePath('/etc/passwd'), isFalse);
      expect(MentionText.isSafePath('~/app.dart'), isFalse);
      expect(MentionText.isSafePath('src/../app.dart'), isFalse);
      expect(MentionText.isSafePath(r'src\app.dart'), isFalse);
    });
  });
}
