/// Сводка паритета опций: сколько флагов из справки git принимает апплет.
///
/// Это не тест и не сравнение вывода. Опция засчитана, если апплет не отвечает
/// `unknown option` / `unknown switch`. Поведенческое совпадение с git здесь
/// не проверяется: для него остаются сценарии в `test/`.
///
/// Запуск из каталога пакета:
/// `dart run tool/parity_report.dart`
/// `dart run tool/parity_report.dart add status`
/// `dart run tool/parity_report.dart --policy`
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:virtual_git/virtual_git.dart';
import 'package:virtual_host/virtual_host.dart';

import 'parity_policy.dart' as policy;

/// Один сценарий: имя команды для `git` и хвост до проверяемых опций
/// (например `maintenance` + `[run]` → проверяем флаги `git maintenance run`).
typedef _Scenario = ({String command, List<String> tail, String displayName});

Future<void> main(List<String> rawArgs) async {
  final policyMode = rawArgs.contains('--policy');
  final args = [
    for (final a in rawArgs)
      if (a != '--policy') a,
  ];

  final version = await _gitVersion();
  final explicit = args.isNotEmpty;
  final scenarios = policyMode && !explicit
      ? _readmePolicyScenarios()
      : explicit
      ? [
          for (final name in args)
            (command: name, tail: <String>[], displayName: name),
        ]
      : null;
  final commands = scenarios == null
      ? await _helpCommands()
      : [for (final s in scenarios) s.displayName];

  final host = await _ProbeHost.open();
  final presentAccepted = <int>[];
  final presentTotal = <int>[];
  final presentPolicyExpected = <int>[];
  final absent = <String>[];

  stdout
    ..writeln(
      'Паритет опций относительно $version. '
      'Опция засчитана, если апплет её разбирает.',
    )
    ..writeln(
      'Список опций — `git <команда> --git-completion-helper` и `git <команда> -h`. '
      'Совпадение текста команд эта сводка не измеряет.',
    )
    ..writeln(
      'Опции, которые git не печатает ни там, ни там, в знаменатель не входят. '
      'У `log` так скрыт `--oneline`.',
    );
  if (policyMode) {
    stdout.writeln(
      'Режим --policy: команды из README («Основные команды»); неожиданные '
      'пробелы см. в parity_policy.dart (supportedOptionLabels / expectedOptionGaps).',
    );
  }

  for (var index = 0; index < commands.length; index++) {
    final displayName = commands[index];
    final scenario = scenarios == null
        ? (command: displayName, tail: <String>[], displayName: displayName)
        : scenarios[index];
    final command = scenario.command;
    final tail = scenario.tail;

    final options = await _helpOptions(command, tail);
    if (options == null) {
      stdout.writeln('$displayName  справка git эту команду не описывает');
      continue;
    }
    final known = await host.acceptsCommand(command);
    if (!known) {
      absent.add(displayName);
      if (explicit) {
        _writeCommand(
          displayName,
          options,
          options,
          options,
          commandMissing: true,
          policyMode: policyMode,
          argvTail: tail,
        );
      }
      continue;
    }
    final missing = <_HelpOption>[];
    var policyExpectedCount = 0;
    for (final option in options) {
      final recognized = await host.recognizes(command, tail, option);
      if (recognized) continue;
      missing.add(option);
      final prefix = policy.policyPrefix(command, tail);
      if (policyMode && policy.isExpectedGap(prefix, option.label)) {
        policyExpectedCount++;
      }
    }
    final unexpected = policyMode
        ? missing
              .where(
                (o) => !policy.isExpectedGap(
                  policy.policyPrefix(command, tail),
                  o.label,
                ),
              )
              .toList()
        : missing;
    final expectedOnly = policyMode
        ? missing
              .where(
                (o) => policy.isExpectedGap(
                  policy.policyPrefix(command, tail),
                  o.label,
                ),
              )
              .toList()
        : const <_HelpOption>[];

    presentAccepted.add(options.length - missing.length);
    presentTotal.add(options.length);
    presentPolicyExpected.add(policyExpectedCount);

    _writeCommand(
      displayName,
      options,
      missing,
      unexpected,
      commandMissing: false,
      policyMode: policyMode,
      argvTail: tail,
      expectedOnly: expectedOnly,
    );
  }

  if (!explicit) {
    final accepted = presentAccepted.fold<int>(0, (sum, value) => sum + value);
    final total = presentTotal.fold<int>(0, (sum, value) => sum + value);
    final percent = total == 0 ? 0 : (accepted * 100 / total).round();
    stdout
      ..writeln('')
      ..writeln(
        'Команды пакета: $percent% опций ($accepted из $total) '
        'в ${presentTotal.length} командах.',
      );
    if (policyMode) {
      final expectedSum = presentPolicyExpected.fold<int>(0, (a, b) => a + b);
      final target = total - expectedSum;
      final policyPercent = target <= 0
          ? 100
          : ((accepted * 100 / target).round()).clamp(0, 100);
      stdout.writeln(
        'По политике README: $policyPercent% ($accepted из $target '
        'без учёта ожидаемых пробелов; помечено ожидаемых $expectedSum).',
      );
    }
    stdout.writeln('Нет в пакете: ${absent.length} команд.');
    if (absent.isNotEmpty) stdout.writeln(absent.join(' '));
  }
}

