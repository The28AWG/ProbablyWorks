import 'dart:io';

import 'package:injectable/injectable.dart';
import 'package:path/path.dart' as p;
import 'package:pw_agent/agent/plugins/plugin_registry.dart';
import 'package:pw_agent/core/config/app_paths.dart';
import 'package:pw_agent/core/data/mcp_server_repository.dart';
import 'package:pw_agent/core/data/settings_repository.dart';
import 'package:pw_agent/core/security/secret_store.dart';
import 'package:pw_agent/core/security/security_audit.dart';

/// Детерминированный аудит окружения.
///
/// Проверки только читают конфигурацию и права; они не запускают команды,
/// не читают значения секретов и не ходят в сеть.
@lazySingleton
class SecurityAuditService {
  SecurityAuditService(
    this._paths,
    this._settings,
    this._secrets,
    this._mcp,
    this._plugins,
  );

  final AppPaths _paths;
  final SettingsRepository _settings;
  final SecretStore _secrets;
  final McpServerRepository _mcp;
  final PluginRegistry _plugins;

  /// В GUI-режиме проверяем только то, что видно снаружи. Защиту от самого
  /// агента этот аудит подтвердить не может.
  Future<SecurityReport> run({
    SecurityRunMode mode = SecurityRunMode.gui,
  }) async {
    final findings = <SecurityFinding>[
      if (mode == SecurityRunMode.gui)
        const SecurityFinding(
          code: SecurityFindingCode.guiMode,
          severity: SecuritySeverity.info,
        )
      else
        const SecurityFinding(
          code: SecurityFindingCode.headlessApi,
          severity: SecuritySeverity.info,
        ),
    ];
    _checkRoot(findings);
    _checkSecretStore(findings);
    await _checkPermissions(findings);
    _checkEnvironment(findings);
    await _checkPolicy(findings);
    await _checkExternalTools(findings);
    findings.add(
      SecurityFinding(
        code: SecurityFindingCode.singleInstance,
        severity: SecuritySeverity.info,
        params: {'path': _paths.lockFile.path},
      ),
    );
    final status =
        findings.any((finding) => finding.severity == SecuritySeverity.critical)
        ? SecurityStatus.unsafe
        : SecurityStatus.baseline;
    return SecurityReport(
      generatedAt: DateTime.now(),
      mode: mode,
      platform: Platform.operatingSystemVersion,
      status: status,
      findings: findings,
    );
  }

  void _checkRoot(List<SecurityFinding> findings) {
    if (!_isRoot()) return;
    findings.add(
      const SecurityFinding(
        code: SecurityFindingCode.rootUser,
        severity: SecuritySeverity.critical,
      ),
    );
  }

  void _checkSecretStore(List<SecurityFinding> findings) {
    final (severity, backend) = switch (_secrets.kind) {
      SecretStoreKind.memory => (SecuritySeverity.critical, 'memory'),
      SecretStoreKind.osKeychain => (SecuritySeverity.info, 'os_keychain'),
      SecretStoreKind.headlessFile => (
        SecuritySeverity.warning,
        'headless_file',
      ),
      SecretStoreKind.unknown => (SecuritySeverity.warning, 'unknown'),
    };
    findings.add(
      SecurityFinding(
        code: SecurityFindingCode.secretStore,
        severity: severity,
        params: {'backend': backend},
      ),
    );
  }

  /// Находка, которая заменяет проверку POSIX-режимов на платформе.
  ///
  /// На мобильных граница — не режимы файлов, а UID и песочница ОС: даже
  /// `0644` внутри private storage недоступен другим приложениям. На Windows
  /// ACL пока не проверяются, поэтому честно сообщаем об этом.
  /// `null` означает, что нужно сравнивать POSIX-режимы.
  static SecurityFinding? platformPermissionsFinding({
    required bool mobile,
    required bool windows,
  }) {
    if (mobile) {
      return const SecurityFinding(
        code: SecurityFindingCode.sandboxedStorage,
        severity: SecuritySeverity.info,
      );
    }
    if (windows) {
      return const SecurityFinding(
        code: SecurityFindingCode.permissionsUnknown,
        severity: SecuritySeverity.warning,
      );
    }
    return null;
  }

