import 'package:pw_agent/core/domain/host.dart';
import 'package:pw_agent/core/util/shell_quote.dart';

/// Окружение локального процесса: карта хоста поверх машины.
/// В терминале `TERM` ставится последним, иначе тип терминала потеряется, если хост его переопределил.
Map<String, String> localSessionEnvironment({
  required Map<String, String> machine,
  required Map<String, String> host,
  bool terminal = false,
}) {
  _requireNames(host);
  return {...machine, ...host, if (terminal) 'TERM': 'xterm-256color'};
}

/// Префикс переменных хоста перед уже обёрнутым скриптом SSH.
/// Канал `environment` у dartssh2 не используется: OpenSSH без `AcceptEnv` такие переменные молча
/// отбрасывает, а присваивание в начале команды работает на обычном сервере.
/// Пустая карта возвращает [script] как есть, поэтому текст команды агента не меняется.
/// Имя не экранируется — оно уже прошло [isHostEnvironmentName]; значение экранируется.
String withHostEnvironment(
  String script, {
  required HostOs os,
  required Map<String, String> environment,
}) {
  if (environment.isEmpty) return script;
  _requireNames(environment);
  final buffer = StringBuffer();
  for (final entry in environment.entries) {
    if (os == HostOs.windows) {
      buffer.write('\$env:${entry.key}=${psQuote(entry.value)};');
    } else {
      buffer.write('export ${entry.key}=${shQuote(entry.value)};');
    }
  }
  return '$buffer$script';
}

void _requireNames(Map<String, String> environment) {
  for (final name in environment.keys) {
    if (!isHostEnvironmentName(name)) {
      throw ArgumentError.value(
        name,
        'environment',
        'Имя переменной должно совпадать с [A-Za-z_][A-Za-z0-9_]*.',
      );
    }
  }
}
