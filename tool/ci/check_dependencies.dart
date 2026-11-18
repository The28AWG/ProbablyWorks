import 'dart:convert';
import 'dart:io';

/// Сверяет Android-тулчейн с шаблоном установленного Flutter и показывает
/// прямые зависимости, у которых есть более новые версии.
///
/// Запуск из корня репозитория:
/// `dart run tool/ci/check_dependencies.dart`.
/// С `--strict` возвращает код 1, если версии Android разошлись с шаблоном
/// Flutter или есть обновления прямых зависимостей. Без флага это отчёт для
/// планового обновления, а не блокирующая проверка каждого коммита.
Future<void> main(List<String> args) async {
  final strict = args.contains('--strict');
  final unknown = args.where((arg) => arg != '--strict').toList();
  if (unknown.isNotEmpty) {
    stderr
      ..writeln('Неизвестные аргументы: ${unknown.join(' ')}')
      ..writeln(
        'Использование: dart run tool/ci/check_dependencies.dart [--strict]',
      );
    exit(2);
  }

  final flutter = await _flutterInfo();
  final template = _templateVersions(flutter.root);
  final project = _projectVersions();
  final mismatches = _printAndroidVersions(flutter, template, project);
  final outdated = await _printOutdated();

  if (strict && (mismatches > 0 || outdated.isNotEmpty)) {
    exit(1);
  }
}

/// Версия и каталог Flutter, с шаблоном которого сверяется Android-сборка.
typedef _FlutterInfo = ({String version, String root});

Future<_FlutterInfo> _flutterInfo() async {
  final root = Platform.environment['FLUTTER_ROOT'];
  final result = await Process.run('flutter', ['--version', '--machine']);
  if (result.exitCode != 0) {
    stderr
      ..writeln('Не удалось определить версию Flutter:')
      ..write(result.stderr);
    exit(2);
  }
  final info = jsonDecode(result.stdout as String) as Map<String, Object?>;
  final detectedRoot = root ?? info['flutterRoot'] as String?;
  final version = info['frameworkVersion'] as String?;
  if (detectedRoot == null || version == null) {
    stderr.writeln(
      'В выводе flutter --version --machine нет flutterRoot или frameworkVersion.',
    );
    exit(2);
  }
  return (version: version, root: detectedRoot);
}

/// Версии Gradle, AGP и Kotlin, которые Flutter считает проверенными для своего
/// шаблона Android-приложения.
typedef _TemplateVersions = ({String gradle, String agp, String kotlin});

_TemplateVersions _templateVersions(String flutterRoot) {
  final file = File(
    '$flutterRoot/packages/flutter_tools/lib/src/android/gradle_utils.dart',
  );
  if (!file.existsSync()) {
    stderr.writeln('Не найден ${file.path}: проверьте установку Flutter.');
    exit(2);
  }
  final source = file.readAsStringSync();
  return (
    gradle: _matchVersion(
      source,
      RegExp(r"templateDefaultGradleVersion = '([^']+)'"),
      'templateDefaultGradleVersion',
      file.path,
    ),
    agp: _matchVersion(
      source,
      RegExp(r"templateAndroidGradlePluginVersion = '([^']+)'"),
      'templateAndroidGradlePluginVersion',
      file.path,
    ),
    kotlin: _matchVersion(
      source,
      RegExp(r"templateKotlinGradlePluginVersion = '([^']+)'"),
      'templateKotlinGradlePluginVersion',
      file.path,
    ),
  );
}

/// Версии, реально заданные в проекте.
typedef _ProjectVersions = ({String gradle, String agp, String kotlin});

_ProjectVersions _projectVersions() {
  final wrapper = File('android/gradle/wrapper/gradle-wrapper.properties');
  final settings = File('android/settings.gradle.kts');
  if (!wrapper.existsSync() || !settings.existsSync()) {
    stderr.writeln('Запустите проверку из корня репозитория.');
    exit(2);
  }
  final settingsSource = settings.readAsStringSync();
  return (
    gradle: _matchVersion(
      wrapper.readAsStringSync(),
      RegExp(r'gradle-([0-9.]+)-all\.zip'),
      'Gradle wrapper',
      wrapper.path,
    ),
    agp: _matchVersion(
      settingsSource,
      RegExp(r'id\("com\.android\.application"\) version "([^"]+)"'),
      'AGP',
      settings.path,
    ),
    kotlin: _matchVersion(
      settingsSource,
      RegExp(r'id\("org\.jetbrains\.kotlin\.android"\) version "([^"]+)"'),
      'Kotlin',
      settings.path,
    ),
  );
}

