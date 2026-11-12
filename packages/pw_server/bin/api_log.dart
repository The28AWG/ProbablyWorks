import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Анализ JSONL-журнала HTTP API.
///
/// Запуск:
///   dart run packages/pw_server/bin/api_log.dart summary --file=/path/api-access.log
///   dart run packages/pw_server/bin/api_log.dart problems --slow-ms=1000
///   dart run packages/pw_server/bin/api_log.dart filter --status=401
void main(List<String> args) {
  final options = _Options.parse(args);
  if (options.help) {
    stdout.writeln(_usage);
    return;
  }
  final file =
      options.file ??
      Platform.environment['PROBABLY_WORKS_API_LOG'] ??
      p.join('logs', 'api-access.log');
  if (!File(file).existsSync()) {
    stderr
      ..writeln('Файл не найден: $file')
      ..writeln('Укажите путь через --file или PROBABLY_WORKS_API_LOG.');
    exitCode = 2;
    return;
  }

  final parsed = _read(file);
  switch (options.command) {
    case 'summary':
      _summary(parsed, options);
    case 'problems':
      _problems(parsed, options);
    case 'filter':
      _filter(parsed, options);
    default:
      stderr
        ..writeln('Неизвестная команда: ${options.command}\n')
        ..writeln(_usage);
      exitCode = 2;
  }
}

void _summary(_Parsed parsed, _Options options) {
  final entries = parsed.entries;
  stdout
    ..writeln('Файл: ${options.file}')
    ..writeln('Записей: ${entries.length}');
  if (entries.isEmpty) return;

  final times = [for (final entry in entries) ?_time(entry)]..sort();
  if (times.isNotEmpty) {
    stdout.writeln(
      'Период: ${times.first.toIso8601String()} — ${times.last.toIso8601String()}',
    );
  }

  _counts('События', entries, (entry) => '${entry['event'] ?? '?'}');
  _counts('Статусы', entries, (entry) {
    final status = _int(entry['status']);
    if (status == null) return '?';
    return status >= 500
        ? '5xx'
        : status >= 400
        ? '4xx'
        : status >= 300
        ? '3xx'
        : '2xx';
  });
  _counts('Авторизация', entries, (entry) => '${entry['auth'] ?? '?'}');
  _counts('Клиенты', entries, _clientLabel);

  final paths = <String, int>{};
  for (final entry in entries) {
    final path = '${entry['path'] ?? '?'}';
    paths[path] = (paths[path] ?? 0) + 1;
  }
  _printTop('Частые пути', paths, options.top);

  final slow = [...entries]
    ..sort(
      (a, b) =>
          (_int(b['durationMs']) ?? 0).compareTo(_int(a['durationMs']) ?? 0),
    );
  stdout.writeln('\nСамые медленные запросы:');
  for (final entry in slow.take(options.top)) {
    _printEntry(entry);
  }

  if (parsed.malformed > 0) {
    stdout.writeln('\nПропущено некорректных строк: ${parsed.malformed}');
  }
}

void _problems(_Parsed parsed, _Options options) {
  final entries = parsed.entries
      .where((entry) => _isProblem(entry, options))
      .toList();
  stdout
    ..writeln('Файл: ${options.file}')
    ..writeln('Проблемных записей: ${entries.length}');
  if (entries.isEmpty) return;

  _counts('Коды ошибок', entries, (entry) => '${entry['error'] ?? '—'}');
  _counts('Статусы', entries, (entry) => '${entry['status'] ?? '?'}');
  _counts('Авторизация', entries, (entry) => '${entry['auth'] ?? '?'}');
  _counts('Клиенты', entries, _clientLabel);

  stdout.writeln('\nЗаписи:');
  for (final entry in entries.take(options.limit)) {
    _printEntry(entry);
  }
  if (entries.length > options.limit) {
    stdout.writeln('… ещё ${entries.length - options.limit} (--limit)');
  }
}