void _writeCommand(
  String displayName,
  List<_HelpOption> options,
  List<_HelpOption> allMissing,
  List<_HelpOption> unexpectedMissing, {
  required bool commandMissing,
  required bool policyMode,
  required List<String> argvTail,
  List<_HelpOption> expectedOnly = const [],
}) {
  if (commandMissing) {
    stdout.writeln(
      '${displayName.padRight(24)} 0%  команды нет в пакете, '
      'в справке ${options.length} опций',
    );
    _writeNames(allMissing);
    return;
  }
  if (options.isEmpty) {
    stdout.writeln('${displayName.padRight(24)} в справке нет опций');
    return;
  }
  final accepted = options.length - allMissing.length;
  final unexpectedCount = unexpectedMissing.length;
  final percentDenominator = policyMode
      ? options.length - expectedOnly.length
      : options.length;
  final percentNumer = policyMode
      ? options.length - allMissing.length
      : accepted;
  final percent = percentDenominator <= 0
      ? 100
      : (percentNumer * 100 / percentDenominator).round();
  final line = StringBuffer()
    ..write('${displayName.padRight(24)} ${'$percent%'.padLeft(4)}  ')
    ..write('$accepted из ${options.length}');
  if (policyMode && expectedOnly.isNotEmpty) {
    line.write(
      ' (неожиданно нет: $unexpectedCount, ожидаемо: ${expectedOnly.length})',
    );
  }
  stdout.writeln(line);
  _writeNames(
    policyMode ? unexpectedMissing : allMissing,
    prefix: policyMode ? 'нет (неожиданно):' : 'нет:',
  );
  if (policyMode && expectedOnly.isNotEmpty) {
    _writeExpectedExpected(displayName, argvTail, expectedOnly);
  }
}

void _writeExpectedExpected(
  String displayName,
  List<String> argvTail,
  List<_HelpOption> expected,
) {
  final command = displayName.split(' ').first;
  final names = expected.map((o) => o.label).toList()..sort();
  for (final name in names) {
    final prefix = policy.policyPrefix(command, argvTail);
    final reason =
        policy.expectedGapReason(prefix, name) ?? '(см. parity_policy)';
    stdout.writeln('  ожидаемо не парсим: $name — $reason');
  }
}

void _writeNames(List<_HelpOption> missing, {String prefix = 'нет:'}) {
  if (missing.isEmpty) return;
  final names = missing.map((option) => option.label).toList()..sort();
  final line = StringBuffer('  $prefix');
  for (final name in names) {
    final piece = ' $name';
    if (line.length + piece.length > 78) {
      stdout.writeln(line);
      line
        ..clear()
        ..write('  $prefix');
    }
    line.write(piece);
  }
  stdout.writeln(line);
}