/// Печатает сверку Android-версий и возвращает число расхождений.
int _printAndroidVersions(
  _FlutterInfo flutter,
  _TemplateVersions template,
  _ProjectVersions project,
) {
  var mismatches = 0;
  stdout
    ..writeln('Flutter ${flutter.version}: ${flutter.root}')
    ..writeln('Android-тулчейн (проект / шаблон Flutter):');
  mismatches += _printVersion('Gradle', project.gradle, template.gradle);
  mismatches += _printVersion('AGP', project.agp, template.agp);
  mismatches += _printVersion('Kotlin', project.kotlin, template.kotlin);
  return mismatches;
}

int _printVersion(String name, String actual, String expected) {
  final comparison = _compareVersions(actual, expected);
  final marker = switch (comparison) {
    < 0 => '[!!] старее шаблона',
    > 0 => '[new] новее шаблона',
    _ => '[ok]',
  };
  stdout.writeln('  $marker $name: $actual / $expected');
  return comparison < 0 ? 1 : 0;
}

/// Сравнивает числовые версии вида 9.5.1, не учитывая суффиксы prerelease.
int _compareVersions(String left, String right) {
  final a = _versionParts(left);
  final b = _versionParts(right);
  for (var i = 0; i < a.length || i < b.length; i++) {
    final x = i < a.length ? a[i] : 0;
    final y = i < b.length ? b[i] : 0;
    if (x != y) return x.compareTo(y);
  }
  return 0;
}

List<int> _versionParts(String version) => version
    .split('.')
    .map((part) => int.tryParse(RegExp(r'^\d+').stringMatch(part) ?? '') ?? 0)
    .toList();

/// Печатает прямые и dev-зависимости с более новой версией и принудительные
/// `dependency_overrides`. Возвращает их имена, чтобы `--strict` мог
/// завершиться с ошибкой.
Future<List<String>> _printOutdated() async {
  final result = await Process.run('flutter', ['pub', 'outdated', '--json']);
  final output = result.stdout as String;
  if (!output.trimLeft().startsWith('{')) {
    stderr
      ..writeln('Не удалось прочитать flutter pub outdated --json:')
      ..write(result.stderr);
    return const [];
  }

  final report = jsonDecode(output) as Map<String, Object?>;
  final direct = (report['packages'] as List<Object?>? ?? const [])
      .cast<Map<String, Object?>>()
      .where((package) {
        final kind = package['kind'] as String?;
        return kind == 'direct' || kind == 'dev';
      })
      .toList();
  final overridden = direct.where(_isOverridden).toList();
  final outdated = direct.where((package) {
    final current = package['current'] as Map<String, Object?>?;
    final latest = package['latest'] as Map<String, Object?>?;
    return current?['version'] != latest?['version'];
  }).toList();

  if (overridden.isEmpty && outdated.isEmpty) {
    stdout.writeln('Прямые зависимости актуальны.');
    return const [];
  }

  final names = <String>{};
  if (overridden.isNotEmpty) {
    stdout.writeln('Прямые зависимости с dependency_overrides:');
    for (final package in overridden) {
      final name = package['package'] as String;
      names.add(name);
      final current = package['current'] as Map<String, Object?>;
      stdout.writeln('  $name: ${current['version']} (override)');
    }
  }
  if (outdated.isNotEmpty) {
    stdout.writeln('Прямые зависимости с более новыми версиями:');
    for (final package in outdated) {
      final name = package['package'] as String;
      names.add(name);
      final current = package['current'] as Map<String, Object?>;
      final latest = package['latest'] as Map<String, Object?>;
      final resolvable = package['resolvable'] as Map<String, Object?>?;
      final advisory = package['isCurrentAffectedByAdvisory'] == true;
      final forced = _isOverridden(package) ? ' [override]' : '';
      final suffix = resolvable?['version'] == latest['version']
          ? ''
          : ' (разрешается ${resolvable?['version'] ?? '?'})';
      final security = advisory ? ' [SECURITY]' : '';
      stdout.writeln(
        '  $name: ${current['version']} -> ${latest['version']}'
        '$suffix$forced$security',
      );
    }
  }
  return names.toList();
}

bool _isOverridden(Map<String, Object?> package) {
  final current = package['current'] as Map<String, Object?>?;
  return current?['overridden'] == true;
}

/// Достаёт первую группу регулярного выражения или завершает проверку с кодом 2.
String _matchVersion(String source, RegExp pattern, String label, String path) {
  final match = pattern.firstMatch(source);
  final version = match?.group(1);
  if (version == null) {
    stderr.writeln('Не найдена версия $label в $path.');
    exit(2);
  }
  return version;
}
