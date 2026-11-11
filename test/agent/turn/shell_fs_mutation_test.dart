import 'package:flutter_test/flutter_test.dart';
import 'package:pw_agent/agent/policy/command_classifier.dart';
import 'package:pw_agent/agent/turn/shell_fs_mutation.dart';

void main() {
  final classifier = CommandClassifier(denylist: const []);

  test('read-only auto command is not marked', () {
    expect(shellMayMutateFilesystem(classifier, 'ls -la'), isFalse);
  });

  test('ask-level command may mutate', () {
    expect(shellMayMutateFilesystem(classifier, 'rm file.txt'), isTrue);
  });
}
