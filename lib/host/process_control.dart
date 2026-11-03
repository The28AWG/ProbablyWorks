import 'package:probably_works/core/domain/host.dart';
import 'package:probably_works/core/util/shell_quote.dart';

/// Управление группой процессов команды по ОС Host.
///
/// - Linux/posix: `setsid -w sh -c` делает команду лидером группы (util-linux). Если `setsid -w`
///   не поддерживается (BusyBox), команда запускается без него. kill — группе (`-pgid`) и дереву детей.
/// - macOS: нет `setsid` по умолчанию, поэтому kill идёт по дереву детей снизу вверх.
/// - Windows: `taskkill /T` убивает дерево процессов.
class ProcessControl {
  ProcessControl(this.os, {String? shell}) : _shell = _safeShell(shell);

  final HostOs os;

  /// Оболочка, которой выполняется команда на posix/macOS (`shellOverride` Host или `sh`).
  final String _shell;

  /// Только имя или путь исполняемого файла: произвольный текст из Settings в командной строке недопустим.
  static String _safeShell(String? value) {
    final trimmed = value?.trim() ?? '';
    return trimmed.isNotEmpty && isValidShell(trimmed) ? trimmed : 'sh';
  }

  static final _shellPattern = RegExp(r'^[A-Za-z0-9_./-]+$');

  /// Допустимое значение shellOverride: имя или путь без пробелов и спецсимволов shell.
  static bool isValidShell(String value) => _shellPattern.hasMatch(value);

  static const markerPrefix = 'PW_PID:';

  /// Оборачивает скрипт так, чтобы его pid был виден и был лидером группы.
  /// Первая строка stdout — `PW_PID:<pid>` (маркер для posix/macOS).
  String wrap(String script) => switch (os) {
    HostOs.windows => script,
    HostOs.macos => '$_shell -c ${shQuote('echo $markerPrefix\$\$; $script')}',
    _ => _posixWrap(script),
  };

  /// Обёртка для запуска в PTY. `setsid` не нужен: PTY делает процесс лидером сессии и группы сам.
  /// `exec` сохраняет pid, поэтому маркер `$$` совпадает с pid группы, и kill по нему работает.
  /// Пейджеры отключаются: интерактивный `less` иначе повиснет без ввода агента.
  ///
  /// Конец команды: обёртка печатает маркер кода выхода в самом потоке вывода и ждёт строку
  /// подтверждения (см. [exitMarkerPrefix]). Так весь вывод доставлен до того, как процесс завершится:
  /// вывод PTY закрывается сразу после кода выхода и мог бы потерять хвост.
  String wrapTerminal(String script) => switch (os) {
    HostOs.windows => script,
    _ =>
      'exec $_shell -c ${shQuote('$_terminalEnv echo $markerPrefix\$\$; ( $script\n); $_terminalEpilogue')}',
  };

  static const _terminalEnv =
      'export TERM=xterm-256color PAGER=cat GIT_PAGER=cat;';

  static const _terminalEpilogue =
      r'pw_rc=$?; stty -echo 2>/dev/null; '
      r'printf "\033]PW;EXIT=%s\007" "$pw_rc"; read -r pw_ack; exit "$pw_rc"';

  /// Начало маркера кода выхода в выводе PTY: `ESC ] PW;EXIT=`. Завершается BEL и кодом.
  static const exitMarkerPrefix = '\x1b]PW;EXIT=';

  /// `setsid -w` есть в util-linux, но не в BusyBox (Alpine), где он падает с ошибкой опции.
  /// Если `setsid -w` недоступен, команда запускается напрямую: на SSH она уже лидер группы (sshd).
  String _posixWrap(String script) {
    final inner = shQuote('echo $markerPrefix\$\$; $script');
    return 'if setsid -w true >/dev/null 2>&1; then exec setsid -w $_shell -c $inner; '
        'else exec $_shell -c $inner; fi';
  }

  /// Есть ли маркер pid в выводе (на Windows pid берётся из Process напрямую).
  bool get hasPidMarker => os != HostOs.windows;

  /// Команда остановки процесса (и его группы/дерева).
  String killCommand(int pid, {bool force = false}) {
    final signal = force ? 'KILL' : 'TERM';
    return switch (os) {
      HostOs.windows =>
        force ? 'taskkill /T /F /PID $pid' : 'taskkill /T /PID $pid',
      HostOs.macos => _treeKill(pid, signal),
      _ => 'kill -s $signal -- -$pid 2>/dev/null; ${_treeKill(pid, signal)}',
    };
  }

  /// Убивает детей снизу вверх через `pgrep -P` (работает и без групп процессов).
  static String _treeKill(int pid, String signal) =>
      'pw_kill() { for c in \$(pgrep -P "\$1" 2>/dev/null); do pw_kill "\$c" "\$2"; done; '
      'kill -s "\$2" "\$1" 2>/dev/null; }; pw_kill $pid $signal; true';

  /// Тип оболочки, которой запускается команда на хосте.
  String get shellExecutable => os == HostOs.windows ? 'cmd' : _shell;

  List<String> shellArgs(String wrapped) =>
      os == HostOs.windows ? ['/c', wrapped] : ['-c', wrapped];
}
