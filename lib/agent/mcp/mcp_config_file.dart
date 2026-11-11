import 'dart:io';

import 'package:probably_works/agent/mcp/mcp_json_config.dart';
import 'package:probably_works/core/data/mcp_server_repository.dart';
import 'package:probably_works/core/domain/mcp_server.dart';
import 'package:probably_works/core/security/file_permissions.dart';
import 'package:probably_works/core/security/secret_store.dart';

/// Синхронизация `mcp.json` с таблицей серверов.
///
/// Файл — источник для записей [McpServerSource.file]. Пользовательские
/// серверы не трогаются. Сырые значения env/headers при импорте переносятся
/// в [SecretStore], а в БД остаются ссылки `${secret:...}`.
final class McpConfigFile {
  McpConfigFile(this.file, this._repository, this._secrets);

  final File file;
  final McpServerRepository _repository;
  final SecretStore _secrets;

  static final _secretRef = RegExp(r'^\$\{secret:([^}]+)\}$');

  /// Импортирует файл, если он существует. Отсутствие файла — не ошибка.
  Future<void> import() async {
    if (!file.existsSync()) return;
    await importRaw(await file.readAsString());
  }

  /// Импортирует текст `mcp.json` из выбранного пользователем файла.
  Future<void> importRaw(String raw) async {
    final parsed = McpJsonConfig.parse(raw);
    final secured = <McpServerConfig>[
      for (final server in parsed) await _secure(server),
    ];
    await _repository.replaceFileServers(secured);
  }

  /// Экспортирует все серверы, включая пользовательские.
  Future<void> export() async {
    await exportTo(file);
  }

  /// Экспортирует все серверы в [target] и возвращает путь.
  Future<String> exportTo(File target) async {
    final servers = await _repository.all();
    final parent = target.parent;
    if (!parent.existsSync()) await parent.create(recursive: true);
    final temp = File('${target.path}.tmp');
    await temp.writeAsString(McpJsonConfig.encode(servers), flush: true);
    // Режим переносится вместе с файлом при rename.
    FilePermissions.file(temp);
    await temp.rename(target.path);
    return target.path;
  }

  Future<McpServerConfig> _secure(McpServerConfig server) async =>
      server.copyWith(
        env: await _secureMap(server, 'env', server.env),
        headers: await _secureMap(server, 'header', server.headers),
      );

  Future<Map<String, String>> _secureMap(
    McpServerConfig server,
    String kind,
    Map<String, String> values,
  ) async {
    final result = <String, String>{};
    for (final entry in values.entries) {
      if (_secretRef.hasMatch(entry.value)) {
        result[entry.key] = entry.value;
        continue;
      }
      final key = 'mcp.${server.externalKey ?? server.id}.$kind.${entry.key}';
      await _secrets.write(key, entry.value);
      result[entry.key] = '\${secret:$key}';
    }
    return result;
  }
}
