/// Маскирует секреты перед записью в лог, tool_result, вложения и summary.
///
/// Два слоя:
/// 1. известные форматы (ключи провайдеров, Authorization, PEM и т.п.);
/// 2. точные значения, которые приложение прочитало или записало через
///    `SecretStore`. Это ловит ключи произвольного формата.
///
/// Это гигиена вывода, а не sandbox: команда может прочитать секрет и
/// использовать его внутри процесса. Redactor защищает журнал, БД и контекст
/// модели, но не заменяет политику и подтверждения.
abstract final class Redactor {
  const Redactor._();

  /// Слишком короткие значения дают ложные срабатывания на обычном тексте.
  static const _minRegisteredLength = 4;

  static final _registered = <String>{};

  static final _rules = <(RegExp, String Function(Match))>[
    (
      RegExp(
        r'-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----',
      ),
      (_) => '[PRIVATE KEY REDACTED]',
    ),
    // Схема аутентификации остаётся видимой, учётные данные — нет.
    (
      RegExp(
        r'((?:proxy-)?authorization\s*[:=]\s*'
        r'(?:basic|bearer|token|negotiate|ntlm)\s+)[^\s"\x27]+',
        caseSensitive: false,
      ),
      (m) => '${m[1]}***',
    ),
    // Digest содержит несколько параметров через запятую — маскируем строку.
    (
      RegExp(
        r'((?:proxy-)?authorization\s*[:=]\s*digest\s+)[^\r\n]+',
        caseSensitive: false,
      ),
      (m) => '${m[1]}***',
    ),
    (RegExp(r'sk-or-v1-[A-Za-z0-9]{8,}'), (_) => 'sk-or-v1-***'),
    (RegExp(r'\bsk-[A-Za-z0-9_-]{20,}'), (_) => 'sk-***'),
    (RegExp(r'\bAKIA[0-9A-Z]{16}\b'), (_) => 'AKIA***'),
    (RegExp(r'\bhf_[A-Za-z0-9]{20,}\b'), (_) => 'hf_***'),
    // Bearer без заголовка: например, фрагмент команды или текст ошибки.
    (
      RegExp(r'(Bearer\s+)[A-Za-z0-9._~+/=-]{8,}', caseSensitive: false),
      (m) => '${m[1]}***',
    ),
    // *_KEY, *_TOKEN, *_SECRET и обычные api_key/token/password в тексте.
    // Граница слова не даёт принять "monkey=banana" за секрет.
    (
      RegExp(
        r'(\b(?:[A-Za-z0-9]+[_-])*'
        r'(?:api[_-]?key|access[_-]?token|token|secret|password|passwd|key)'
        r'\s*["\x27]?\s*[=:]\s*["\x27]?)[^\s"\x27&]+',
        caseSensitive: false,
      ),
      (m) => '${m[1]}***',
    ),
  ];

  /// Запоминает точное значение секрета для последующего маскирования.
  ///
  /// Вызывается хранилищами при чтении и записи. Секрет не логируется и не
  /// покидает память процесса; для тестов реестр очищается явно.
  static void registerSecret(String? value) {
    if (value == null || value.length < _minRegisteredLength) return;
    _registered.add(value);
  }

  /// Очищает реестр. Нужен тестам и смене профиля/пользователя.
  static void clearRegisteredSecrets() => _registered.clear();

  static String redact(String input) {
    var out = input;
    if (_registered.isNotEmpty) {
      // Длинные значения первыми: иначе короткий секрет может оставить
      // видимый хвост от более длинного.
      final values = _registered.toList()
        ..sort((a, b) => b.length.compareTo(a.length));
      for (final value in values) {
        if (out.contains(value)) out = out.replaceAll(value, '***');
      }
    }
    for (final (pattern, replace) in _rules) {
      out = out.replaceAllMapped(pattern, replace);
    }
    return out;
  }
}