List<_Scenario> _readmePolicyScenarios() {
  final out = <_Scenario>[];
  for (final name in policy.readmeMainCommands) {
    if (name == 'maintenance') {
      out.addAll([
        (command: 'maintenance', tail: ['run'], displayName: 'maintenance run'),
        (
          command: 'maintenance',
          tail: ['is-needed'],
          displayName: 'maintenance is-needed',
        ),
        (
          command: 'maintenance',
          tail: ['start'],
          displayName: 'maintenance start',
        ),
        (
          command: 'maintenance',
          tail: ['stop'],
          displayName: 'maintenance stop',
        ),
        (
          command: 'maintenance',
          tail: ['register'],
          displayName: 'maintenance register',
        ),
        (
          command: 'maintenance',
          tail: ['unregister'],
          displayName: 'maintenance unregister',
        ),
      ]);
      continue;
    }
    if (name == 'scalar') {
      out.addAll([
        (command: 'scalar', tail: ['clone'], displayName: 'scalar clone'),
        (command: 'scalar', tail: ['register'], displayName: 'scalar register'),
        (command: 'scalar', tail: ['run'], displayName: 'scalar run'),
        (
          command: 'scalar',
          tail: ['reconfigure'],
          displayName: 'scalar reconfigure',
        ),
        (command: 'scalar', tail: ['list'], displayName: 'scalar list'),
        (
          command: 'scalar',
          tail: ['unregister'],
          displayName: 'scalar unregister',
        ),
        (command: 'scalar', tail: ['delete'], displayName: 'scalar delete'),
        (command: 'scalar', tail: ['diagnose'], displayName: 'scalar diagnose'),
        (command: 'scalar', tail: ['help'], displayName: 'scalar help'),
        (command: 'scalar', tail: ['version'], displayName: 'scalar version'),
      ]);
      continue;
    }
    out.add((command: name, tail: const [], displayName: name));
  }
  return out;
}

Future<String> _gitVersion() async {
  final result = await _gitExecutable('git', ['--version']);
  final text = (result.stdout as String).trim();
  if (result.exitCode != 0 || text.isEmpty) {
    stderr.writeln('git --version завершился с кодом ${result.exitCode}');
    exit(1);
  }
  return text;
}

/// Имена из `git help -a` до страниц `attributes` и `format-*`: это уже не команды.
Future<List<String>> _helpCommands() async {
  final result = await _gitExecutable('git', ['help', '-a']);
  final names = <String>[];
  final seen = <String>{};
  var skip = false;
  for (final line in (result.stdout as String).split('\n')) {
    if (line.isNotEmpty && !line.startsWith(' ')) {
      skip =
          line.startsWith('User-facing') || line.startsWith('Developer-facing');
      continue;
    }
    if (skip || !line.startsWith('   ')) continue;
    final parts = line.trim().split(RegExp(' {2,}'));
    for (var index = 0; index < parts.length; index += 2) {
      final name = parts[index].trim();
      if (RegExp('^[a-z0-9][a-z0-9-]*\$').hasMatch(name) && seen.add(name)) {
        names.add(name);
      }
    }
  }
  return names;
}

/// Опции команды или null, если git не отдал ни usage, ни список для completion.
Future<List<_HelpOption>?> _helpOptions(
  String command,
  List<String> tail,
) async {
  final fromHelper = await _completionOptions(command, tail);
  final fromHelp = await _shortHelpOptions(command, tail);
  if (fromHelper == null && fromHelp == null) return null;
  final options = <_HelpOption>[];
  final seen = <String>{};
  for (final option in [...?fromHelper, ...?fromHelp]) {
    if (seen.add(option.label)) options.add(option);
  }
  return options;
}

/// Машинный список флагов. null — команда не понимает этот запрос.
Future<List<_HelpOption>?> _completionOptions(
  String command,
  List<String> tail,
) async {
  final result = command == 'scalar'
      ? await _gitExecutable('scalar', [...tail, '--git-completion-helper'])
      : await _gitExecutable('git', [
          command,
          ...tail,
          '--git-completion-helper',
        ]);
  if (result.exitCode != 0) return null;
  final options = <_HelpOption>[];
  final positives = <String>{};
  for (final token in '${result.stdout}'.split(RegExp(r'\s+'))) {
    if (token == '--') break;
    if (!token.startsWith('--') || token.length < 3) continue;
    final valued = token.endsWith('=');
    final withoutDashes = token.replaceFirst(RegExp(r'^--'), '');
    final name = valued
        ? withoutDashes.replaceFirst(RegExp(r'=$'), '')
        : withoutDashes;
    if (name.isEmpty) continue;
    final positive = name.replaceFirst(RegExp(r'^no-'), '');
    if (positive != name && positives.contains(positive)) continue;
    positives.add(name);
    options.add(
      _HelpOption(
        longName: name,
        shortName: null,
        kind: valued ? _OptionKind.required : _OptionKind.flag,
      ),
    );
  }
  return options;
}

