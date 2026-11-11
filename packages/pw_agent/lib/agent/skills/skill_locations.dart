/// Где искать skills в workspace.
///
/// `.probablyworks/skills` — публичный каталог приложения. Остальные пути — это
/// совместимые каталоги других агентов: они не являются частью публичного
/// контракта ProbablyWorks и проверяются только тогда, когда существуют.
/// Список живёт в одном месте, чтобы загрузчик workspace и планировщик
/// инструментов не расходились.
abstract final class SkillLocations {
  const SkillLocations._();

  /// Каталог приложения. Его можно указывать в документации и UI.
  static const appDirectory = '.probablyworks/skills';

  /// Совместимые каталоги. Порядок задаёт порядок в каталоге skills.
  static const _compatibleDirectories = <String>[
    '.agents/skills',
    '.claude/skills',
    '.codex/skills',
    '.cursor/skills',
    '.gemini/skills',
    '.opencode/skills',
    '.windsurf/skills',
    '.cline/skills',
    '.roo/skills',
    '.continue/skills',
    '.github/skills',
    '.kiro/skills',
    '.amp/skills',
    '.trae/skills',
    '.junie/skills',
    '.warp/skills',
  ];

  /// Абсолютные каталоги skills для [workspace] без дублей.
  ///
  /// Первым всегда идёт каталог приложения: встроенные skills и skills проекта
  /// должны иметь предсказуемый приоритет.
  static List<String> forWorkspace(String workspace) {
    final seen = <String>{};
    final paths = <String>[];
    for (final relative in [appDirectory, ..._compatibleDirectories]) {
      final path = '$workspace/$relative';
      if (seen.add(path)) paths.add(path);
    }
    return paths;
  }
}
