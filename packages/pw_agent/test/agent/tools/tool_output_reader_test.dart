import 'package:pw_agent/agent/tools/tool_output_reader.dart';
import 'package:test/test.dart';

const _runTarget = 'read_run_output run_id=r1';

void main() {
  group('ToolOutputReader tail', () {
    test('returns the end of the text and points deeper', () {
      final text = '${'a' * 200}THE-END-MARKER';
      final result = ToolOutputReader(_runTarget)
          .read({'limit': 40}, text, const ['run_id: r1']);

      expect(result.isError, isFalse);
      expect(result.text, contains('start_offset:'));
      expect(result.text, contains('$_runTarget mode=chunk'));
      expect(result.text, contains('THE-END-MARKER'));
      expect(result.text, isNot(contains('a' * 200)));
    });

    test('short text is reported as the start of retained text', () {
      final result = ToolOutputReader(_runTarget)
          .read({'limit': 4000}, 'hello', const ['run_id: r1']);

      expect(result.text, contains('[start of retained text]'));
      expect(result.text, contains('\n\nhello\n\n'));
    });
  });

  group('ToolOutputReader chunk', () {
    test('reads a window and points to the next offset', () {
      final text = '0123456789' * 10;
      final result = ToolOutputReader(_runTarget)
          .read({'mode': 'chunk', 'offset': 10, 'limit': 20}, text, const []);

      expect(result.text, contains('offset: 10'));
      expect(result.text, contains('mode=chunk offset=30 limit=20'));
    });

    test('an offset past the end gives a reason instead of text', () {
      final result = ToolOutputReader(_runTarget)
          .read({'mode': 'chunk', 'offset': 100}, 'short', const []);

      expect(result.text, contains('is past the end'));
    });

    test('unknown mode is an argument error, not a silent tail', () {
      expect(
        () =>
            ToolOutputReader(_runTarget)
                .read({'mode': 'whole'}, 'text', const []),
        throwsArgumentError,
      );
    });
  });

  group('ToolOutputReader grep', () {
    test('finds a line with context and its offset', () {
      final result = ToolOutputReader(_runTarget).read(
        {'mode': 'grep', 'pattern': 'ERROR', 'context': 1},
        'alpha\nbeta\ngamma\nERROR here\ndelta',
        const [],
      );

      expect(result.text, contains('matches: 1'));
      expect(result.text, contains('ERROR here'));
      expect(result.text, contains('[line 4, offset'));
    });

    test('literal search ignores regex metacharacters', () {
      final result = ToolOutputReader(_runTarget).read(
        {'mode': 'grep', 'pattern': 'a.b', 'regex': false},
        'a.b\naxb',
        const [],
      );

      expect(result.text, contains('matches: 1'));
    });

    test('an invalid pattern is an error result', () {
      final result = ToolOutputReader(_runTarget)
          .read({'mode': 'grep', 'pattern': '('}, 'text', const []);

      expect(result.isError, isTrue);
      expect(result.text, contains('invalid pattern'));
    });

    test('no matches explains what to try next', () {
      final result = ToolOutputReader(_runTarget)
          .read({'mode': 'grep', 'pattern': 'absent'}, 'alpha', const []);

      expect(result.text, contains('no matches'));
    });
  });

  group('clampToolText', () {
    test('short text is kept whole under its header', () {
      final text = clampToolText(
        text: 'ok',
        maxChars: 100,
        header: const ['run_id: r1'],
        target: _runTarget,
      );

      expect(text, 'run_id: r1\noutput: 2 chars\nok');
    });

    test('long text keeps the tail and points to the full text', () {
      final text = clampToolText(
        text: 'x' * 100,
        maxChars: 10,
        header: const ['run_id: r1'],
        target: _runTarget,
      );

      expect(text, contains('showing: last 10 chars'));
      expect(text, contains('read more: $_runTarget'));
      expect(text, endsWith('x' * 10));
    });
  });
}
