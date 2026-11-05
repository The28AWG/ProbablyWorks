import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/core/domain/host.dart';
import 'package:probably_works/host/virtual/in_memory_vfs_store.dart';
import 'package:probably_works/host/virtual/vfs_store.dart';
import 'package:probably_works/host/virtual/virtual_fs.dart';
import 'package:probably_works/host/virtual/virtual_host_profile.dart';
import 'package:probably_works/host/virtual/virtual_host_seeder.dart';
import 'package:probably_works/host/virtual/virtual_profile.dart';

Host _host(String name) => Host(
  id: 'sandbox',
  name: name,
  kind: HostKind.virtual,
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

void main() {
  group('hostnameFor', () {
    test('переводит название в строчные с дефисами', () {
      expect(hostnameFor('My Server'), 'my-server');
    });

    test('схлопывает повторы и убирает дефисы по краям', () {
      expect(hostnameFor('  --Sandbox__01!!  '), 'sandbox-01');
    });

    test('без допустимых символов даёт запасное имя', () {
      expect(hostnameFor('Песочница'), 'probably');
      expect(hostnameFor('   '), 'probably');
    });

    test('обрезает до 63 символов и не оставляет дефис в конце', () {
      final name = '${'a' * 62}-bbbb';
      final result = hostnameFor(name);

      expect(result.length, lessThanOrEqualTo(63));
      expect(result.endsWith('-'), isFalse);
    });
  });

  test(
    'профиль берёт имя хоста из названия, пользователь и дом фиксированы',
    () {
      final profile = virtualProfileFor(_host('Work Box'));

      expect(profile.hostname, 'work-box');
      expect(profile.user, 'agent');
      expect(profile.home, '/home/agent');
      expect(profile.unameLine, contains('work-box'));
    },
  );

  group('seedVirtualHost', () {
    late VirtualFs fs;
    const profile = VirtualProfile();

    setUp(() {
      fs = VirtualFs(InMemoryVfsStore(), clock: () => 1700000000);
    });

    test('создаёт домашний каталог и /tmp с правами sticky', () async {
      await seedVirtualHost(fs, profile);

      expect((await fs.stat('/home/agent'))?.kind, VfsNodeKind.dir);
      final tmp = await fs.stat('/tmp');
      expect(tmp?.kind, VfsNodeKind.dir);
      expect(tmp?.mode, 1023);
    });

    test('повторный вызов не трогает файлы пользователя', () async {
      await seedVirtualHost(fs, profile);
      await fs.writeBytes(
        '/home/agent/notes.txt',
        Uint8List.fromList(utf8.encode('важно')),
      );

      await seedVirtualHost(fs, profile);

      final bytes = await fs.readBytes('/home/agent/notes.txt');
      expect(utf8.decode(bytes), 'важно');
    });
  });
}