void _filter(_Parsed parsed, _Options options) {
  final entries = parsed.entries
      .where((entry) => _matches(entry, options))
      .toList();
  for (final entry in entries.take(options.limit)) {
    if (options.json) {
      stdout.writeln(jsonEncode(entry));
    } else {
      _printEntry(entry);
    }
  }
  if (entries.length > options.limit) {
    stderr.writeln('… ещё ${entries.length - options.limit} (--limit)');
  }
}

bool _isProblem(Map<String, dynamic> entry, _Options options) {
  final status = _int(entry['status']) ?? 0;
  final duration = _int(entry['durationMs']) ?? 0;
  return status >= 400 ||
      entry['auth'] != 'ok' ||
      entry['error'] != null ||
      duration >= options.slowMs ||
      entry['event'] == 'api.sse.close' && duration >= options.slowMs;
}

bool _matches(Map<String, dynamic> entry, _Options options) {
  if (options.event case final event?) {
    if (entry['event'] != event) return false;
  }
  if (options.method case final method?) {
    if (entry['method'] != method.toUpperCase()) return false;
  }
  if (options.status case final status?) {
    if (!_statusMatches(_int(entry['status']), status)) return false;
  }
  if (options.auth case final auth?) {
    if (entry['auth'] != auth) return false;
  }
  if (options.path case final path?) {
    if (!'${entry['path'] ?? ''}'.contains(path)) return false;
  }
  if (options.minDuration case final min?) {
    if ((_int(entry['durationMs']) ?? 0) < min) return false;
  }
  final time = _time(entry);
  if (options.since case final since?) {
    if (time == null || time.isBefore(since)) return false;
  }
  if (options.until case final until?) {
    if (time == null || time.isAfter(until)) return false;
  }
  return true;
}

bool _statusMatches(int? status, String pattern) {
  if (status == null) return false;
  if (pattern.endsWith('xx') && pattern.length == 3) {
    final first = int.tryParse(pattern[0]);
    return first != null && status ~/ 100 == first;
  }
  return status == int.tryParse(pattern);
}

void _counts(
  String title,
  Iterable<Map<String, dynamic>> entries,
  String Function(Map<String, dynamic>) key,
) {
  final counts = <String, int>{};
  for (final entry in entries) {
    final value = key(entry);
    counts[value] = (counts[value] ?? 0) + 1;
  }
  final sorted = counts.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  stdout.writeln('\n$title:');
  for (final entry in sorted) {
    stdout.writeln('  ${entry.key}: ${entry.value}');
  }
}

void _printTop(String title, Map<String, int> counts, int top) {
  final sorted = counts.entries.toList()
    ..sort((a, b) => b.value.compareTo(a.value));
  stdout.writeln('\n$title:');
  for (final entry in sorted.take(top)) {
    stdout.writeln('  ${entry.value.toString().padLeft(4)}  ${entry.key}');
  }
}

void _printEntry(Map<String, dynamic> entry) {
  final status = _int(entry['status']) ?? 0;
  final duration = _int(entry['durationMs']) ?? 0;
  final error = entry['error'] == null ? '' : ' error=${entry['error']}';
  stdout.writeln(
    '${entry['ts'] ?? '?'} ${status.toString().padLeft(3)} '
    '${entry['method'] ?? '?'} ${entry['path'] ?? '?'} '
    '${duration}ms auth=${entry['auth'] ?? '?'}'
    '${error.isEmpty ? '' : error} client=${_clientLabel(entry)} '
    'id=${entry['requestId'] ?? '?'}',
  );
}

_Parsed _read(String path) {
  final entries = <Map<String, dynamic>>[];
  var malformed = 0;
  for (final line in File(path).readAsLinesSync()) {
    if (line.trim().isEmpty) continue;
    try {
      final decoded = jsonDecode(line);
      if (decoded is Map<String, dynamic>) {
        entries.add(decoded);
      } else {
        malformed++;
      }
    } on FormatException {
      malformed++;
    }
  }
  return _Parsed(entries, malformed);
}

