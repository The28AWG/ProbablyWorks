import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:probably_works/app/profiles/local_daemon_discovery.dart';
import 'package:pw_agent/core/config/app_paths.dart';
import 'package:pw_agent/core/config/local_daemon_info.dart';
import 'package:pw_agent/core/logging/app_log.dart';

/// Запускает локальный демон в development-сборке или из установленного пакета.
abstract interface class DaemonLauncher {
  /// Запускает процесс демона и возвращает true, если он стартовал.
  ///
  /// Успешный старт процесса не означает готовность API: вызывающая сторона
  /// ждёт discovery-файл и health-проверку.
  Future<bool> start(AppPaths paths);
}

/// Автозапуск отключён: GUI должен работать embedded.
///
/// Переменная нужна для отладки и тестов, где нельзя поднимать второй процесс.
bool localDaemonDisabled([Map<String, String>? environment]) =>
    (environment ?? Platform.environment)['PROBABLY_WORKS_NO_DAEMON'] == '1';

/// Выбирает стратегию запуска для текущего способа поставки.
///
/// В dev рядом лежит исходник `pw_server`, после сборки — готовый бинарник.
/// Параметры `release` и `environment` нужны тестам и не влияют на вызовы из
/// приложения.
DaemonLauncher createDaemonLauncher({
  bool release = kReleaseMode,
  Map<String, String>? environment,
}) {
  final env = environment ?? Platform.environment;
  if (localDaemonDisabled(env)) return const DisabledDaemonLauncher();
  return release
      ? const PackagedDaemonLauncher()
      : const DevelopmentDaemonLauncher();
}

/// Заглушка для `PROBABLY_WORKS_NO_DAEMON=1`: демон не запускается.
final class DisabledDaemonLauncher implements DaemonLauncher {
  const DisabledDaemonLauncher();

  @override
  Future<bool> start(AppPaths paths) async => false;
}

/// В dev GUI и демон — разные процессы, но оба запускаются из репозитория.
///
/// Скрипт ищется вверх от текущего каталога: IDE и `flutter run` могут держать
/// рабочую директорию как в корне репозитория, так и в подкаталоге.
final class DevelopmentDaemonLauncher implements DaemonLauncher {
  const DevelopmentDaemonLauncher();

  @override
  Future<bool> start(AppPaths paths) async {
    final override = Platform.environment['PROBABLY_WORKS_SERVER'];
    if (override != null) {
      // Переопределение может указывать и на скрипт, и на собранный бинарник.
      return override.endsWith('.dart')
          ? _runScript(_dartExecutable(), override, paths)
          : _detached(override, _daemonArgs(paths), override);
    }
    final script = _findServerScript();
    if (script == null) return false;
    return _runScript(_dartExecutable(), script, paths);
  }

  /// Ищет Dart из Flutter SDK, если `dart` нет в PATH.
  static String _dartExecutable() {
    final override = Platform.environment['PROBABLY_WORKS_DART'];
    if (override != null) return override;
    final root = Platform.environment['FLUTTER_ROOT'];
    if (root != null) {
      final dart = p.join(
        root,
        'bin',
        Platform.isWindows ? 'dart.exe' : 'dart',
      );
      if (File(dart).existsSync()) return dart;
    }
    return 'dart';
  }

  static Future<bool> _runScript(
    String executable,
    String script,
    AppPaths paths,
  ) => _detached(
    executable,
    ['run', script, ..._daemonArgs(paths)],
    // `dart run` ищет package_config от каталога пакета, поэтому запускаем
    // из `packages/pw_server`, а не из корня репозитория.
    p.dirname(p.dirname(script)),
  );

  static String? _findServerScript() {
    var directory = Directory.current;
    for (var depth = 0; depth < 6; depth++) {
      final file = File(
        p.join(
          directory.path,
          'packages',
          'pw_server',
          'bin',
          'pw_server.dart',
        ),
      );
      if (file.existsSync()) return file.path;
      final parent = directory.parent;
      if (parent.path == directory.path) break;
      directory = parent;
    }
    return null;
  }
}

/// В собранном пакете рядом с GUI лежит готовый бинарник демона.
///
/// Имена и каталоги покрывают Windows/macOS, AppImage (`APPDIR`) и Snap.
final class PackagedDaemonLauncher implements DaemonLauncher {
  const PackagedDaemonLauncher();

  @override
  Future<bool> start(AppPaths paths) async {
    final executable = _findExecutable();
    if (executable == null) return false;
    return _detached(executable, _daemonArgs(paths), p.dirname(executable));
  }

  static String? _findExecutable() {
    final override = Platform.environment['PROBABLY_WORKS_SERVER'];
    if (override != null && File(override).existsSync()) return override;
    final app = File(Platform.resolvedExecutable).parent.path;
    final candidates = [
      p.join(app, 'pw_server'),
      p.join(app, 'pw_server.exe'),
      p.join(app, '..', 'Resources', 'pw_server'),
      if (Platform.environment['APPDIR'] case final dir?)
        p.join(dir, 'usr', 'bin', 'pw_server'),
      if (Platform.environment['SNAP'] case final dir?)
        p.join(dir, 'current', 'bin', 'pw_server'),
    ];
    for (final candidate in candidates) {
      if (File(candidate).existsSync()) return candidate;
    }
    return null;
  }
}

List<String> _daemonArgs(AppPaths paths) => [
  '--data-dir',
  paths.support.path,
  '--port',
  '0',
];

/// Запускает процесс без ожидания и без захвата stdout/stderr.
///
/// GUI не должен зависеть от времени жизни демона: пользователь закрывает окно,
/// демон продолжает работу с БД и планировщиком.
Future<bool> _detached(
  String executable,
  List<String> arguments,
  String workingDirectory,
) async {
  try {
    final process = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      mode: ProcessStartMode.detached,
    );
    // Ссылка на exitCode нужна, чтобы поток завершения не считался ошибкой.
    unawaited(process.exitCode);
    return true;
  } on Object catch (error) {
    AppLog.root.warning('cannot start local daemon', error);
    return false;
  }
}

/// Ищет демон и, если его нет, пробует запустить и дождаться discovery-файла.
///
/// Таймаут покрывает не только старт процесса, но и открытие БД демоном.
final class LocalDaemonStarter {
  LocalDaemonStarter(
    this._discovery, {
    DaemonLauncher? launcher,
    this.timeout = const Duration(seconds: 15),
    Map<String, String>? environment,
  }) : _launcher = launcher ?? createDaemonLauncher(),
       _environment = environment ?? Platform.environment;

  final LocalDaemonDiscovery _discovery;
  final DaemonLauncher _launcher;
  final Map<String, String> _environment;

  /// Сколько ждать `daemon.json` после запуска процесса.
  final Duration timeout;

  /// Возвращает работающий демон или null, если автозапуск выключен/не удался.
  Future<LocalDaemonInfo?> ensureRunning(AppPaths paths) async {
    if (localDaemonDisabled(_environment)) return null;
    final existing = await _discovery.find();
    if (existing != null) return existing;
    if (!await _launcher.start(paths)) return null;
    return waitForStartup();
  }

  /// Ждёт появления и готовности демона, не запуская новый процесс.
  ///
  /// Нужен, когда БД уже занята: демон мог стартовать после таймаута запуска,
  /// и второй экземпляр запускать нельзя.
  Future<LocalDaemonInfo?> waitForStartup({Duration? timeout}) async {
    final deadline = DateTime.now().add(timeout ?? this.timeout);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 120));
      final info = await _discovery.find();
      if (info != null) return info;
    }
    return null;
  }
}
