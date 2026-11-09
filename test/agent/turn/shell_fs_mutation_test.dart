import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/agent/policy/command_classifier.dart';
import 'package:probably_works/agent/turn/shell_fs_mutation.dart';

void main() {
  final classifier = CommandClassifier(denylist: const []);

  test('read-only auto command is not marked', () {
    expect(shellMayMutateFilesystem(classifier, 'ls -la'), isFalse);
  });

  test('ask-level command may mutate', () {
    expect(shellMayMutateFilesystem(classifier, 'rm file.txt'), isTrue);
  });
}
