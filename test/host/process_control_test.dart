import 'package:flutter_test/flutter_test.dart';
import 'package:pw_agent/core/domain/host.dart';
import 'package:pw_agent/host/process_control.dart';

void main() {
  group('ProcessControl shell override', () {
    test(
      'posix wrap uses the overridden shell for both setsid and fallback paths',
      () {
        final wrapped = ProcessControl(HostOs.posix, shell: 'bash').wrap('ls');
        expect(wrapped, contains('exec setsid -w bash -c'));
        expect(wrapped, contains('else exec bash -c'));
        expect(
          ProcessControl(HostOs.posix, shell: 'bash').shellExecutable,
          'bash',
        );
      },
    );

    test('empty or unsafe shell falls back to sh', () {
      expect(ProcessControl(HostOs.posix).shellExecutable, 'sh');
      expect(ProcessControl(HostOs.posix, shell: '  ').shellExecutable, 'sh');
      expect(
        ProcessControl(
          HostOs.posix,
          shell: 'bash -c; rm -rf /',
        ).shellExecutable,
        'sh',
      );
    });

    test('macOS wrap uses the overridden shell', () {
      expect(
        ProcessControl(HostOs.macos, shell: '/bin/zsh').wrap('ls'),
        startsWith('/bin/zsh -c'),
      );
    });

    test('isValidShell accepts names and paths only', () {
      expect(ProcessControl.isValidShell('bash'), isTrue);
      expect(ProcessControl.isValidShell('/usr/bin/zsh'), isTrue);
      expect(ProcessControl.isValidShell('sh -l'), isFalse);
      expect(ProcessControl.isValidShell(r'$(id)'), isFalse);
    });
  });
}
