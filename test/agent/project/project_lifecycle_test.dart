import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/test_support/pipe_pty_launcher.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/domain/project.dart';
import 'package:pw_agent/agent/project/project_lifecycle.dart';
import 'package:pw_agent/core/data/chat_repository.dart';
import 'package:pw_agent/core/data/host_repository.dart';
import 'package:pw_agent/core/data/project_repository.dart';
import 'package:pw_agent/core/data/settings_repository.dart';
import 'package:pw_agent/core/data/virtual_host_provisioner.dart';
import 'package:pw_agent/core/db/app_database.dart';
import 'package:pw_agent/core/db/db_connection.dart';
import 'package:pw_agent/core/domain/host.dart';
import 'package:pw_agent/core/error/app_failure.dart';
import 'package:pw_agent/core/security/secret_store.dart';
import 'package:pw_agent/host/host_op.dart';
import 'package:pw_agent/host/host_runtime.dart';
import 'package:pw_agent/host/host_runtime_factory.dart';
import 'package:pw_agent/host/host_terminal.dart';
import 'package:pw_agent/host/ssh_connection_pool.dart';

final _at = DateTime.utc(2026, 3, 1);

Host _host(
  String id,
  HostKind kind, {
  String? workspace,
  String? address,
  int? timeout,
}) => Host(
  id: id,
  name: id,
  kind: kind,
  address: address,
  defaultWorkspace: workspace,
  connectTimeoutSeconds: timeout,
  createdAt: _at,
  updatedAt: _at,
);

Chat _chat(String id, String hostId, {String? workspace}) => Chat(
  id: id,
  hostId: hostId,
  title: id,
  workspace: workspace,
  createdAt: _at,
  updatedAt: _at,
);

