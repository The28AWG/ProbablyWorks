import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/host/host_runtime.dart';
import 'package:probably_works/host/virtual/in_memory_vfs_store.dart';
import 'package:probably_works/host/virtual/shell/applets/applet.dart';
import 'package:probably_works/host/virtual/shell/shell_interpreter.dart';
import 'package:probably_works/host/virtual/shell/shell_io.dart';
import 'package:probably_works/host/virtual/vfs_path.dart';
import 'package:probably_works/host/virtual/virtual_fs.dart';
import 'package:probably_works/host/virtual/virtual_limits.dart';
import 'package:probably_works/host/virtual/virtual_profile.dart';

/// Итог запуска: stdout, stderr и код выхода. У виртуального запуска есть ещё ФС для проверки записи.
final class _Outcome {
  const _Outcome(this.stdout, this.stderr, this.exitCode, {this.fs});

  final String stdout;
  final String stderr;
  final int exitCode;
  final VirtualFs? fs;
}

const _workdir = '/work';

/// Файлы, которые лежат и в виртуальной ФС, и в настоящем каталоге bash. Скрипты читают их одинаково.
const _fixture = {
  'a.txt': 'alpha\n',
  'b.txt': 'beta\n',
  'c.log': 'gamma',
  'in.txt': 'from input\n',
  'sub/inner.txt': 'deep\n',
  '.hidden': 'h\n',
};

/// Апплеты только для тестов интерпретатора: echo, cat, true, false. Они повторяют поведение GNU для
/// тех аргументов, которые здесь используются, и поэтому сравниваются с настоящими утилитами bash.
final class _Echo implements Applet {
  const _Echo();

  @override
  String get name => 'echo';

  @override
  Future<int> run(AppletIo io, List<String> args) async {
    io.stdout.writeText('${args.join(' ')}\n');
    return 0;
  }
}

final class _Cat implements Applet {
  const _Cat();

  @override
  String get name => 'cat';

  @override
  Future<int> run(AppletIo io, List<String> args) async {
    if (args.isEmpty) {
      io.stdout.write(io.stdin);
      return 0;
    }
    var status = 0;
    for (final arg in args) {
      if (arg == '-') {
        io.stdout.write(io.stdin);
        continue;
      }
      try {
        io.stdout.write(await io.fs.readBytes(arg, cwd: io.cwd));
      } on VfsException catch (e) {
        io.stderr.writeText('cat: $arg: ${e.message}\n');
        status = 1;
      }
    }
    return status;
  }
}

final class _True implements Applet {
  const _True();

  @override
  String get name => 'true';

  @override
  Future<int> run(AppletIo io, List<String> args) async => 0;
}

final class _False implements Applet {
  const _False();

  @override
  String get name => 'false';

  @override
  Future<int> run(AppletIo io, List<String> args) async => 1;
}

final _registry = AppletRegistry(const [_Echo(), _Cat(), _True(), _False()]);

/// Запускает скрипт в виртуальной ФС с файлами [_fixture] (или [files]) в каталоге [_workdir].
Future<_Outcome> _shell(
  String script, {
  Map<String, String> files = _fixture,
  VirtualLimits limits = const VirtualLimits(),
}) async {
  final fs = VirtualFs(
    InMemoryVfsStore(),
    limits: limits,
    clock: () => 1700000000,
  );
  await fs.mkdir(_workdir, recursive: true);
  for (final entry in files.entries) {
    final path = VfsPath.join(_workdir, entry.key);
    await fs.mkdir(VfsPath.parent(path), recursive: true);
    await fs.writeBytes(path, Uint8List.fromList(utf8.encode(entry.value)));
  }
  final interpreter = ShellInterpreter(
    fs: fs,
    applets: _registry,
    profile: const VirtualProfile(home: _workdir),
  );
  final events = await interpreter.run(script, cwd: _workdir).toList();
  final stdout = BytesBuilder();
  final stderr = BytesBuilder();
  var exitCode = -1;
  for (final event in events) {
    switch (event) {
      case ExecStdout(:final bytes):
        stdout.add(bytes);
      case ExecStderr(:final bytes):
        stderr.add(bytes);
      case ExecDone(exitCode: final code):
        exitCode = code ?? -1;
      case ExecStarted():
    }
  }
  return _Outcome(
    utf8.decode(stdout.toBytes()),
    utf8.decode(stderr.toBytes()),
    exitCode,
    fs: fs,
  );
}

