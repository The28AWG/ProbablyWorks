import 'package:pw_agent/agent/loop/turn_progress_guard.dart';
import 'package:test/test.dart';

ProgressVerdict _record(
  TurnProgressGuard guard, {
  String tool = 'read_file',
  String arguments = '{"path":"a"}',
  String result = 'same',
  bool isError = false,
}) => guard.record(
  tool: tool,
  arguments: arguments,
  result: result,
  isError: isError,
);

List<ProgressVerdict> _recordAll(
  TurnProgressGuard guard,
  List<String> results, {
  String tool = 'read_file',
  String arguments = '{"path":"a"}',
}) => [
  for (final result in results)
    _record(guard, tool: tool, arguments: arguments, result: result),
];

void main() {
  group('TurnProgressGuard', () {
    test('different outcomes are progress', () {
      final guard = TurnProgressGuard();
      expect(_recordAll(guard, ['one', 'two', 'three']), [
        ProgressVerdict.ok,
        ProgressVerdict.ok,
        ProgressVerdict.ok,
      ]);
    });

    test('identical outcome warns once and then stops', () {
      final guard = TurnProgressGuard();
      expect(_recordAll(guard, ['same', 'same', 'same', 'same']), [
        ProgressVerdict.ok,
        ProgressVerdict.ok,
        ProgressVerdict.warn,
        ProgressVerdict.stop,
      ]);
      expect(guard.lastAction, 'read_file');
    });

    test('the same action with a new result is progress', () {
      final guard = TurnProgressGuard();
      expect(_recordAll(guard, ['building', 'building 50%', 'done']), [
        ProgressVerdict.ok,
        ProgressVerdict.ok,
        ProgressVerdict.ok,
      ]);
    });

    test('a two-step cycle warns and then stops', () {
      final guard = TurnProgressGuard();
      expect(_recordAll(guard, ['a', 'b', 'a', 'b', 'a']), [
        ProgressVerdict.ok,
        ProgressVerdict.ok,
        ProgressVerdict.ok,
        ProgressVerdict.warn,
        ProgressVerdict.stop,
      ]);
    });

    test('progress resets the warning', () {
      final guard = TurnProgressGuard();
      expect(
        _recordAll(guard, [
          'same',
          'same',
          'same',
          'new',
          'same',
          'same',
          'same',
        ]),
        [
          ProgressVerdict.ok,
          ProgressVerdict.ok,
          ProgressVerdict.warn,
          ProgressVerdict.ok,
          ProgressVerdict.ok,
          ProgressVerdict.ok,
          ProgressVerdict.warn,
        ],
      );
    });

    test('run_id is volatile and does not count as progress', () {
      final guard = TurnProgressGuard();
      expect(
        _recordAll(guard, [
          'run_id: aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa\nstatus: done',
          'run_id: bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb\nstatus: done',
          'run_id: cccccccc-cccc-cccc-cccc-cccccccccccc\nstatus: done',
        ]),
        [ProgressVerdict.ok, ProgressVerdict.ok, ProgressVerdict.warn],
      );
    });

    test('large results with the same prefix are not identical', () {
      final guard = TurnProgressGuard();
      final prefix = 'a' * 5000;
      expect(_recordAll(guard, ['${prefix}x', '${prefix}y', '${prefix}x']), [
        ProgressVerdict.ok,
        ProgressVerdict.ok,
        ProgressVerdict.ok,
      ]);
    });
  });
}
