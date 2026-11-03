import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/core/domain/host.dart';
import 'package:probably_works/host/shell_adapter.dart';

const _sh = ShellAdapter(HostOs.posix);

/// Временный каталог с файлами и `awk`, подменённым на [awkName] через PATH: проверяем и gawk, и mawk.
class _Env {
  _Env(this.awkName) {
    dir = Directory.systemTemp.createTempSync('pw_read_');
    bin = Directory('${dir.path}/bin')..createSync();
    Link('${bin.path}/awk').createSync('/usr/bin/$awkName');
  }

  final String awkName;
  late final Directory dir;
  late final Directory bin;

  File write(String name, List<int> bytes) =>
      File('${dir.path}/$name')..writeAsBytesSync(bytes);

  Future<ProcessResult> readFile(
    String path, {
    int offset = 1,
    int byteOffset = 0,
    int limit = 200,
    int chunk = 20000,
    int lineBytes = 2000,
  }) => Process.run(
    'sh',
    [
      '-c',
      _sh.readFile(
        path,
        offset: offset,
        byteOffset: byteOffset,
        limit: limit,
        chunkBytes: chunk,
        lineBytes: lineBytes,
      ),
    ],
    environment: {'PATH': '${bin.path}:${Platform.environment['PATH']}'},
  );

  Future<ProcessResult> grep(String pattern, String path) => Process.run(
    'sh',
    ['-c', _sh.grep(pattern, path)],
    environment: {'PATH': '${bin.path}:${Platform.environment['PATH']}'},
  );

  void dispose() => dir.deleteSync(recursive: true);
}

/// Читает файл целиком, следуя курсорам из подвала, и собирает строки обратно.
/// Строка, разрезанная между вызовами, склеивается по номеру строки.
Future<List<String>> _readAll(
  _Env env,
  String path, {
  int limit = 200,
  int chunk = 20000,
  int lineBytes = 2000,
}) async {
  final lines = <int, StringBuffer>{};
  var offset = 1;
  var byteOffset = 0;
  for (var step = 0; step < 10000; step++) {
    final result = await env.readFile(
      path,
      offset: offset,
      byteOffset: byteOffset,
      limit: limit,
      chunk: chunk,
      lineBytes: lineBytes,
    );
    expect(result.exitCode, 0, reason: '${result.stderr}');
    final out = result.stdout as String;
    for (final line in const LineSplitter().convert(out)) {
      final match = RegExp(r'^(\d+)(?: \(from byte \d+\))?: (.*)$')
          .firstMatch(line);
      if (match != null) {
        (lines[int.parse(match[1]!)] ??= StringBuffer()).write(match[2]);
      }
    }
    if (out.contains('[end of file]')) break;
    final next = RegExp(r'continue with offset=(\d+)(?: byte_offset=(\d+))?\]')
        .firstMatch(out);
    expect(next, isNotNull, reason: out);
    offset = int.parse(next![1]!);
    byteOffset = next[2] == null ? 0 : int.parse(next[2]!);
  }
  final keys = lines.keys.toList()..sort();
  return [for (final key in keys) lines[key]!.toString()];
}

