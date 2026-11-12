import 'dart:io';

import 'package:pw_agent/agent/plugins/plugin_registry.dart';
import 'package:pw_agent/core/config/app_paths.dart';
import 'package:pw_agent/core/data/mcp_server_repository.dart';
import 'package:pw_agent/core/data/settings_repository.dart';
import 'package:pw_agent/core/db/app_database.dart';
import 'package:pw_agent/core/db/db_connection.dart';
import 'package:pw_agent/core/security/secret_store.dart';
import 'package:pw_agent/core/security/security_audit.dart';
import 'package:pw_agent/core/security/security_audit_service.dart';
import 'package:test/test.dart';

void main() {
  late AppDatabase db;
  late Directory tmp;
  late SettingsRepository settings;

  setUp(() async {
    db = openInMemoryDatabase();
    tmp = Directory.systemTemp.createTempSync('pw_security_audit');
    settings = SettingsRepository(db);
    await settings.preload();
  });

  tearDown(() async {
    await db.close();
    tmp.deleteSync(recursive: true);
  });

  SecurityAuditService service(SecretStore secrets) => SecurityAuditService(
    AppPaths.forSupport(tmp),
    settings,
    secrets,
    McpServerRepository(db),
    const PluginRegistry([]),
  );

  test('findings are sorted from critical to info', () {
    final sorted = sortFindingsBySeverity([
      const SecurityFinding(
        code: SecurityFindingCode.headlessApi,
        severity: SecuritySeverity.info,
      ),
      const SecurityFinding(
        code: SecurityFindingCode.policyYolo,
        severity: SecuritySeverity.warning,
      ),
      const SecurityFinding(
        code: SecurityFindingCode.rootUser,
        severity: SecuritySeverity.critical,
      ),
    ]);

    expect(sorted.map((finding) => finding.severity), [
      SecuritySeverity.critical,
      SecuritySeverity.warning,
      SecuritySeverity.info,
    ]);
  });

  test('headless mode reports the API instead of GUI mode', () async {
    final report = await service(const _SecureStore())
        .run(mode: SecurityRunMode.headless);

    expect(
      report.findings.any(
        (finding) => finding.code == SecurityFindingCode.headlessApi,
      ),
      isTrue,
    );
    expect(
      report.findings.any(
        (finding) => finding.code == SecurityFindingCode.guiMode,
      ),
      isFalse,
    );
  });

  test('memory secret store is a critical finding', () async {
    final report = await service(MemorySecretStore()).run();

    expect(report.status, SecurityStatus.unsafe);
    expect(
      report.findings.any(
        (finding) =>
            finding.code == SecurityFindingCode.secretStore &&
            finding.severity == SecuritySeverity.critical,
      ),
      isTrue,
    );
  });

  test('secure store without critical findings is baseline only', () async {
    final report = await service(const _SecureStore()).run();

    expect(report.status, SecurityStatus.baseline);
    expect(
      report.findings.any(
        (finding) => finding.code == SecurityFindingCode.guiMode,
      ),
      isTrue,
    );
  });

  test('files created with app-owned modes produce no findings', () async {
    if (Platform.isWindows) return;
    final paths = AppPaths.forSupport(tmp);
    paths.database.writeAsStringSync('test');
    paths.logs.createSync();
    paths.mcpConfig.writeAsStringSync('{}');
    _chmod(tmp.path, '700');
    _chmod(paths.database.path, '600');
    _chmod(paths.logs.path, '700');
    _chmod(paths.mcpConfig.path, '600');

    final report = await service(const _SecureStore()).run();

    expect(report.status, SecurityStatus.baseline);
    expect(
      report.findings.any(
        (finding) => finding.code == SecurityFindingCode.dataPermissions,
      ),
      isFalse,
    );
  });

  test('loosened modes are warnings while the parent protects them', () async {
    if (Platform.isWindows) return;
    final paths = AppPaths.forSupport(tmp);
    paths.database.writeAsStringSync('test');
    _chmod(tmp.path, '700');
    _chmod(paths.database.path, '644');

    final report = await service(const _SecureStore()).run();

    final finding = report.findings.singleWhere(
      (finding) => finding.code == SecurityFindingCode.dataPermissions,
    );
    expect(finding.severity, SecuritySeverity.warning);
    expect(finding.params['expected'], 'rw-------');
    expect(finding.params['mode'], 'rw-r--r--');
    expect(report.status, SecurityStatus.baseline);
  });

  test('reachable loosened mode is critical', () async {
    if (Platform.isWindows) return;
    final paths = AppPaths.forSupport(tmp);
    paths.database.writeAsStringSync('test');
    _chmod(tmp.path, '755');
    _chmod(paths.database.path, '644');

    final report = await service(const _SecureStore()).run();

    expect(report.status, SecurityStatus.unsafe);
    expect(
      report.findings.any(
        (finding) =>
            finding.code == SecurityFindingCode.dataPermissions &&
            finding.severity == SecuritySeverity.critical &&
            finding.params['path'] == paths.database.path,
      ),
      isTrue,
    );
  });

  test('mobile storage uses the sandbox finding instead of file modes', () {
    final finding = SecurityAuditService.platformPermissionsFinding(
      mobile: true,
      windows: false,
    );

    expect(finding?.code, SecurityFindingCode.sandboxedStorage);
    expect(finding?.severity, SecuritySeverity.info);
  });

  test('windows permissions are reported as unchecked', () {
    final finding = SecurityAuditService.platformPermissionsFinding(
      mobile: false,
      windows: true,
    );

    expect(finding?.code, SecurityFindingCode.permissionsUnknown);
    expect(finding?.severity, SecuritySeverity.warning);
  });

  test('world-writable support directory is critical', () async {
    if (Platform.isWindows) return;
    _chmod(tmp.path, '777');

    final report = await service(const _SecureStore()).run();

    expect(report.status, SecurityStatus.unsafe);
    expect(
      report.findings.any(
        (finding) =>
            finding.code == SecurityFindingCode.dataPermissions &&
            finding.severity == SecuritySeverity.critical &&
            finding.params['path'] == tmp.path,
      ),
      isTrue,
    );
  });

  test('yolo policy is reported', () async {
    await settings.write(SettingsRepository.keyDefaultPolicy, 'yolo');
    final report = await service(const _SecureStore()).run();

    expect(
      report.findings.any(
        (finding) => finding.code == SecurityFindingCode.policyYolo,
      ),
      isTrue,
    );
  });
}

final class _SecureStore implements SecretStore {
  const _SecureStore();

  @override
  SecretStoreKind get kind => SecretStoreKind.osKeychain;

  @override
  Future<String?> read(String key) async => null;

  @override
  Future<void> write(String key, String value) => Future<void>.value();

  @override
  Future<void> delete(String key) => Future<void>.value();
}

/// Меняет POSIX-режим и падает, если `chmod` недоступен.
void _chmod(String path, String mode) {
  final result = Process.runSync('chmod', [mode, path]);
  expect(result.exitCode, 0, reason: 'chmod $mode $path');
}