/// Колонка опций из `git <command> [<tail>] -h`. null — в выводе нет строки usage.
Future<List<_HelpOption>?> _shortHelpOptions(
  String command,
  List<String> tail,
) async {
  final result = command == 'scalar'
      ? await _gitExecutable('scalar', [...tail, '-h'])
      : await _gitExecutable('git', [command, ...tail, '-h']);
  final text = '${result.stdout}${result.stderr}';
  if (!text.contains('usage:')) return null;
  final options = <_HelpOption>[];
  for (final line in text.split('\n')) {
    final trimmed = line.trimLeft();
    if (!trimmed.startsWith('-')) continue;
    final spec = trimmed.split(RegExp(' {2,}')).first;
    final option = _HelpOption.parse(spec);
    if (option == null) continue;
    options.add(option);
  }
  return options;
}

Future<ProcessResult> _gitExecutable(String executable, List<String> args) =>
    Process.run(
      executable,
      args,
      environment: const {
        'LC_ALL': 'C',
        'GIT_CONFIG_NOSYSTEM': '1',
        'GIT_CONFIG_GLOBAL': '/dev/null',
        'GIT_CONFIG_COUNT': '0',
      },
    );

/// Флаг из колонки опций `git -h`.
final class _HelpOption {
  const _HelpOption({
    required this.longName,
    required this.shortName,
    required this.kind,
  });

  final String? longName;
  final String? shortName;
  final _OptionKind kind;

  String get label => longName == null ? '-$shortName' : '--$longName';

  List<String> get probeArgs {
    final name = longName;
    if (name == null) {
      final letter = shortName!;
      return kind == _OptionKind.flag ? ['-$letter'] : ['-$letter', 'x'];
    }
    return switch (kind) {
      _OptionKind.flag || _OptionKind.optional => ['--$name'],
      _OptionKind.required => ['--$name=x'],
    };
  }

  static final _spec = RegExp(
    '^(?:-([0-9A-Za-z])(?:,\\s*)?)?'
    '(?:--(?:\\[no-\\])?([0-9A-Za-z][0-9A-Za-z-]*))?(.*)\$',
  );

  static _HelpOption? parse(String spec) {
    final match = _spec.firstMatch(spec);
    if (match == null) return null;
    final shortName = match.group(1);
    final longName = match.group(2);
    if (shortName == null && longName == null) return null;
    final rest = (match.group(3) ?? '').trim();
    final kind = rest.startsWith('[=')
        ? _OptionKind.optional
        : rest.isEmpty
        ? _OptionKind.flag
        : _OptionKind.required;
    return _HelpOption(longName: longName, shortName: shortName, kind: kind);
  }
}

enum _OptionKind { flag, optional, required }

/// Один репозиторий в памяти: по ответу апплета видно, знаком ли ему флаг.
final class _ProbeHost {
  _ProbeHost(this._io, this._out, this._err);

  final AppletIo _io;
  final _Buffer _out;
  final _Buffer _err;

  static Future<_ProbeHost> open() async {
    final fs = VirtualFs(InMemoryVfsStore());
    await fs.mkdir('/work', recursive: true);
    final out = _Buffer();
    final err = _Buffer();
    final io = AppletIo(
      readStdin: () => Uint8List(0),
      stdout: out,
      stderr: err,
      cwd: '/work',
      env: const {},
      fs: fs,
      profile: const VirtualProfile(home: '/work'),
      applets: AppletRegistry(const [GitApplet()]),
      exec: (_, _) async => 127,
    );
    final host = _ProbeHost(io, out, err);
    final init = await host._run(const ['init', '-b', 'main']);
    if (init.err.isNotEmpty) {
      stderr.writeln(init.err);
      exit(1);
    }
    return host;
  }

  Future<bool> acceptsCommand(String command) async {
    final probe = command == 'scalar'
        ? [command, 'version', '--parity-missing']
        : [command, '--parity-missing'];
    final result = await _run(probe);
    return !result.err.contains('is not a git command');
  }

  Future<bool> recognizes(
    String command,
    List<String> tail,
    _HelpOption option,
  ) async {
    final result = await _run([command, ...tail, ...option.probeArgs]);
    final token = option.longName ?? option.shortName!;
    final kind = option.longName == null ? 'switch' : 'option';
    return !result.err.contains("error: unknown $kind `$token'");
  }

  Future<({String err})> _run(List<String> args) async {
    _out.clear();
    _err.clear();
    await const GitApplet().run(_io, args);
    return (err: _err.text);
  }
}

final class _Buffer implements ShellSink {
  final _bytes = BytesBuilder(copy: false);

  String get text => utf8.decode(_bytes.toBytes());

  void clear() => _bytes.clear();

  @override
  void write(Uint8List bytes) => _bytes.add(bytes);
}