/// Запускает скрипт настоящим bash на Linux в временном каталоге с теми же файлами. Локаль C, чтобы
/// сообщения и сортировка глобов совпадали с виртуальным shell.
Future<_Outcome> _bash(
  String script, {
  Map<String, String> files = _fixture,
}) async {
  final dir = await Directory.systemTemp.createTemp('vsh_diff_');
  try {
    for (final entry in files.entries) {
      final file = File('${dir.path}/${entry.key}');
      await file.parent.create(recursive: true);
      await file.writeAsString(entry.value);
    }
    final result = await Process.run(
      'bash',
      ['-c', script],
      workingDirectory: dir.path,
      environment: {'LC_ALL': 'C', 'HOME': _workdir},
    );
    return _Outcome(
      result.stdout as String,
      result.stderr as String,
      result.exitCode,
    );
  } finally {
    await dir.delete(recursive: true);
  }
}

/// Скрипты, которые должны давать тот же stdout, stderr и код выхода, что и bash -c.
const _differential = [
  'echo hello world',
  'echo a; echo b',
  'echo a\necho b',
  '',
  '# только комментарий',
  'echo a # хвост',
  'echo "a  b"',
  "echo 'a  b' c",
  r'echo "a\"b" \$HOME',
  r'echo a\ b',
  r'echo "x"y"z"',
  'echo "" b',
  r'echo ""',
  "echo '\$HOME' \"\$HOME\"",
  'false && echo no || echo yes',
  'true && echo yes || echo no',
  'false; echo \$?',
  'false || false; echo \$?',
  'echo a && exit 4 || echo b',
  'echo hi | cat | cat',
  'echo hi | false; echo \$?',
  'nosuch | cat; echo \$?',
  '! false; echo \$?',
  '! true | cat; echo \$?',
  r'X=1; echo $X ${X}2 "$X" "${X}"',
  r'echo "[$UNSET]" x',
  r'X="a   b"; echo $X "$X"',
  r'X=5; X=6 echo $X; echo $X',
  r'x=1 true; echo "[$x]"',
  r'export X=7; echo $X; unset X; echo "[$X]"',
  r'Y=$(echo one two); echo $Y',
  r'echo $(echo a; echo b)',
  r'echo "$(echo a; echo b)"',
  r'echo $(echo $(echo deep))',
  r'echo "x$(true)y"',
  r'x=$(false); echo $?',
  r'$(false); echo $?',
  r'echo $(exit 3)$?',
  r'echo $(cat in.txt)',
  'echo hi > out.txt; cat out.txt',
  'echo a > out.txt; echo b >> out.txt; cat out.txt',
  'cat < in.txt',
  'cat < /dev/null; echo "[done]"',
  'echo one > o.txt && cat o.txt',
  'cat in.txt | cat',
  'cat nope; echo \$?',
  'cat nope 2>&1',
  'cat nope 2>/dev/null; echo \$?',
  'echo err 1>&2',
  'echo to-null > /dev/null; echo ok',
  'cat nope > made.txt; echo \$?; cat made.txt',
  'cat a.txt b.txt',
  'cat a.txt nope b.txt',
  'cat a.txt | cat > both.txt 2>&1; cat both.txt',
  'echo a > nodir/f; echo \$?',
  'cat <<EOF\nhello\nEOF',
  'X=there; cat <<EOF\nhi \$X\nEOF',
  "cat <<'EOF'\n\$X\nEOF",
  'cat <<-EOF\n\tindented\n\tEOF',
  'cat <<< "here"',
  'cat <<EOF\nno end',
  'cat <<EOF\nno end\n',
  'cd sub; cat inner.txt',
  'cd sub && cd .. && cat a.txt',
  'cd nope; echo \$?',
  'cd sub; echo \$?; cd ..; cat sub/inner.txt',
  'echo *.txt',
  'echo *.none',
  r'echo "*.txt"',
  'echo [ab].txt',
  'echo ?.log',
  'echo *',
  'echo sub/*',
  'echo ./*.txt',
  'echo ~',
  'echo ~/a.txt',
  r'echo $0 $# $?',
  'exit 3; echo no',
  'false; exit',
  'exit 300',
  'exit -1',
  'nosuchcommand',
  'echo a\nnosuch',
  'nosuchcommand; echo after',
  'cat < nope',
  'echo a | exit 5; echo \$?',
  'exit 2 | cat; echo \$?',
  'true | true | false',
  '/bin/echo via-path',
  '/nope/x; echo \$?',
  // Условные конструкции.
  'if true; then echo y; fi',
  'if false; then echo a; elif true; then echo b; else echo c; fi',
  'if false; then echo a; else echo c; fi',
  'if false; then echo a; fi; echo \$?',
  'if false; then echo a; elif false; then echo b; fi; echo \$?',
  'if true; then false; fi; echo \$?',
  // Циклы while и until.
  'while false; do echo no; done; echo \$?',
  'until true; do echo no; done; echo \$?',
  'while read line; do echo "[\$line]"; done < in.txt',
  r'cat in.txt | while read line; do echo "got $line"; done',
  r'echo a | while read x; do echo "got $x"; done',
  // Циклы for, break и continue.
  'for i in 1 2 3; do echo \$i; done',
  r'for i in a "b c" ""; do echo "<$i>"; done',
  'for i in 1 2 3; do echo \$i; continue; echo no; done',
  'for i in 1 2 3; do echo \$i; break; done',
  'for i in 1 2; do for j in a b; do echo \$i\$j; continue 2; done; done',
  'for i in 1 2; do for j in a b; do echo \$i\$j; break 2; done; done; echo end',
  'for i in 1 2; do echo \$i; done | cat',
  // case, включая все три терминатора.
  r'case abc in a*) echo star;; esac',
  'case x in a) echo a;; *) echo other;; esac',
  'case x in x) echo 1;& y) echo 2;; z) echo 3;; esac',
  r'case x in x*) echo 1;;& *x) echo 2;; esac',
  'case x in y) echo no;; esac; echo \$?',
  "case '' in '') echo empty;; esac",
  'case "a b" in "a b") echo quoted;; esac',
  // Функции, параметры, return, local, shift.
  r'f() { echo "$1-$#"; return 3; echo no; }; f a b; echo $?',
  r'f() { shift; echo $1 $#; }; f a b c',
  r'f() { echo $(($1 + 1)); }; f 4',
  r'f() { local x=1; echo $x; }; x=0; f; echo $x',
  r'f() { echo $x; }; x=2; f',
  r'f() { echo "[$X]"; }; X=5 f; echo "[$X]"',
  r'X=1; f() { echo $X; }; X=2 f; echo $X',
  'f() { echo in; }; f() { echo redefined; }; f',
  r'f() { f2 "$@"; }; f2() { echo "[$*]"; }; f a b',
  'f() { return 5; }; f; echo \$?',
  'f() { false; }; f && echo yes || echo no',
  r'f() { for a; do echo "arg $a"; done; }; f x "y z"',
  r'f() { break; }; for i in 1 2; do f; echo "i=$i"; done; echo end',
  'f() { echo in-f; } > o.txt; f; cat o.txt',
  // Подоболочка и группа.
  '(X=1; echo \$X); echo "[\$X]"',
  '(exit 3); echo \$?',
  '{ echo a; echo b; } > g.txt; cat g.txt',
  '{ echo a; false; } || echo failed',
  // Подстановки и арифметика.
  r'echo `echo hi`',
  r'echo `echo a b` c',
  r'echo $((2*3)) $((7/2)) $((1<2 ? 10 : 20))',
  r'x=5; echo $((x * 2)) $((x > 3 && x < 9))',
];

