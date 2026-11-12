import 'package:pw_agent/core/security/security_audit.dart';

/// Детерминированный аудит окружения конкретного агента.
///
/// Для удалённого профиля [run] возвращает отчёт, собранный на сервере:
/// клиент не может проверить права и окружение чужой машины локально.
abstract interface class SecurityAuditApi {
  Future<SecurityReport> run({SecurityRunMode mode = SecurityRunMode.gui});
}

/// JSON-представление отчёта для HTTP API.
Map<String, Object?> securityReportToJson(SecurityReport report) => {
  'generatedAt': report.generatedAt.toUtc().toIso8601String(),
  'mode': report.mode.name,
  'platform': report.platform,
  'status': report.status.name,
  'findings': [
    for (final finding in report.findings)
      {
        'code': finding.code.name,
        'severity': finding.severity.name,
        'params': finding.params,
      },
  ],
};

/// Восстанавливает отчёт аудита из JSON API.
SecurityReport securityReportFromJson(
  Map<String, dynamic> json,
) => SecurityReport(
  generatedAt: DateTime.parse('${json['generatedAt']}').toUtc(),
  mode: _enumByName(SecurityRunMode.values, json['mode'], SecurityRunMode.gui),
  platform: '${json['platform'] ?? ''}',
  status: _enumByName(
    SecurityStatus.values,
    json['status'],
    SecurityStatus.unknown,
  ),
  findings: [
    for (final item in (json['findings'] as List? ?? const []))
      if (item is Map)
        SecurityFinding(
          code: _enumByName(
            SecurityFindingCode.values,
            item['code'],
            SecurityFindingCode.guiMode,
          ),
          severity: _enumByName(
            SecuritySeverity.values,
            item['severity'],
            SecuritySeverity.info,
          ),
          params: {
            for (final entry in (item['params'] as Map? ?? const {}).entries)
              '${entry.key}': '${entry.value}',
          },
        ),
  ],
);

T _enumByName<T extends Enum>(List<T> values, Object? raw, T fallback) {
  final name = '$raw';
  for (final value in values) {
    if (value.name == name) return value;
  }
  return fallback;
}