String _clientLabel(Map<String, dynamic> entry) {
  final app = entry['clientApp'] ?? entry['clientPackage'] ?? '?';
  final version = entry['clientVersion'] ?? '?';
  final build = entry['clientBuild'];
  final platform = entry['clientPlatform'];
  return [
    '$app/$version',
    if (build != null) '+$build',
    if (platform != null) ' ($platform)',
  ].join();
}

DateTime? _time(Map<String, dynamic> entry) =>
    DateTime.tryParse('${entry['ts'] ?? ''}')?.toUtc();

int? _int(Object? value) => value is num ? value.toInt() : null;

final class _Parsed {
  const _Parsed(this.entries, this.malformed);

  final List<Map<String, dynamic>> entries;
  final int malformed;
}

final class _Options {
  _Options({
    required this.command,
    this.file,
    this.event,
    this.method,
    this.status,
    this.auth,
    this.path,
    this.minDuration,
    this.since,
    this.until,
    this.limit = 50,
    this.top = 5,
    this.slowMs = 1000,
    this.json = false,
    this.help = false,
  });

  factory _Options.parse(List<String> args) {
    final values = <String, String>{};
    var json = false;
    var help = false;
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      if (arg == '--json') {
        json = true;
        continue;
      }
      if (arg == '--help' || arg == '-h') {
        help = true;
        continue;
      }
      if (arg.startsWith('-')) {
        final parts = arg.split('=');
        if (parts.length > 1) {
          values[parts.first] = parts.skip(1).join('=');
        } else if (i + 1 < args.length) {
          values[arg] = args[++i];
        } else {
          values[arg] = '';
        }
      }
    }
    final command = args.isEmpty || args.first.startsWith('-')
        ? 'summary'
        : args.first;
    return _Options(
      command: command,
      file: values['--file'] ?? values['-f'],
      event: values['--event'],
      method: values['--method'],
      status: values['--status'],
      auth: values['--auth'],
      path: values['--path'],
      minDuration: int.tryParse(values['--min-duration'] ?? ''),
      since: DateTime.tryParse(values['--since'] ?? '')?.toUtc(),
      until: DateTime.tryParse(values['--until'] ?? '')?.toUtc(),
      limit: int.tryParse(values['--limit'] ?? '') ?? 50,
      top: int.tryParse(values['--top'] ?? '') ?? 5,
      slowMs: int.tryParse(values['--slow-ms'] ?? '') ?? 1000,
      json: json,
      help: help,
    );
  }

  final String command;
  final String? file;
  final String? event;
  final String? method;
  final String? status;
  final String? auth;
  final String? path;
  final int? minDuration;
  final DateTime? since;
  final DateTime? until;
  final int limit;
  final int top;
  final int slowMs;
  final bool json;
  final bool help;
}

const _usage = '''
Анализ журнала доступа ProbablyWorks API.

Использование:
  dart run packages/pw_server/bin/api_log.dart <команда> --file=<path> [опции]

Команды:
  summary    сводка: события, статусы, авторизация, частые пути, медленные запросы
  problems   ошибки, неавторизованные запросы и запросы медленнее --slow-ms
  filter     фильтрация записей

Общие опции:
  --file, -f <path>       путь к api-access.log (или PROBABLY_WORKS_API_LOG)
  --limit <n>              максимум строк (по умолчанию 50)
  --since <ISO>            начало периода
  --until <ISO>            конец периода
  --json                   вывести исходный JSONL в filter

filter:
  --event <name>           api.request, api.sse.open, api.sse.close
  --method <METHOD>        HTTP-метод
  --status <code|4xx>      точный статус или класс
  --auth <ok|missing|invalid>
  --path <substring>       подстрока пути
  --min-duration <ms>      минимальная длительность

problems:
  --slow-ms <ms>           порог медленного запроса (по умолчанию 1000)

summary:
  --top <n>                сколько путей и медленных запросов показать (по умолчанию 5)
''';
