import 'dart:convert';
import 'dart:typed_data';

import 'package:virtual_host/src/shell/applets/applet.dart';
import 'package:virtual_host/src/shell/applets/applet_args.dart';
import 'package:virtual_host/src/shell/shell_io.dart';

/// Апплеты сведений о среде: профиль Host, окружение, даты и служебные команды.
///
/// Всё берётся из [AppletIo.profile] и [AppletIo.env], поэтому вывод совпадает с тем, что модель видит
/// в `host_info`.
final List<Applet> infoApplets = [
  const _True(),
  const _False(),
  const _Pwd(),
  const _Uname(),
  const _Whoami(),
  const _Id(),
  const _Hostname(),
  const _Date(),
  const _Env(),
  const _Printenv(),
  const _Which(),
  const _Xargs(),
];

/// `true`: код 0, ничего не печатает.
final class _True implements Applet {
  const _True();

  @override
  String get name => 'true';

  @override
  Future<int> run(AppletIo io, List<String> args) async => 0;
}

/// `false`: код 1, ничего не печатает.
final class _False implements Applet {
  const _False();

  @override
  String get name => 'false';

  @override
  Future<int> run(AppletIo io, List<String> args) async => 1;
}

/// `pwd`: текущий каталог (логический, как после `cd`). Опции `-L` и `-P` принимаются и ничего не меняют:
/// у виртуальной ФС симлинки разворачиваются при `cd`, поэтому пути совпадают.
final class _Pwd implements Applet {
  const _Pwd();

  @override
  String get name => 'pwd';

  @override
  Future<int> run(AppletIo io, List<String> args) async {
    final parsed = parseArgs(args, flags: 'LP');
    if (parsed.error != null) return usageError(io, name, parsed.error!);
    io.stdout.writeText('${io.cwd}\n');
    return 0;
  }
}

/// `uname`: `-s` (по умолчанию), `-n`, `-r`, `-m`, `-a`. Порядок полей фиксирован, как у GNU.
final class _Uname implements Applet {
  const _Uname();

  @override
  String get name => 'uname';

  @override
  Future<int> run(AppletIo io, List<String> args) async {
    final parsed = parseArgs(args, flags: 'asnrmvo');
    if (parsed.error != null) return usageError(io, name, parsed.error!);
    final profile = io.profile;
    if (parsed.has('a')) {
      io.stdout.writeText('${profile.unameLine}\n');
      return 0;
    }
    final fields = [
      if (parsed.has('s') || parsed.flags.isEmpty) 'Linux',
      if (parsed.has('n')) profile.hostname,
      if (parsed.has('r')) '6.1.0-virtual',
      if (parsed.has('v')) '#1 SMP',
      if (parsed.has('m')) 'x86_64',
      if (parsed.has('o')) 'GNU/Linux',
    ];
    io.stdout.writeText('${fields.join(' ')}\n');
    return 0;
  }
}

/// `whoami`: имя пользователя профиля.
final class _Whoami implements Applet {
  const _Whoami();

  @override
  String get name => 'whoami';

  @override
  Future<int> run(AppletIo io, List<String> args) async {
    io.stdout.writeText('${io.profile.user}\n');
    return 0;
  }
}

/// `id`: без опций — `uid=… gid=… groups=…`. `-u`, `-g` печатают номер, `-un`, `-gn` — имя.
final class _Id implements Applet {
  const _Id();

  @override
  String get name => 'id';

  @override
  Future<int> run(AppletIo io, List<String> args) async {
    final parsed = parseArgs(args, flags: 'ugn');
    if (parsed.error != null) return usageError(io, name, parsed.error!);
    final user = io.profile.user;
    if (parsed.has('u')) {
      io.stdout.writeText(parsed.has('n') ? '$user\n' : '$hostUid\n');
      return 0;
    }
    if (parsed.has('g')) {
      io.stdout.writeText(parsed.has('n') ? '$user\n' : '$hostGid\n');
      return 0;
    }
    io.stdout.writeText(
      'uid=$hostUid($user) gid=$hostGid($user) groups=$hostGid($user)\n',
    );
    return 0;
  }
}