void main() {
  late AppDatabase db;
  late ProjectLifecycleService life;
  late ProjectRepository projects;
  late ChatRepository chats;
  late HostRepository hosts;
  late VirtualHostProvisioner provisioner;

  setUp(() async {
    db = openInMemoryDatabase();
    final settings = SettingsRepository(db);
    await settings.preload();
    final secrets = MemorySecretStore();
    hosts = HostRepository(db, secrets);
    projects = ProjectRepository(db);
    chats = ChatRepository(db);
    provisioner = VirtualHostProvisioner(db);
    life = ProjectLifecycleService(
      db,
      projects,
      hosts,
      HostRuntimeFactory(
        SshConnectionPool(hosts, secrets, settings, HostKeyConfirmations()),
        const PipePtyLauncher(),
        provisioner,
      ),
    );
  });

  tearDown(() => db.close());

  Future<Host> virtual(String id, {String? workspace}) async {
    final host = _host(id, HostKind.virtual, workspace: workspace);
    await hosts.save(host);
    await provisioner.provision(host);
    return host;
  }

  test('канонический ключ схлопывает ~, хвост и симлинк', () async {
    final host = await virtual('box');
    final fs = provisioner.fsOf(host.id);
    await fs.mkdir('/work', recursive: true);
    await fs.mkdir('/work/repo');
    await fs.symlink('/work/repo', '/work/link');

    final tilde = await life.canonicalKey(host, '~/repo/');
    final absolute = await life.canonicalKey(host, '/home/agent/repo');
    final link = await life.canonicalKey(host, '/work/link');
    final target = await life.canonicalKey(host, '/work/repo/');

    expect(tilde, '/home/agent/repo');
    expect(absolute, tilde);
    expect(link, '/work/repo');
    expect(target, link);

    final first = await life.ensureProject(
      hostId: host.id,
      workspace: '~/repo/',
    );
    final second = await life.ensureProject(
      hostId: host.id,
      workspace: '/home/agent/repo',
    );
    expect(second.id, first.id);
  });

  test('недоступный хост оставляет лексический ключ', () async {
    final host = _host('down', HostKind.ssh, address: '127.0.0.1', timeout: 1);
    await hosts.save(host);
    final failingLife = ProjectLifecycleService(
      db,
      projects,
      hosts,
      _FailingRuntimeFactory(
        SshConnectionPool(
          hosts,
          MemorySecretStore(),
          SettingsRepository(db),
          HostKeyConfirmations(),
        ),
        const PipePtyLauncher(),
        provisioner,
      ),
    );

    expect(await failingLife.canonicalKey(host, '~/repo/../repo/'), '~/repo');
  });

  test('чаты без папки не делят домашний проект', () async {
    final host = _host('local', HostKind.local);
    await hosts.save(host);

    final first = await life.attach(_chat('a', host.id));
    final second = await life.attach(_chat('b', host.id));

    expect(first.projectId, isNull);
    expect(first.workspace, isNull);
    expect(second.projectId, isNull);
    expect(await projects.all(), isEmpty);
    expect(await life.findForChat(first), isNull);
  });

  test('явная папка и папка хоста — один проект с общей памятью', () async {
    final host = await virtual('box', workspace: '/opt/app');
    final plain = await virtual('plain');

    final configured = await life.attach(_chat('cfg-a', host.id));
    final sameDefault = await life.attach(_chat('cfg-b', host.id));
    expect(configured.projectId, sameDefault.projectId);
    expect(configured.workspace, '/opt/app');

    await projects.saveMemory(
      ProjectMemory(
        projectId: configured.projectId!,
        summary: 'общий',
        updatedAt: _at,
      ),
    );
    expect((await projects.memory(sameDefault.projectId!))?.summary, 'общий');

    final left = await life.attach(
      _chat('left', plain.id, workspace: '/srv/a'),
    );
    final right = await life.attach(
      _chat('right', plain.id, workspace: '/srv/a/'),
    );
    final other = await life.attach(
      _chat('other', plain.id, workspace: '/srv/b'),
    );
    expect(left.projectId, right.projectId);
    expect(other.projectId, isNot(left.projectId));
    expect(
      await life.findForChat(_chat('soon', plain.id, workspace: '/srv/a')),
      isNotNull,
    );
  });

  test('перенос архивирует пустой проект, смена хоста и очистка папки отвязывают чат', () async {
    final from = await virtual('from');
    final plain = await virtual('plain');
    final to = await virtual('to', workspace: '/opt/next');
    var chat = await life.attach(_chat('move', from.id, workspace: '/work/a'));
    final originId = chat.projectId!;
    await chats.saveChat(chat);

    chat = await life.relocate(
      chat,
      workspace: '/work/b',
      workspaceSpecified: true,
    );
    expect(chat.workspace, '/work/b');
    expect((await chats.chat('move'))!.projectId, chat.projectId);
    expect((await projects.byId(originId))!.isArchived, isTrue);

    final sharedId = chat.projectId!;
    var stay = await life.attach(_chat('stay', from.id, workspace: '/work/b'));
    await chats.saveChat(stay);
    chat = await life.relocate(chat, hostId: plain.id);
    expect(chat.projectId, isNull);
    expect(chat.workspace, isNull);
    expect((await projects.byId(sharedId))!.isArchived, isFalse);

    stay = await life.relocate((await chats.chat('stay'))!, hostId: to.id);
    expect(stay.workspace, '/opt/next');
    expect((await projects.byId(sharedId))!.isArchived, isTrue);

    final cleared = await life.relocate(
      stay,
      workspace: ' ',
      workspaceSpecified: true,
    );
    // У хоста есть своя папка: очистка поля возвращает чат в неё, а не в дом.
    expect(cleared.workspace, '/opt/next');
    expect(cleared.projectId, stay.projectId);

    final loose = await life.attach(
      _chat('loose', plain.id, workspace: '/work/c'),
    );
    await chats.saveChat(loose);
    final detached = await life.relocate(
      loose,
      workspace: '',
      workspaceSpecified: true,
    );
    expect(detached.projectId, isNull);
    expect(detached.workspace, isNull);
    expect((await projects.byId(loose.projectId!))!.isArchived, isTrue);
  });

  test('архив удаляется через неделю и не трогает проект с чатом', () async {
    final host = await virtual('box');
    final project = await life.ensureProject(
      hostId: host.id,
      workspace: '/work/old',
    );
    await life.releaseIfEmpty(project.id);
    final archivedAt = (await projects.byId(project.id))!.archivedAt!;

    await life.purgeExpired(now: archivedAt.add(const Duration(days: 6)));
    expect(await projects.byId(project.id), isNotNull);

    final kept = await life.ensureProject(
      hostId: host.id,
      workspace: '/work/kept',
    );
    await chats.saveChat(
      await life.attach(_chat('alive', host.id, workspace: '/work/kept')),
    );
    await projects.save(
      kept.copyWith(archivedAt: archivedAt.subtract(const Duration(days: 30))),
    );
    await life.purgeExpired(now: archivedAt);
    expect(await projects.byId(kept.id), isNotNull);

    await life.purgeExpired(now: archivedAt.add(const Duration(days: 8)));
    expect(await projects.byId(project.id), isNull);
    expect((await projects.byId(kept.id))!.isArchived, isTrue);
  });

  test('починка не выдаёт домашний проект чату без папки', () async {
    final host = _host('local', HostKind.local);
    await hosts.save(host);
    await chats.saveChat(_chat('orphan', host.id, workspace: '/srv/keep'));
    await chats.saveChat(_chat('loose', host.id));

    await life.repairOrphans();

    final orphan = (await chats.chat('orphan'))!;
    final loose = (await chats.chat('loose'))!;
    expect(orphan.projectId, isNotNull);
    expect(orphan.workspace, '/srv/keep');
    expect(loose.projectId, isNull);
    expect(loose.workspace, isNull);
  });
}

final class _FailingRuntimeFactory extends HostRuntimeFactory {
  // ignore: use_super_parameters, параметры HostRuntimeFactory приватные и из другого пакета
  _FailingRuntimeFactory(
    SshConnectionPool pool,
    PipePtyLauncher pty,
    VirtualHostProvisioner virtual,
  ) : super(pool, pty, virtual);

  @override
  HostRuntime forHost(Host host) => _FailingRuntime(host.os);
}

final class _FailingRuntime implements HostRuntime {
  _FailingRuntime(this.os);

  @override
  final HostOs os;

  @override
  bool get hasTerminal => false;

  @override
  Stream<ExecEvent> perform(HostOp op, {String? cwd, Uint8List? stdin}) =>
      _failure();

  @override
  Stream<ExecEvent> run(String command, {String? cwd, Uint8List? stdin}) =>
      _failure();

  @override
  Future<HostTerminal> openTerminal(
    String command, {
    String? cwd,
    int columns = defaultTerminalColumns,
    int rows = defaultTerminalRows,
  }) async => throw _failureError;

  Stream<ExecEvent> _failure() => Stream.error(_failureError);

  static const _failureError = HostFailure(
    'host is unavailable',
    kind: HostFailureKind.connectionLost,
  );
}
