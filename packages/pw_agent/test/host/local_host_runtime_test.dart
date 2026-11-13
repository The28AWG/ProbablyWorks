import 'package:pw_agent/core/domain/host.dart';
import 'package:pw_agent/core/error/app_failure.dart';
import 'package:pw_agent/host/local_host_runtime.dart';
import 'package:test/test.dart';

void main() {
  test('posix and macOS local hosts have a terminal', () {
    expect(LocalHostRuntime(os: HostOs.posix).hasTerminal, isTrue);
    expect(LocalHostRuntime(os: HostOs.macos).hasTerminal, isTrue);
  });

  test('Windows local host runs commands without a terminal', () async {
    final runtime = LocalHostRuntime(os: HostOs.windows);

    expect(runtime.hasTerminal, isFalse);
    await expectLater(
      runtime.openTerminal('echo hello'),
      throwsA(
        isA<HostFailure>().having(
          (error) => error.message,
          'message',
          contains('without a TTY'),
        ),
      ),
    );
  });
}