/// `hostname`: имя из профиля.
final class _Hostname implements Applet {
  const _Hostname();

  @override
  String get name => 'hostname';

  @override
  Future<int> run(AppletIo io, List<String> args) async {
    io.stdout.writeText('${io.profile.hostname}\n');
    return 0;
  }
}

/// `date`: текущее время Host в UTC. `+FORMAT` поддерживает основные спецификаторы strftime; `-u`
/// принимается, потому что Host всегда в UTC.
final class _Date implements Applet {
  const _Date();

  @override
  String get name => 'date';

  @override
  Future<int> run(AppletIo io, List<String> args) async {
    final parsed = parseArgs(args, flags: 'u');
    if (parsed.error != null) return usageError(io, name, parsed.error!);
    final now = DateTime.fromMillisecondsSinceEpoch(
      io.fs.now() * 1000,
      isUtc: true,
    );
    final operand = parsed.operands.firstOrNull;
    if (operand == null) {
      io.stdout.writeText('${formatDate(now, '%a %b %e %H:%M:%S UTC %Y')}\n');
      return 0;
    }
    if (!operand.startsWith('+')) {
      return usageError(io, name, 'invalid date format: $operand');
    }
    io.stdout.writeText('${formatDate(now, operand.replaceFirst('+', ''))}\n');
    return 0;
  }
}

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _weekdaysFull = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];
const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];
const _monthsFull = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

/// Форматирует [t] (в UTC) по строке формата strftime. Неизвестный спецификатор выводится как есть,
/// чтобы ошибка была видна в выводе, а не терялась.
String formatDate(DateTime t, String format) {
  String two(int v) => v.toString().padLeft(2, '0');
  final out = StringBuffer();
  for (var i = 0; i < format.length; i++) {
    final ch = format[i];
    if (ch != '%' || i + 1 >= format.length) {
      out.write(ch);
      continue;
    }
    final spec = format[++i];
    switch (spec) {
      case 'Y':
        out.write(t.year);
      case 'y':
        out.write(two(t.year % 100));
      case 'm':
        out.write(two(t.month));
      case 'd':
        out.write(two(t.day));
      case 'e':
        out.write(t.day.toString().padLeft(2));
      case 'H':
        out.write(two(t.hour));
      case 'M':
        out.write(two(t.minute));
      case 'S':
        out.write(two(t.second));
      case 'F':
        out.write('${t.year}-${two(t.month)}-${two(t.day)}');
      case 'T':
        out.write('${two(t.hour)}:${two(t.minute)}:${two(t.second)}');
      case 'a':
        out.write(_weekdays[t.weekday - 1]);
      case 'A':
        out.write(_weekdaysFull[t.weekday - 1]);
      case 'b' || 'h':
        out.write(_months[t.month - 1]);
      case 'B':
        out.write(_monthsFull[t.month - 1]);
      case 's':
        out.write(t.millisecondsSinceEpoch ~/ 1000);
      case 'j':
        out.write(
          (t.difference(DateTime.utc(t.year)).inDays + 1).toString().padLeft(
            3,
            '0',
          ),
        );
      case 'Z':
        out.write('UTC');
      case 'z':
        out.write('+0000');
      case 'p':
        out.write(t.hour < 12 ? 'AM' : 'PM');
      case 'n':
        out.write('\n');
      case 't':
        out.write('\t');
      case '%':
        out.write('%');
      default:
        out.write('%$spec');
    }
  }
  return out.toString();
}

/// `env`: без операндов печатает экспортируемые переменные. С операндами `NAME=VALUE` и командой
/// запускает её с изменённым окружением.
final class _Env implements Applet {
  const _Env();

  @override
  String get name => 'env';

