import 'dart:math' show max;

import 'package:virtual_host/src/shell/applets/applet.dart';
import 'package:virtual_host/src/shell/applets/applet_args.dart';
import 'package:virtual_host/src/shell/shell_io.dart';
import 'package:virtual_host/src/vfs_path.dart';
import 'package:virtual_host/src/vfs_store.dart';

/// Состояние и расход: `du`, `df`, `uptime`. Всё считается по VFS и профилю, без обращения к системе.
final List<Applet> systemApplets = [const _Du(), const _Df(), const _Uptime()];

/// Размер блока учёта, как у файловых систем: каждый файл и каталог занимает целое число блоков.
const _blockBytes = 4096;

/// Блоки в килобайтах (единица `du` и `df`).
int _kibibytes(int bytes) => (bytes + _blockBytes - 1) ~/ _blockBytes * 4;

/// Размер в читаемом виде, как `du -h`: до десяти — с одним знаком после запятой, дальше целым.
String _human(int kib) {
  const units = ['K', 'M', 'G', 'T'];
  var value = kib.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final number = value < 10
      ? value.toStringAsFixed(1)
      : value.ceil().toString();
  return '$number${units[unit]}';
}

/// `du [-sah] [PATH...]`: объём в килобайтах по блокам 4 КиБ. Каталог выводится после содержимого,
/// как у GNU. По умолчанию — каталоги и аргументы; `-a` добавляет файлы, `-s` — только итоги аргументов.
final class _Du implements Applet {
  const _Du();

  @override
  String get name => 'du';

  @override
  Future<int> run(AppletIo io, List<String> args) async {
    final parsed = parseArgs(args, flags: 'sah');
    if (parsed.error != null) return usageError(io, name, parsed.error!);
    final options = _DuOptions(
      summary: parsed.has('s'),
      all: parsed.has('a'),
      human: parsed.has('h'),
    );
    var status = 0;
    for (final operand
        in parsed.operands.isEmpty ? const ['.'] : parsed.operands) {
      final node = await io.fs.stat(operand, cwd: io.cwd);
      if (node == null) {
        io.stderr.writeText(
          "du: cannot access '$operand': No such file or directory\n",
        );
        status = 1;
        continue;
      }
      await _usage(io, node, trimSlashes(operand), options, topLevel: true);
    }
    return status;
  }

  /// Возвращает объём узла в КиБ и печатает строку, если она нужна по опциям. Для каталога объём — его
  /// блок плюс объём всех потомков; потомки печатаются раньше каталога.
  Future<int> _usage(
    AppletIo io,
    VfsNode node,
    String label,
    _DuOptions options, {
    required bool topLevel,
  }) async {
    if (node.kind != VfsNodeKind.dir) {
      final kib = node.kind == VfsNodeKind.symlink ? 0 : _kibibytes(node.size);
      final show = topLevel || (!options.summary && options.all);
      if (show) io.stdout.writeText('${_format(kib, options)}\t$label\n');
      return kib;
    }
    // Сам каталог занимает один блок; порядок потомков по имени, чтобы вывод не зависел от хранилища.
    var total = _blockBytes ~/ 1024;
    final children = [...await io.fs.list(node.path)]
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final child in children) {
      total += await _usage(
        io,
        child,
        '$label/${VfsPath.name(child.path)}',
        options,
        topLevel: false,
      );
    }
    if (!options.summary || topLevel) {
      io.stdout.writeText('${_format(total, options)}\t$label\n');
    }
    return total;
  }

  String _format(int kib, _DuOptions options) =>
      options.human ? _human(kib) : '$kib';
}

/// Опции `du`, собранные из флагов один раз.
final class _DuOptions {
  const _DuOptions({
    required this.summary,
    required this.all,
    required this.human,
  });

  final bool summary;
  final bool all;
  final bool human;
}

/// `df [-h]`: один раздел виртуальной ФС. Размер — квота Host, занято — текущий объём данных.
/// Имя раздела — имя хоста, точка монтирования — `/`. Пути-аргументы проверяются на существование.
final class _Df implements Applet {
  const _Df();

  @override
  String get name => 'df';

  @override
  Future<int> run(AppletIo io, List<String> args) async {
    final parsed = parseArgs(args, flags: 'h');
    if (parsed.error != null) return usageError(io, name, parsed.error!);
    var status = 0;
    // Раздел один, поэтому строка таблицы одна. Как у GNU: если все операнды несуществующие,
    // печатаются только ошибки, без таблицы.
    var found = parsed.operands.isEmpty;
    for (final operand in parsed.operands) {
      if (await io.fs.stat(operand, cwd: io.cwd) == null) {
        io.stderr.writeText('df: $operand: No such file or directory\n');
        status = 1;
      } else {
        found = true;
      }
    }
    if (!found) return status;
    final human = parsed.has('h');
    final total = _kibibytes(io.fs.limits.quotaBytes);
    final used = _kibibytes(await io.fs.usedBytes());
    final available = max(0, total - used);
    final percent = total == 0 ? 0 : (used * 100 + total - 1) ~/ total;
    String cell(int kib) => (human ? _human(kib) : '$kib').padLeft(9);
    io.stdout.writeText(
      '${'Filesystem'.padRight(14)} '
      '${(human ? 'Size' : '1K-blocks').padLeft(9)} '
      '${'Used'.padLeft(9)} ${'Available'.padLeft(9)} ${'Use%'.padLeft(4)} '
      'Mounted on\n'
      '${io.profile.hostname.padRight(14)} ${cell(total)} ${cell(used)} '
      '${cell(available)} ${'$percent%'.padLeft(4)} /\n',
    );
    return status;
  }
}

/// `uptime`: текущее время, время с запуска Host (от его создания), одна сессия и средняя нагрузка 0.
/// Нагрузки у виртуального Host нет, поэтому нули — честное значение, а не имитация.
final class _Uptime implements Applet {
  const _Uptime();

  @override
  String get name => 'uptime';

  @override
  Future<int> run(AppletIo io, List<String> args) async {
    final parsed = parseArgs(args);
    if (parsed.error != null) return usageError(io, name, parsed.error!);
    final now = io.fs.now();
    final boot = io.profile.bootedAt;
    final elapsedMinutes = boot == 0 ? 0 : max(0, now - boot) ~/ 60;
    final days = elapsedMinutes ~/ 1440;
    final hours = (elapsedMinutes % 1440) ~/ 60;
    final minutes = elapsedMinutes % 60;
    String two(int n) => n.toString().padLeft(2, '0');
    final clock = DateTime.fromMillisecondsSinceEpoch(now * 1000, isUtc: true);
    final up = days > 0
        ? '$days ${days == 1 ? 'day' : 'days'},  $hours:${two(minutes)}'
        : hours > 0
        ? '$hours:${two(minutes)}'
        : '$minutes min';
    io.stdout.writeText(
      ' ${two(clock.hour)}:${two(clock.minute)}:${two(clock.second)} '
      'up $up,  1 user,  load average: 0.00, 0.00, 0.00\n',
    );
    return 0;
  }
}
