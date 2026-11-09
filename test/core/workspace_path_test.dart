import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/core/domain/host.dart';
import 'package:probably_works/core/util/home_path.dart';
import 'package:probably_works/core/util/workspace_path.dart';

Host _host(HostKind kind, {String? workspace}) => Host(
  id: 'h',
  name: 'h',
  kind: kind,
  defaultWorkspace: workspace,
  createdAt: DateTime.utc(2026),
  updatedAt: DateTime.utc(2026),
);

void main() {
  test('лексический ключ схлопывает хвост, точку и регистр диска', () {
    expect(normalizeWorkspacePath('~/repo/', windows: false), '~/repo');
    expect(normalizeWorkspacePath('~/repo/../repo', windows: false), '~/repo');
    expect(
      normalizeWorkspacePath(r'C:\Repo\..\Repo\', windows: true),
      'c:/repo',
    );
    expect(normalizeWorkspacePath('', windows: false), '~');
  });

  test('папка проекта не подменяет отсутствие выбора домом', () {
    final local = _host(HostKind.local);
    final remote = _host(HostKind.ssh);
    final configured = _host(HostKind.local, workspace: '/opt/app');

    expect(explicitProjectWorkspace(local, null), isNull);
    expect(explicitProjectWorkspace(local, '  '), isNull);
    expect(explicitProjectWorkspace(remote, null), isNull);
    expect(explicitProjectWorkspace(local, '/srv/app'), '/srv/app');
    expect(explicitProjectWorkspace(configured, null), '/opt/app');
    expect(explicitProjectWorkspace(configured, '/srv/app'), '/srv/app');
  });

  test('каталог команд остаётся домом, когда проекта нет', () {
    final local = _host(HostKind.local);
    final remote = _host(HostKind.ssh);

    expect(commandWorkspace(local, null), expandHomePath('~'));
    expect(commandWorkspace(remote, null), '~');
    expect(commandWorkspace(local, '/srv/app'), '/srv/app');
    expect(
      commandWorkspace(_host(HostKind.ssh, workspace: '/opt/app'), null),
      '/opt/app',
    );
  });
}
