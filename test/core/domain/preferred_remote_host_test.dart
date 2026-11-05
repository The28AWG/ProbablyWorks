import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/core/domain/host.dart';

Host _host(String id, HostKind kind) => Host(
  id: id,
  name: id,
  kind: kind,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

void main() {
  test('без хостов удалённого по умолчанию нет', () {
    expect(preferredRemoteHost(const []), isNull);
  });

  test('локальный хост удалённым не считается', () {
    expect(preferredRemoteHost([_host('local', HostKind.local)]), isNull);
  });

  test('SSH-хост выбирается раньше виртуального, даже если он позже', () {
    final hosts = [
      _host('sandbox', HostKind.virtual),
      _host('server', HostKind.ssh),
    ];

    expect(preferredRemoteHost(hosts)?.id, 'server');
  });

  test('без SSH выбирается виртуальный: iOS без него остался бы без чата', () {
    final hosts = [
      _host('local', HostKind.local),
      _host('sandbox', HostKind.virtual),
    ];

    expect(preferredRemoteHost(hosts)?.id, 'sandbox');
  });
}