void main() {
  for (final awk in ['gawk', 'mawk']) {
    group('read_file через $awk', () {
      late _Env env;

      setUp(() => env = _Env(awk));
      tearDown(() => env.dispose());

      test('короткий файл: заголовок, номера строк и маркер конца', () async {
        final file = env.write('a.txt', utf8.encode('alpha\nbeta\ngamma'));
        final result = await env.readFile(file.path);
        expect(result.exitCode, 0, reason: '${result.stderr}');
        expect(
          result.stdout,
          '[file: 3 lines, 16 bytes]\n1: alpha\n2: beta\n3: gamma\n[end of file]\n',
        );
      });

      test(
        'перевод строки в конце: последняя строка не теряется и не удваивается',
        () async {
          final file = env.write('b.txt', utf8.encode('a\nb\n'));
          final result = await env.readFile(file.path);
          expect(
            result.stdout,
            '[file: 2 lines, 4 bytes]\n1: a\n2: b\n[end of file]\n',
          );
        },
      );

      test('offset и limit: подвал подсказывает следующий offset', () async {
        final file = env.write('c.txt', utf8.encode('l1\nl2\nl3\nl4\nl5'));
        final result = await env.readFile(file.path, offset: 2, limit: 2);
        expect(
          result.stdout,
          '[file: 5 lines, 14 bytes]\n2: l2\n3: l3\n[more: continue with offset=4]\n',
        );
      });

      test(
        'offset за концом файла — понятное сообщение, а не пустой вывод',
        () async {
          final file = env.write('d.txt', utf8.encode('x\ny\nz'));
          final result = await env.readFile(file.path, offset: 10);
          expect(
            result.stdout,
            '[file: 3 lines, 5 bytes]\n[offset 10 is beyond the end of the file (3 lines)]\n',
          );
        },
      );

      test('пустой файл', () async {
        final file = env.write('empty.txt', const []);
        final result = await env.readFile(file.path);
        expect(
          result.stdout,
          '[file: 0 lines, 0 bytes]\n[offset 1 is beyond the end of the file (0 lines)]\n',
        );
      });

      test(
        'байтовый лимит: все строки собираются из нескольких вызовов',
        () async {
          final source = [for (var i = 0; i < 40; i++) 'line $i ${'x' * 30}'];
          final file = env.write('big.txt', utf8.encode(source.join('\n')));
          final lines = await _readAll(env, file.path, chunk: 200);
          expect(lines, source);
        },
      );

      test(
        'длинная строка режется по lineBytes и дочитывается через byte_offset',
        () async {
          final long = 'abcdefghij' * 10;
          final file = env.write('long.txt', utf8.encode('$long\ntail'));
          final first = await env.readFile(file.path, lineBytes: 30);
          expect(
            first.stdout,
            contains(
              '[line 1 is cut at byte 30 of 100 bytes: continue with offset=1 byte_offset=30]',
            ),
          );
          final lines = await _readAll(env, file.path, lineBytes: 30);
          expect(lines, [long, 'tail']);
        },
      );

      test('UTF-8: разрез не попадает внутрь символа', () async {
        final line = 'привет мир ' * 10;
        final file = env.write('ru.txt', utf8.encode('$line\nконец'));
        final lines = await _readAll(env, file.path, lineBytes: 7);
        expect(lines, [line, 'конец']);
      });

      test('бинарный файл (есть NUL) не читается', () async {
        final file = env.write('bin.dat', [0x41, 0x00, 0x42]);
        final result = await env.readFile(file.path);
        expect(result.exitCode, isNot(0));
        expect(result.stderr, contains('binary'));
      });

      test('отсутствующий файл — ошибка', () async {
        final result = await env.readFile('${env.dir.path}/nope.txt');
        expect(result.exitCode, isNot(0));
      });

      test(
        'grep: пропускает .git и помечает обрезку при большом числе совпадений',
        () async {
          final src = Directory('${env.dir.path}/src')..createSync();
          final git = Directory('${env.dir.path}/.git')..createSync();
          File('${git.path}/config').writeAsStringSync('hello from git\n');
          File('${src.path}/a.txt').writeAsStringSync('hello world\nnope\n');
          final many = [for (var i = 0; i < 350; i++) 'hello $i'].join('\n');
          File('${src.path}/many1.txt').writeAsStringSync(many);
          File('${src.path}/many2.txt').writeAsStringSync(many);

          final small = await env.grep('hello', '${src.path}/a.txt');
          expect(small.stdout, contains('1:hello world'));
          expect(small.stdout, isNot(contains('nope')));

          final tree = await env.grep('hello', env.dir.path);
          expect(tree.stdout, isNot(contains('.git')));
          expect(
            tree.stdout,
            contains('[more matches not shown: narrow the pattern or path]'),
          );
        },
      );
    }, skip: !File('/usr/bin/$awk').existsSync());
  }
}
