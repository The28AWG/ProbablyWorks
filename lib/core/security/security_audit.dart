/// Уровень находки аудита безопасности.
enum SecuritySeverity { critical, warning, info }

/// Итоговая оценка окружения.
enum SecurityStatus { unsafe, baseline, unknown, isolated }

/// Режим, в котором выполняется проверка.
enum SecurityRunMode { gui, headless }

/// Тип находки. Текст и рекомендации локализуются в UI по коду.
enum SecurityFindingCode {
  guiMode,
  rootUser,
  secretStore,
  dataPermissions,
  permissionsUnknown,
  environmentSecrets,
  policyYolo,
  emptyDenylist,
  externalTools,
  headlessApi,
  singleInstance,
}

/// Одна проверка окружения.
final class SecurityFinding {
  const SecurityFinding({
    required this.code,
    required this.severity,
    this.params = const {},
  });

  final SecurityFindingCode code;
  final SecuritySeverity severity;
  final Map<String, String> params;
}

/// Сначала критичные находки, затем предупреждения, затем информация.
List<SecurityFinding> sortFindingsBySeverity(
  Iterable<SecurityFinding> findings,
) =>
    [...findings]..sort((a, b) => a.severity.index.compareTo(b.severity.index));

/// Результат проверки, который показывает вкладка настроек.
final class SecurityReport {
  const SecurityReport({
    required this.generatedAt,
    required this.mode,
    required this.platform,
    required this.status,
    required this.findings,
  });

  final DateTime generatedAt;
  final SecurityRunMode mode;
  final String platform;
  final SecurityStatus status;
  final List<SecurityFinding> findings;

  bool get hasCritical =>
      findings.any((finding) => finding.severity == SecuritySeverity.critical);
}