  Future<void> _checkPermissions(List<SecurityFinding> findings) async {
    final platformFinding = platformPermissionsFinding(
      mobile: Platform.isAndroid || Platform.isIOS,
      windows: Platform.isWindows,
    );
    if (platformFinding != null) {
      findings.add(platformFinding);
      return;
    }
    // Ожидаемые режимы: приложение само создаёт каталоги с 0700 и файлы
    // с 0600. Находка означает, что режим изменили после создания.
    // Lock-файл не содержит данных и в проверку не входит.
    final expectations = [
      (path: _paths.support.path, expected: 0x1C0, directory: true),
      (path: _paths.database.path, expected: 0x180, directory: false),
      (path: _paths.logs.path, expected: 0x1C0, directory: true),
      (path: _paths.mcpConfig.path, expected: 0x180, directory: false),
    ];
    for (final entry in expectations) {
      final path = entry.path;
      if (!FileSystemEntity.isFileSync(path) &&
          !FileSystemEntity.isDirectorySync(path)) {
        continue;
      }
      final stat = FileStat.statSync(path);
      final actual = stat.mode & 0x1FF;
      // Более строгий режим безопасен: сообщаем только о лишних битах.
      if ((actual & ~entry.expected & 0x1FF) == 0) continue;
      // Если родительский каталог недоступен классу пользователей, биты файла
      // для этого класса ничего не дают: до файла нельзя дойти.
      final other = _classCanReach(path, 0x001) ? actual & 0x007 : 0;
      // Каталог с r-x для других — обычная ситуация; критична запись.
      // Файл с любым доступом для других — уже утечка.
      final critical = entry.directory ? (other & 0x002) != 0 : other != 0;
      findings.add(
        SecurityFinding(
          code: SecurityFindingCode.dataPermissions,
          severity: critical
              ? SecuritySeverity.critical
              : SecuritySeverity.warning,
          params: {
            'path': path,
            'mode': _permissions(actual),
            'expected': _permissions(entry.expected),
          },
        ),
      );
    }
  }

  /// Права в формате `rw-r--r--`, без типа файла.
  static String _permissions(int mode) {
    String part(int shift) {
      final bits = (mode >> shift) & 0x7;
      return '${bits & 0x4 != 0 ? 'r' : '-'}'
          '${bits & 0x2 != 0 ? 'w' : '-'}'
          '${bits & 0x1 != 0 ? 'x' : '-'}';
    }

    return '${part(6)}${part(3)}${part(0)}';
  }

  void _checkEnvironment(List<SecurityFinding> findings) {
    final names = [
      for (final key in Platform.environment.keys)
        if (_looksLikeSecret(key)) key,
    ];
    if (names.isEmpty) return;
    findings.add(
      SecurityFinding(
        code: SecurityFindingCode.environmentSecrets,
        severity: SecuritySeverity.warning,
        params: {'keys': names.join(', ')},
      ),
    );
  }

  Future<void> _checkPolicy(List<SecurityFinding> findings) async {
    final policy =
        await _settings.read(SettingsRepository.keyDefaultPolicy) ?? 'ask';
    if (policy == 'yolo') {
      findings.add(
        const SecurityFinding(
          code: SecurityFindingCode.policyYolo,
          severity: SecuritySeverity.warning,
        ),
      );
    }
    if ((await _settings.readDenylist()).isEmpty) {
      findings.add(
        const SecurityFinding(
          code: SecurityFindingCode.emptyDenylist,
          severity: SecuritySeverity.warning,
        ),
      );
    }
  }

  Future<void> _checkExternalTools(List<SecurityFinding> findings) async {
    final enabledPlugins = <String>[];
    for (final plugin in _plugins.plugins) {
      final raw = await _settings.read('plugin.${plugin.id}.enabled');
      final enabled = raw == null ? plugin.defaultEnabled : raw == 'yes';
      if (enabled) enabledPlugins.add(plugin.id);
    }
    final servers = [
      for (final server in await _mcp.all())
        if (server.enabled) server.name,
    ];
    if (enabledPlugins.isEmpty && servers.isEmpty) return;
    findings.add(
      SecurityFinding(
        code: SecurityFindingCode.externalTools,
        severity: SecuritySeverity.warning,
        params: {
          'plugins': enabledPlugins.join(', '),
          'servers': servers.join(', '),
        },
      ),
    );
  }

  /// Может ли класс пользователей дойти до [path]: у всех каталогов от
  /// support до родителя должен быть соответствующий execute-бит.
  bool _classCanReach(String path, int executeBit) {
    if (path == _paths.support.path) return true;
    var directory = File(path).parent;
    while (p.isWithin(_paths.support.path, directory.path) ||
        directory.path == _paths.support.path) {
      final stat = FileStat.statSync(directory.path);
      if ((stat.mode & executeBit) == 0) return false;
      if (directory.path == _paths.support.path) return true;
      directory = directory.parent;
    }
    return true;
  }

  static bool _isRoot() {
    if (Platform.isLinux) {
      try {
        final status = File('/proc/self/status').readAsStringSync();
        final match = RegExp(
          r'^Uid:\s+(\d+)',
          multiLine: true,
        ).firstMatch(status);
        if (match != null) return match.group(1) == '0';
      } on FileSystemException {
        // Не смогли прочитать — ниже проверим окружение.
      }
    }
    return Platform.environment['USER'] == 'root';
  }

  static bool _looksLikeSecret(String key) {
    final upper = key.toUpperCase();
    if (const {
      'SSH_AUTH_SOCK',
      'XAUTHORITY',
      'DBUS_SESSION_BUS_ADDRESS',
      'GPG_AGENT_INFO',
      'SESSION_MANAGER',
    }.contains(upper)) {
      return false;
    }
    return upper.contains('TOKEN') ||
        upper.contains('SECRET') ||
        upper.contains('PASSWORD') ||
        upper.contains('API_KEY') ||
        upper.contains('PRIVATE_KEY') ||
        upper.contains('ACCESS_KEY') ||
        upper.contains('CREDENTIAL');
  }
}
