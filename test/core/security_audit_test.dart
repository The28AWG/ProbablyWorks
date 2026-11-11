import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/agent/plugins/plugin_catalog.dart';
import 'package:probably_works/app/bootstrap/app_paths.dart';
import 'package:probably_works/core/data/mcp_server_repository.dart';
import 'package:probably_works/core/data/settings_repository.dart';
import 'package:probably_works/core/db/app_database.dart';
import 'package:probably_works/core/db/db_connection.dart';
import 'package:probably_works/core/security/secret_store.dart';
import 'package:probably_works/core/security/security_audit.dart';
import 'package:probably_works/core/security/security_audit_service.dart';

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
    const PluginCatalog(),
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
    final report = await service(
      FlutterSecretStore(const FlutterSecureStorage()),
    ).run();

    expect(report.status, SecurityStatus.baseline);
    expect(
      report.findings.any(
        (finding) => finding.code == SecurityFindingCode.guiMode,
      ),
      isTrue,
    );
  });

  test('protected support directory hides file permission bits', () async {
    if (Platform.isWindows) return;
    final file = File('${tmp.path}/probably_works.db')
      ..writeAsStringSync('test');
    Process.runSync('chmod', ['644', file.path]);
    Process.runSync('chmod', ['700', tmp.path]);

    final report = await service(
      FlutterSecretStore(const FlutterSecureStorage()),
    ).run();

    expect(report.status, SecurityStatus.baseline);
    expect(
      report.findings.any(
        (finding) =>
            finding.code == SecurityFindingCode.dataPermissions &&
            finding.severity == SecuritySeverity.critical,
      ),
      isFalse,
    );
  });

  test('yolo policy is reported', () async {
    await settings.write(SettingsRepository.keyDefaultPolicy, 'yolo');
    final report = await service(
      FlutterSecretStore(const FlutterSecureStorage()),
    ).run();

    expect(
      report.findings.any(
        (finding) => finding.code == SecurityFindingCode.policyYolo,
      ),
      isTrue,
    );
  });
}
