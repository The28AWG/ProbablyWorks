import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/core/util/unified_diff.dart';

void main() {
  test('replaces a line and keeps the trailing newline', () {
    const patch = '@@ -1,3 +1,3 @@\n a\n-old\n+new\n c';
    final result = applyUnifiedDiff('a\nold\nc\n', parseUnifiedDiff(patch));

    expect(result, 'a\nnew\nc\n');
  });

  test(
    'applies several hunks from the bottom without shifting line numbers',
    () {
      const patch = '''
@@ -1,2 +1,3 @@
 a
+inserted
 b
@@ -4,2 +5,2 @@
-old
+new
 d''';
      final result = applyUnifiedDiff(
        'a\nb\nc\nold\nd\n',
        parseUnifiedDiff(patch),
      );

      expect(result, 'a\ninserted\nb\nc\nnew\nd\n');
    },
  );

  test('inserts an empty hunk after the stated line', () {
    const patch = '@@ -1,0 +2,1 @@\n+inserted';
    final result = applyUnifiedDiff('a\nb\n', parseUnifiedDiff(patch));

    expect(result, 'a\ninserted\nb\n');
  });

  test('rejects a context mismatch and changes nothing', () {
    const patch = '@@ -1,1 +1,1 @@\n wrong\n+new';

    expect(
      () => applyUnifiedDiff('old\n', parseUnifiedDiff(patch)),
      throwsFormatException,
    );
  });

  test('rejects a hunk whose counts do not match its body', () {
    const patch = '@@ -1,2 +1,2 @@\n-old\n+new';

    expect(() => parseUnifiedDiff(patch), throwsFormatException);
  });

  test('preserves CRLF', () {
    const patch = '@@ -1,1 +1,1 @@\n-old\n+new';
    final result = applyUnifiedDiff('old\r\n', parseUnifiedDiff(patch));

    expect(result, 'new\r\n');
  });

  test('adds lines to an empty file', () {
    const patch = '@@ -0,0 +1,2 @@\n+one\n+two';
    final result = applyUnifiedDiff('', parseUnifiedDiff(patch));

    expect(result, 'one\ntwo');
  });
}
