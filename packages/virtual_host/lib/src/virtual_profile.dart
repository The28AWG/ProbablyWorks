/// Профиль виртуального Host: то, что на реальной машине дают `hostname`, `id -un`, `$HOME` и `$SHELL`.
///
/// Модель видит профиль через `host_info`, поэтому значения по умолчанию — её представление о среде.
final class VirtualProfile {
  const VirtualProfile({
    this.hostname = 'probably',
    this.user = 'agent',
    this.home = '/home/agent',
    this.shell = '/bin/sh',
    this.bootedAt = 0,
    this.environment = const {},
  });

  final String hostname;
  final String user;

  /// Домашний каталог. Тильда и `cd` без аргументов раскрываются в него.
  final String home;

  /// Путь оболочки. Для команд `echo $SHELL` и `host_info`.
  final String shell;

  /// Момент запуска Host в секундах Unix: от него `uptime` считает время работы. Ноль — неизвестен.
  final int bootedAt;

  /// Переменные, которые оболочка экспортирует после встроенных.
  ///
  /// Имя должно совпадать с `[A-Za-z_][A-Za-z0-9_]*`, иначе [ShellState.initial]
  /// бросает ошибку. `HOME`, `PATH` и остальные встроенные имена из этой карты
  /// не перезаписываются. `host_info` карту не печатает: секрет не должен попасть
  /// в контекст модели на каждом ходе. Значения живут только в памяти профиля.
  final Map<String, String> environment;

  /// Вывод `uname -a` для этого профиля.
  String get unameLine =>
      'Linux $hostname 6.1.0-virtual #1 SMP x86_64 GNU/Linux';
}
