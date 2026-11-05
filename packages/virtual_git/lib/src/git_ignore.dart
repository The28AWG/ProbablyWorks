// Перенос git_core (MIT), см. THIRD_PARTY_LICENSE. Поведение совпадает с референсом.
final class GitIgnoreMatch {
  const GitIgnoreMatch({
    required this.path,
    required this.pattern,
    required this.source,
    required this.lineNumber,
  });

  final String path;
  final String pattern;
  final String source;
  final int lineNumber;
}
