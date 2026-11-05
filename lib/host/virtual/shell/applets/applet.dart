import 'dart:typed_data';

import 'package:probably_works/host/virtual/shell/shell_io.dart';
import 'package:probably_works/host/virtual/virtual_fs.dart';
import 'package:probably_works/host/virtual/virtual_profile.dart';

/// Апплет: встроенная утилита виртуального Host (подмножество busybox). Работает только через [AppletIo]:
/// читает и пишет в VFS, печатает в приёмники, не трогает процессы и сеть.
///
/// Добавление апплета — один файл и строка в реестре. Интерпретатор не меняется.
abstract interface class Applet {
  /// Имя команды, по которому её вызывает модель.
  String get name;

  /// Выполняет апплет. Возвращает код выхода. Сообщения об ошибках пишет в [AppletIo.stderr] в формате
  /// POSIX: `name: operand: сообщение`. Ошибки VFS можно не перехватывать: интерпретатор выведет их сам.
  Future<int> run(AppletIo io, List<String> args);
}

/// Вызов команды из апплета (например, `xargs`). Работает как обычная команда, без разбора строки оболочкой.
typedef AppletExec = Future<int> Function(List<String> argv, AppletIo io);

/// Окружение одного вызова апплета: потоки, каталог, переменные экспорта и доступ к ФС и профилю Host.
final class AppletIo {
  AppletIo({
    required this.readStdin,
    required this.stdout,
    required this.stderr,
    required this.cwd,
    required this.env,
    required this.fs,
    required this.profile,
    required this.applets,
    required this.exec,
  });

  /// Источник оставшегося входа. Интерпретатор передаёт `ShellInput.takeRest`, поэтому вход
  /// забирается из общего буфера, а не копируется заранее.
  final Uint8List Function() readStdin;
  Uint8List? _stdin;

  /// Весь оставшийся stdin. Читается при первом обращении, а не при запуске: апплет, который вход не
  /// трогает, не забирает строки, которые `read` в цикле ещё не прочитал. Повторные обращения отдают тот
  /// же массив, поэтому апплет может обращаться к нему несколько раз.
  Uint8List get stdin => _stdin ??= readStdin();

  final ShellSink stdout;
  final ShellSink stderr;

  /// Текущий каталог в каноническом виде. Относительные пути апплет разрешает от него.
  final String cwd;

  /// Экспортируемые переменные (то, что видит `env`).
  final Map<String, String> env;

  final VirtualFs fs;

  /// Профиль Host: hostname, пользователь, домашний каталог.
  final VirtualProfile profile;

  /// Реестр апплетов, нужен `which` и `help`-подобным командам.
  final AppletRegistry applets;

  final AppletExec exec;

  /// Копия окружения с заменой части полей. Нужна `env` (другой набор переменных) и `xargs` (другой stdin).
  AppletIo copyWith({
    Uint8List Function()? readStdin,
    ShellSink? stdout,
    ShellSink? stderr,
    String? cwd,
    Map<String, String>? env,
    VirtualFs? fs,
    VirtualProfile? profile,
    AppletRegistry? applets,
    AppletExec? exec,
  }) => AppletIo(
    readStdin: readStdin ?? this.readStdin,
    stdout: stdout ?? this.stdout,
    stderr: stderr ?? this.stderr,
    cwd: cwd ?? this.cwd,
    env: env ?? this.env,
    fs: fs ?? this.fs,
    profile: profile ?? this.profile,
    applets: applets ?? this.applets,
    exec: exec ?? this.exec,
  );
}

/// Реестр апплетов по имени. Имена уникальны: повторная регистрация — ошибка сборки, а не молчаливая
/// подмена одного апплета другим.
final class AppletRegistry {
  factory AppletRegistry(Iterable<Applet> applets) {
    final byName = <String, Applet>{};
    for (final applet in applets) {
      if (byName.containsKey(applet.name)) {
        throw StateError('duplicate applet: ${applet.name}');
      }
      byName[applet.name] = applet;
    }
    return AppletRegistry._(byName);
  }

  const AppletRegistry._(this._byName);

  final Map<String, Applet> _byName;

  /// Апплет по имени или null, если такой команды нет.
  Applet? lookup(String name) => _byName[name];

  /// Все имена команд. Используется `which` и `host_info`, чтобы модель видела реальный набор.
  Set<String> get names => _byName.keys.toSet();
}
