import 'package:probably_works/host/virtual/shell/shell_ast.dart';
import 'package:probably_works/host/virtual/virtual_profile.dart';

/// Состояние оболочки одного запуска: переменные, экспортируемые имена, текущий каталог, код последней
/// команды (`$?`), функции, позиционные параметры и вложенность циклов и вызовов.
///
/// Каждый запуск `run_command` начинается с чистого состояния, как отдельный `bash -c` на реальном Host:
/// `cd` и присваивания не переживают запуск. Подоболочки (пайп, `( )`, `$(...)`) работают с копией [fork].
final class ShellState {
  ShellState({
    required this.cwd,
    required this.vars,
    required this.exported,
    this.lastStatus = 0,
    Map<String, FunctionDefinition>? functions,
    List<String>? positional,
    this.functionDepth = 0,
    List<Map<String, String?>>? localFrames,
    this.loopDepth = 0,
  }) : functions = functions ?? {},
       positional = positional ?? [],
       localFrames = localFrames ?? [];

  /// Состояние нового запуска: переменные окружения профиля Host в каталоге [cwd].
  factory ShellState.initial(VirtualProfile profile, String cwd) {
    final vars = <String, String>{
      'HOME': profile.home,
      'USER': profile.user,
      'LOGNAME': profile.user,
      'HOSTNAME': profile.hostname,
      'SHELL': profile.shell,
      'PATH': '/usr/local/bin:/usr/bin:/bin',
      'PWD': cwd,
      'LANG': 'C.UTF-8',
    };
    return ShellState(
      cwd: cwd,
      vars: vars,
      exported: {'HOME', 'USER', 'LOGNAME', 'SHELL', 'PATH', 'PWD', 'LANG'},
    );
  }

  /// Текущий каталог в каноническом виде ([VfsPath]).
  String cwd;

  /// Значения переменных. Отсутствие ключа означает «не задана».
  final Map<String, String> vars;

  /// Имена, которые передаются апплетам в окружении (`export`).
  final Set<String> exported;

  /// Код последней завершённой команды или конвейера: значение `$?`.
  int lastStatus;

  /// Функции, определённые в этом запуске. Подоболочка получает копию: функция, описанная в ней, наружу
  /// не выходит, как в bash.
  final Map<String, FunctionDefinition> functions;

  /// Позиционные параметры `$1`, `$2`, ... `$#`. В функции — её аргументы; на верхнем уровне пусты,
  /// как у `bash -c` без аргументов.
  List<String> positional;

  /// Глубина вызова функций. Вне функции `return` и `local` — ошибка.
  int functionDepth;

  /// Значения переменных до `local` в каждом вызове функции: при выходе восстанавливаются. `null` — переменной
  /// не было. Глубина стека совпадает с [functionDepth].
  final List<Map<String, String?>> localFrames;

  /// Число вложенных циклов. `break` и `continue` вне цикла — no-op с сообщением, как в bash.
  int loopDepth;

  /// Копия для подоболочки: изменения в ней не видны родителю.
  ShellState fork() => ShellState(
    cwd: cwd,
    vars: {...vars},
    exported: {...exported},
    lastStatus: lastStatus,
    functions: {...functions},
    positional: [...positional],
    functionDepth: functionDepth,
    localFrames: [
      for (final frame in localFrames) {...frame},
    ],
    loopDepth: loopDepth,
  );

  String? get(String name) => vars[name];

  void set(String name, String value) => vars[name] = value;

  /// Вход в функцию: новые позиционные параметры и пустая запись для `local`. Возвращает прежние
  /// параметры, которые [leaveFunction] вернёт на место.
  List<String> enterFunction(List<String> args) {
    final saved = positional;
    positional = args;
    functionDepth++;
    localFrames.add({});
    return saved;
  }

  /// Выход из функции: переменные, перекрытые `local`, возвращаются к прежним значениям, а параметры — к
  /// [savedPositional].
  void leaveFunction(List<String> savedPositional) {
    final frame = localFrames.removeLast();
    for (final MapEntry(:key, :value) in frame.entries) {
      if (value == null) {
        vars.remove(key);
      } else {
        vars[key] = value;
      }
    }
    positional = savedPositional;
    functionDepth--;
  }

  /// `local NAME[=VALUE]`: переменная видна только внутри текущего вызова функции. Прежнее значение
  /// запоминается при первом `local` для имени в этом вызове.
  void declareLocal(String name, String? value) {
    final frame = localFrames.last;
    if (!frame.containsKey(name)) frame[name] = vars[name];
    if (value == null) {
      vars.remove(name);
    } else {
      vars[name] = value;
    }
  }

  /// Окружение для апплета: только экспортируемые переменные, которые заданы.
  Map<String, String> environment() => {
    for (final name in exported) name: ?vars[name],
  };
}
