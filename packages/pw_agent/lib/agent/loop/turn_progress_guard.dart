/// Вердикт после записи одного результата инструмента.
enum ProgressVerdict {
  /// Состояние меняется: работа продолжается.
  ok,

  /// Похоже на зацикливание: модели стоит сменить подход.
  warn,

  /// Зацикливание подтвердилось после предупреждения.
  stop,
}

/// Детектор работы без прогресса.
///
/// Прогресс — это новое состояние. Если агент повторяет то же действие
/// и получает тот же результат, состояние не меняется. Детектор замечает:
///
/// - одно и то же действие с тем же результатом, повторённое
///   [repeatLimit] раз подряд;
/// - простой цикл `A → B → A → B` (до трёх шагов в цикле), повторённый
///   дважды.
///
/// Первое срабатывание даёт [ProgressVerdict.warn]: вызывающая сторона
/// подсказывает модели сменить подход. Если повторение продолжается,
/// следующая запись даёт [ProgressVerdict.stop].
///
/// Volatile-идентификаторы (`run_id`) не считаются прогрессом: у каждого
/// запуска команды он новый, хотя действие и результат те же.
class TurnProgressGuard {
  TurnProgressGuard({this.repeatLimit = 3})
    : assert(repeatLimit > 0, 'repeatLimit must be positive');

  /// Сколько одинаковых исходов подряд считать отсутствием прогресса.
  final int repeatLimit;

  static const _maxCycle = 3;
  static final _runIdPattern = RegExp(r'run_id:\s*[0-9a-fA-F-]{8,}');

  final List<_Outcome> _recent = [];
  bool _warned = false;

  /// Последнее действие — для лога. Null, пока не записано ни одного исхода.
  String? get lastAction => _recent.isEmpty ? null : _recent.last.tool;

  /// Записывает результат одного инструмента и возвращает вердикт.
  ///
  /// Вызывается в порядке записи результатов в ленту, а не в порядке
  /// завершения параллельных вызовов: иначе повтор одного и того же
  /// действия мог бы выглядеть как прогресс.
  ProgressVerdict record({
    required String tool,
    required String arguments,
    required String result,
    required bool isError,
  }) {
    final normalized = _normalize(result);
    _recent.add((
      tool: tool,
      argumentsHash: _hash(arguments),
      argumentsLength: arguments.length,
      resultHash: _hash(normalized),
      resultLength: normalized.length,
      isError: isError,
    ));
    final window = repeatLimit * 4;
    if (_recent.length > window) {
      _recent.removeRange(0, _recent.length - window);
    }
    if (!_isStalled()) {
      _warned = false;
      return ProgressVerdict.ok;
    }
    if (_warned) return ProgressVerdict.stop;
    _warned = true;
    return ProgressVerdict.warn;
  }

  /// Есть ли в хвосте истории повтор без нового результата.
  bool _isStalled() {
    if (_recent.length < repeatLimit) return false;
    final tailStart = _recent.length - repeatLimit;
    final first = _recent[tailStart];
    var identical = true;
    for (var i = tailStart + 1; i < _recent.length; i++) {
      if (_recent[i] != first) {
        identical = false;
        break;
      }
    }
    if (identical) return true;

    for (var period = 2; period <= _maxCycle; period++) {
      final needed = period * 2;
      if (_recent.length < needed) break;
      final start = _recent.length - needed;
      var same = true;
      for (var i = period; i < needed; i++) {
        if (_recent[start + i] != _recent[start + i - period]) {
          same = false;
          break;
        }
      }
      if (same) return true;
    }
    return false;
  }

  /// FNV-1a по code units. Хеш не зависит от `String.hashCode` и не хранит
  /// большие аргументы и результаты в истории хода.
  static int _hash(String value) {
    var hash = 0x811c9dc5;
    for (final unit in value.codeUnits) {
      hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
    }
    return hash;
  }

  /// `run_id` меняется у каждого запуска и не является новым состоянием.
  static String _normalize(String value) =>
      value.replaceAll(_runIdPattern, 'run_id: <id>');
}

typedef _Outcome = ({
  String tool,
  int argumentsHash,
  int argumentsLength,
  int resultHash,
  int resultLength,
  bool isError,
});
