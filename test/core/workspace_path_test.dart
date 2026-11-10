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

  test('внутри папки проекта в подписи остаётся имя файла', () {
    expect(
      projectFileLabel(
        '/home/user/proj/lib/a.dart',
        workspace: '/home/user/proj',
      ),
      'a.dart',
    );
    expect(
      projectFileLabel('lib/a.dart', workspace: '/home/user/proj'),
      'a.dart',
    );
    expect(
      projectFileLabel('~/proj/src/main.rs', workspace: '~/proj/'),
      'main.rs',
    );
    expect(
      projectFileLabel(
        r'C:\Repo\lib\A.dart',
        workspace: r'c:/repo',
        windows: true,
      ),
      'A.dart',
    );
  });

  test('файл вне папки проекта и путь без папки не сокращаются', () {
    expect(
      projectFileLabel('/etc/hosts', workspace: '/home/user/proj'),
      '/etc/hosts',
    );
    expect(
      projectFileLabel(
        '/home/user/project/a.dart',
        workspace: '/home/user/proj',
      ),
      '/home/user/project/a.dart',
    );
    expect(
      projectFileLabel('../secret.txt', workspace: '/home/user/proj'),
      '../secret.txt',
    );
    expect(
      projectFileLabel('/home/user/proj/a.dart'),
      '/home/user/proj/a.dart',
    );
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