/// Конструкции, которые bash выполняет, а виртуальный shell пока нет. Здесь проверяется только отказ:
/// ни одна команда скрипта не должна выполниться, код выхода — 2. Сравнивать с bash нельзя, потому что
/// он выполнит скрипт.
const _rejected = [
  'echo a; echo a & echo b',
  r'echo a; echo ${x:-default}',
  'echo a; [[ -f in.txt ]]',
  'echo a; ((i++))',
  'echo a; select x in a; do :; done',
  'echo a; echo a |',
];

void main() {
  final skip = Platform.isLinux ? false : 'сравнение с bash только на Linux';

  group('сравнение с bash -c', () {
    for (final script in _differential) {
      test('совпадает: ${script.replaceAll('\n', r'\n')}', () async {
        final ours = await _shell(script);
        final real = await _bash(script);
        expect(ours.stdout, real.stdout);
        expect(ours.stderr, real.stderr);
        expect(ours.exitCode, real.exitCode);
      }, skip: skip);
    }
  });

  group('отказ без выполнения', () {
    for (final script in _rejected) {
      test(script.replaceAll('\n', r'\n'), () async {
        final outcome = await _shell(script);
        expect(outcome.stdout, isEmpty);
        expect(outcome.exitCode, 2);
        expect(outcome.stderr, startsWith('bash: -c: line 1: '));
      });
    }
  });

  group('поведение виртуального shell', () {
    test(
      'синтаксис и неподдерживаемые конструкции не запускают команды',
      () async {
        final outcome = await _shell('echo a; echo a & echo b');
        expect(outcome.stdout, isEmpty);
        expect(outcome.exitCode, 2);
        expect(outcome.stderr, contains('unsupported syntax: operator &'));
      },
    );

    test('бесконечный цикл останавливается лимитом команд', () async {
      final outcome = await _shell(
        'while true; do :; done',
        limits: const VirtualLimits(maxCommandsPerRun: 50),
      );
      expect(outcome.exitCode, 1);
      expect(
        outcome.stderr,
        contains('too many commands in one run (limit 50)'),
      );
    });

    test('рекурсия функции останавливается лимитом команд', () async {
      final outcome = await _shell(
        'f() { f; }; f',
        limits: const VirtualLimits(maxCommandsPerRun: 50),
      );
      expect(outcome.exitCode, 1);
      expect(outcome.stderr, contains('too many commands in one run'));
    });

    test('ошибка арифметики отменяет только свою команду', () async {
      final outcome = await _shell('echo \$((1/0)); echo ok');
      expect(outcome.stdout, 'ok\n');
      expect(outcome.stderr, contains('division by 0'));
      expect(outcome.exitCode, 0);
    });

    test('параметры верхнего уровня пусты', () async {
      final outcome = await _shell(r'echo "[$1][$#]"');
      expect(outcome.stdout, '[][0]\n');
    });

    test('`break` вне цикла не прерывает скрипт', () async {
      final outcome = await _shell('break; echo after');
      expect(outcome.stdout, 'after\n');
    });

    test('ошибка синтаксиса отмечает строку', () async {
      final outcome = await _shell('echo a\necho b\n| x');
      expect(outcome.stdout, isEmpty);
      expect(
        outcome.stderr,
        'bash: -c: line 3: syntax error near unexpected token `|\'\n',
      );
      expect(outcome.exitCode, 2);
    });

    test('вывод записывается в файл и остаётся в ФС', () async {
      final outcome = await _shell('echo hi > out.txt');
      final bytes = await outcome.fs!.readBytes('/work/out.txt');
      expect(utf8.decode(bytes), 'hi\n');
    });

    test(
      'перенаправление в несуществующий каталог даёт ошибку и код 1',
      () async {
        final outcome = await _shell('echo a > nodir/f; echo \$?');
        expect(outcome.stdout, '1\n');
        expect(
          outcome.stderr,
          'bash: line 1: nodir/f: No such file or directory\n',
        );
      },
    );

    test('подоболочка не меняет каталог родителя', () async {
      final outcome = await _shell(
        r'echo $(cd sub; cat inner.txt); cat sub/inner.txt',
      );
      expect(outcome.stdout, 'deep\ndeep\n');
      expect(outcome.exitCode, 0);
    });

    test('`cd` не переживает запуск', () async {
      await _shell('cd sub');
      final outcome = await _shell('cat sub/inner.txt');
      expect(outcome.stdout, 'deep\n');
    });

    test('текст в кавычках не глобится', () async {
      final outcome = await _shell(r'echo "*.txt" *.txt');
      expect(outcome.stdout, '*.txt a.txt b.txt in.txt\n');
    });

    test('скрипт в пути не исполняется', () async {
      final outcome = await _shell('./a.txt');
      expect(outcome.exitCode, 126);
      expect(outcome.stderr, contains('scripts are not supported'));
    });

    test('вывод сверх бюджета усекается и помечается', () async {
      final outcome = await _shell(
        'echo abcdefgh',
        limits: const VirtualLimits(maxOutputBytes: 4),
      );
      expect(outcome.stdout, 'abcd');
      expect(outcome.stderr, contains('output limit of 4 bytes exceeded'));
    });

    test('лимит команд прерывает запуск', () async {
      final outcome = await _shell(
        'true; true; true',
        limits: const VirtualLimits(maxCommandsPerRun: 2),
      );
      expect(outcome.exitCode, 1);
      expect(
        outcome.stderr,
        contains('too many commands in one run (limit 2)'),
      );
    });

    test('лимит длины пайпа', () async {
      final outcome = await _shell(
        'true | true | true',
        limits: const VirtualLimits(maxPipelineLength: 2),
      );
      expect(outcome.exitCode, 1);
      expect(outcome.stderr, contains('pipeline has more than 2 commands'));
    });

    test('лимит длины команды', () async {
      final outcome = await _shell(
        'echo abcdefgh',
        limits: const VirtualLimits(maxCommandLength: 5),
      );
      expect(outcome.exitCode, 2);
      expect(outcome.stderr, contains('longer than 5 characters'));
    });

    test('таймаут прерывает запуск с кодом 124', () async {
      final outcome = await _shell(
        'true',
        limits: const VirtualLimits(runTimeout: Duration(microseconds: -1)),
      );
      expect(outcome.exitCode, 124);
    });

    test('лимит ФС: файл больше лимита не записывается', () async {
      final outcome = await _shell(
        'echo abcdefgh > big.txt; echo \$?',
        files: {},
        limits: const VirtualLimits(maxFileBytes: 4),
      );
      expect(outcome.stdout, '1\n');
      expect(outcome.stderr, contains('big.txt: File too large'));
    });
  });
}
