import 'package:pw_agent/core/domain/host.dart';
import 'package:pw_agent/host/local_host_runtime.dart';
import 'package:test/test.dart';

void main() {
  test('every local host has a terminal', () {
    expect(LocalHostRuntime(os: HostOs.posix).hasTerminal, isTrue);
    expect(LocalHostRuntime(os: HostOs.macos).hasTerminal, isTrue);
    expect(LocalHostRuntime(os: HostOs.windows).hasTerminal, isTrue);
  });
}
