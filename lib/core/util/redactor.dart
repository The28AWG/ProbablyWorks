/// Маскирует секреты перед записью в лог, в tool_result, вложения и summary.
abstract final class Redactor {
  const Redactor._();
  static final _rules = <(RegExp, String Function(Match))>[
    (
      RegExp(
        r'-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----',
      ),
      (_) => '[PRIVATE KEY REDACTED]',
    ),
    (RegExp(r'sk-or-v1-[A-Za-z0-9]{8,}'), (_) => 'sk-or-v1-***'),
    (RegExp(r'\bsk-[A-Za-z0-9_-]{20,}'), (_) => 'sk-***'),
    (RegExp(r'\bAKIA[0-9A-Z]{16}\b'), (_) => 'AKIA***'),
    (
      RegExp(r'(Bearer\s+)[A-Za-z0-9._~+/=-]{8,}', caseSensitive: false),
      (m) => '${m[1]}***',
    ),
    (
      RegExp(
        r'((?:api[_-]?key|access[_-]?token|token|secret|password|passwd|authorization)'
        r'["\x27]?\s*[=:]\s*["\x27]?)[^\s"\x27&]+',
        caseSensitive: false,
      ),
      (m) => '${m[1]}***',
    ),
  ];

  static String redact(String input) {
    var out = input;
    for (final (pattern, replace) in _rules) {
      out = out.replaceAllMapped(pattern, replace);
    }
    return out;
  }
}