  @override
  Future<int> run(AppletIo io, List<String> args) async {
    final parsed = parseArgs(args, flags: 'i');
    if (parsed.error != null) return usageError(io, name, parsed.error!);
    final env = parsed.has('i') ? <String, String>{} : {...io.env};
    var index = 0;
    final operands = parsed.operands;
    while (index < operands.length) {
      final assignment = _assignment.firstMatch(operands[index]);
      if (assignment == null) break;
      env[assignment.group(1)!] = assignment.group(2)!;
      index++;
    }
    if (index == operands.length) {
      final names = env.keys.toList()..sort();
      for (final key in names) {
        io.stdout.writeText('$key=${env[key]}\n');
      }
      return 0;
    }
    return io.exec(operands.sublist(index), io.copyWith(env: env));
  }
}

/// `NAME=VALUE` в начале команды `env`. Значение может содержать `=`.
final _assignment = RegExp(r'^([^=]+)=(.*)$', dotAll: true);

/// `printenv [NAME...]`: значения переменных, каждая на своей строке. Нет переменной — код 1, без вывода.
final class _Printenv implements Applet {
  const _Printenv();

  @override
  String get name => 'printenv';

  @override
  Future<int> run(AppletIo io, List<String> args) async {
    if (args.isEmpty) {
      final names = io.env.keys.toList()..sort();
      for (final key in names) {
        io.stdout.writeText('$key=${io.env[key]}\n');
      }
      return 0;
    }
    var status = 0;
    for (final arg in args) {
      final value = io.env[arg];
      if (value == null) {
        status = 1;
      } else {
        io.stdout.writeText('$value\n');
      }
    }
    return status;
  }
}

/// `which NAME...`: путь апплета `/bin/NAME` для каждой известной команды. Неизвестная — код 1 для всей
/// команды, как у GNU which.
final class _Which implements Applet {
  const _Which();

  @override
  String get name => 'which';

  @override
  Future<int> run(AppletIo io, List<String> args) async {
    if (args.isEmpty) return 1;
    var status = 0;
    for (final arg in args) {
      if (io.applets.lookup(arg) != null) {
        io.stdout.writeText('/bin/$arg\n');
      } else {
        status = 1;
      }
    }
    return status;
  }
}

/// `xargs [-n N] [-r] [COMMAND [ARG...]]`: читает аргументы из stdin, разделённые пробелами и переводами
/// строк, и запускает команду пачками по N штук. Без команды — `echo`. Без `-0` и кавычек: аргументы с
/// пробелами не поддерживаются, это задокументировано и видно модели через `--help`-подобный вывод.
final class _Xargs implements Applet {
  const _Xargs();

  @override
  String get name => 'xargs';

  @override
  Future<int> run(AppletIo io, List<String> args) async {
    final parsed = parseArgs(args, flags: 'r', valued: 'n');
    if (parsed.error != null) return usageError(io, name, parsed.error!);
    final perRun = int.tryParse(parsed.value('n') ?? '');
    if (parsed.value('n') != null && (perRun == null || perRun < 1)) {
      return usageError(io, name, 'invalid number: ${parsed.value('n')}');
    }
    final input = utf8
        .decode(io.stdin, allowMalformed: true)
        .split(RegExp(r'\s+'))
        .where((s) => s.isNotEmpty)
        .toList();
    final command = parsed.operands.isEmpty ? ['echo'] : parsed.operands;
    if (input.isEmpty && parsed.has('r')) return 0;
    final size = perRun ?? (input.isEmpty ? 1 : input.length);
    var status = 0;
    final batches = input.isEmpty ? [<String>[]] : _chunks(input, size);
    for (final batch in batches) {
      final code = await io.exec([
        ...command,
        ...batch,
      ], io.copyWith(readStdin: () => Uint8List(0)));
      if (code != 0) status = 123;
    }
    return status;
  }

  static List<List<String>> _chunks(List<String> items, int size) => [
    for (var start = 0; start < items.length; start += size)
      items.sublist(start, (start + size).clamp(0, items.length)),
  ];
}
