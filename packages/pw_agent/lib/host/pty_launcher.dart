import 'package:pw_agent/host/host_terminal.dart';

/// Создание PTY-процесса на локальной машине. В приложении — [FlutterPtyLauncher]
/// (пакет flutter_pty2); тесты агента подменяют его, чтобы не зависеть от
/// нативной библиотеки.
abstract interface class PtyLauncher {
  Future<PtyChannel> start(
    String executable,
    List<String> arguments, {
    required Map<String, String> environment,
    required int columns,
    required int rows,
  });
}
