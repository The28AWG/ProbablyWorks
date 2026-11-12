import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:virtual_host/src/in_memory_vfs_store.dart';
import 'package:virtual_host/src/shell/applets/standard_applets.dart';
import 'package:virtual_host/src/shell/shell_interpreter.dart';
import 'package:virtual_host/src/shell/shell_io.dart';
import 'package:virtual_host/src/vfs_path.dart';
import 'package:virtual_host/src/virtual_fs.dart';
import 'package:virtual_host/src/virtual_profile.dart';

import '../support/parity.dart';

/// Итог запуска: stdout, stderr и код выхода.
final class _Outcome {
  const _Outcome(this.stdout, this.stderr, this.exitCode);

  final String stdout;
  final String stderr;
  final int exitCode;
}

const _workdir = '/work';

/// Время VFS для всех тестов: 2023-11-14 22:13:20 UTC, вторник.
const _clock = 1700000000;

/// Файлы, которые есть и в виртуальной ФС, и в каталоге настоящего bash.
const _fixture = {
  'a.txt': 'alpha\n',
  'b.txt': 'beta\n',
  'c.log': 'gamma',
  'in.txt': 'from input\n',
  'sub/inner.txt': 'deep\n',
  '.hidden': 'h\n',
  'empty.txt': '',
  'lines.txt': '1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n',
};

/// Запускает скрипт в виртуальной ФС со стандартным реестром апплетов. Каталог — [_workdir].
Future<_Outcome> _shell(
  String script, {
  Map<String, String> files = _fixture,
  VirtualProfile profile = const VirtualProfile(home: _workdir),
}) async {
  final fs = VirtualFs(InMemoryVfsStore(), clock: () => _clock);
  await fs.mkdir(_workdir, recursive: true);
  for (final entry in files.entries) {
    final path = VfsPath.join(_workdir, entry.key);
    await fs.mkdir(VfsPath.parent(path), recursive: true);
    await fs.writeBytes(path, Uint8List.fromList(utf8.encode(entry.value)));
  }
  final interpreter = ShellInterpreter(
    fs: fs,
    applets: standardApplets,
    profile: profile,
  );
  final events = await interpreter.run(script, cwd: _workdir).toList();
  final stdout = BytesBuilder();
  final stderr = BytesBuilder();
  var exitCode = -1;
  for (final event in events) {
    switch (event) {
      case ShellStdout(:final bytes):
        stdout.add(bytes);
      case ShellStderr(:final bytes):
        stderr.add(bytes);
      case ShellDone(exitCode: final code):
        exitCode = code ?? -1;
    }
  }
  return _Outcome(
    utf8.decode(stdout.toBytes()),
    utf8.decode(stderr.toBytes()),
    exitCode,
  );
}

/// Тот же скрипт в настоящем bash с настоящими coreutils в локали C.
Future<_Outcome> _bash(
  String script, {
  Map<String, String> files = _fixture,
}) async {
  final dir = await Directory.systemTemp.createTemp('vsh_applets_');
  try {
    for (final entry in files.entries) {
      final file = File('${dir.path}/${entry.key}');
      await file.parent.create(recursive: true);
      await file.writeAsString(entry.value);
    }
    // Режимы фикстуры и создаваемых файлов задаём явно: иначе они зависят от umask хоста,
    // а у VFS — умолчания 644 для файлов и 755 для каталогов.
    await Process.run('chmod', ['-R', 'u=rwX,go=rX', dir.path]);
    final result = await Process.run(
      'bash',
      ['-c', 'umask 022\n$script'],
      workingDirectory: dir.path,
      environment: {
        'LC_ALL': 'C',
        'HOME': _workdir,
        'PATH': Platform.environment['PATH'] ?? '/usr/bin:/bin',
      },
      includeParentEnvironment: false,
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

/// Скрипты, на которых виртуальный вывод (stdout и код выхода) обязан совпадать с настоящими утилитами.
/// Вывод, зависящий от времени, владельца или номеров inode, сюда не входит: его проверяем явно ниже.
const _differential = [
  // ls
  'ls',
  'ls -a',
  'ls -A',
  'ls -1 sub',
  'ls -d sub',
  'ls a.txt sub',
  'ls -R',
  'ls nope; echo \$?',
  'mkdir d && ls -d d',
  // mkdir, touch, rm, cp, mv
  'mkdir -p x/y/z && find x | sort',
  'mkdir a.txt; echo \$?',
  'mkdir -p a.txt/b; echo \$?',
  'touch new.txt && ls',
  'touch -c ghost && ls',
  'rm a.txt && ls',
  'rm -f nope; echo \$?',
  'rm nope; echo \$?',
  'rm sub; echo \$?',
  'rm -r sub && ls',
  'cp a.txt copy.txt && cat copy.txt',
  'cp a.txt b.txt sub && cat sub/a.txt sub/b.txt',
  'cp sub x; echo \$?',
  'cp -r sub copy && cat copy/inner.txt',
  'cp a.txt nope/x; echo \$?',
  'mv a.txt moved.txt && ls',
  'mv a.txt b.txt sub && ls sub',
  'mv nope x; echo \$?',
  // stat, find
  'stat -c %s a.txt',
  'stat -c "%n %F" sub',
  'stat -c %F c.log',
  'stat -c %F empty.txt',
  'find . -name "*.txt" | sort',
  'find . -type d | sort',
  'find . -type f | sort',
  'find . -maxdepth 1 | sort',
  'find sub -maxdepth 0',
  'find . -mindepth 1 -maxdepth 1 -type d',
  'find . -name a.txt -o -name b.txt | sort',
  'find . \\( -name a.txt -o -name b.txt \\) | sort',
  'find . ! -name "*.txt" | sort',
  'mkdir e && find . -type d -empty',
  'find . -empty -type f',
  'find nope; echo \$?',
  // text
  'echo hello world',
  'echo -n a; echo b',
  'echo -e "a\\tb"',
  'echo -E "a\\n"',
  'printf "%s-%d\\n" a 1 b 2',
  'printf "%5.2f|\\n" 3.14159',
  'printf "%-5s|\\n" ab',
  'printf "%05d\\n" 42',
  'printf "%x %X %o\\n" 255 255 8',
  'printf "%c\\n" hello',
  'printf "%%\\n"',
  'printf "a\\tb\\n"',
  'printf "%b\\n" "a\\nb"',
  'printf "%s\\n"',
  'cat -n a.txt',
  'cat -n a.txt b.txt',
  'cat a.txt nope b.txt; echo \$?',
  'head -n 2 lines.txt',
  'head -3 lines.txt',
  'head -n -10 lines.txt',
  'head -n 0 lines.txt',
  'head a.txt b.txt',
  'tail -n 3 lines.txt',
  'tail -n +10 lines.txt',
  'tail -2 lines.txt',
  'tail -n 2 c.log',
  'head -c 4 a.txt',
  'tail -c 3 a.txt',
  'wc -l a.txt',
  'wc -w a.txt',
  'wc -c c.log',
  'wc a.txt',
  'wc -l a.txt b.txt',
  'printf "a b\\nc\\n" | wc -w',
  'echo tee-test | tee t.txt && cat t.txt',
  'echo more | tee -a in.txt && cat in.txt',
  'seq 3',
  'seq 2 4',
  'seq 1 2 7',
  'seq 5 -2 1',
  'basename /a/b/c.txt',
  'basename /a/b/c.txt .txt',
  'basename a/b/',
  'basename /',
  'dirname /a/b/c.txt',
  'dirname c.txt',
  'dirname /',
  'dirname a/b/',
  // filters
  'grep alpha a.txt',
  'grep -n a a.txt b.txt',
  'grep -c a a.txt b.txt',
  'grep -v alpha a.txt; echo \$?',
  'grep -i ALPHA a.txt',
  'grep -w be b.txt; echo \$?',
  'grep -x beta b.txt',
  'grep -o a a.txt',
  'grep -E "a+" a.txt',
  'grep "a\\|b" a.txt b.txt',
  'grep -F "." a.txt; echo \$?',
  'grep -l alpha *.txt',
  'grep -L alpha *.txt',
  'grep -h alpha a.txt b.txt',
  'grep -r deep .',
  'grep deep sub/inner.txt',
  'grep alpha nope; echo \$?',
  'grep -s alpha nope; echo \$?',
  'grep -A1 2 lines.txt',
  'grep -B1 -n 7 lines.txt',
  'grep -B1 -e "^3\$" -e "^9\$" lines.txt',
  'grep -A1 -e "^1\$" -e "^9\$" lines.txt',
  'grep -e alpha -e beta a.txt b.txt',
  'grep; echo \$?',
  'printf "b\\na\\nc\\n" | sort',
  'printf "b\\na\\nc\\n" | sort -r',
  'printf "10\\n9\\n100\\n" | sort -n',
  'printf "x 3\\ny 1\\nz 2\\n" | sort -k2 -n',
  'printf "a,2\\nb,1\\n" | sort -t, -k2',
  'printf "b\\na\\nb\\n" | sort -u',
  'printf "a\\na\\nb\\nb\\nb\\nc\\n" | uniq',
  'printf "a\\na\\nb\\nb\\nb\\nc\\n" | uniq -c',
  'printf "a\\na\\nb\\nb\\nb\\nc\\n" | uniq -d',
  'printf "a\\na\\nb\\nb\\nb\\nc\\n" | uniq -u',
  'printf "A\\na\\nb\\n" | uniq -i',
  'printf "a:b:c\\n" | cut -d: -f2',
  'printf "a:b:c\\n" | cut -d: -f1,3',
  'printf "a:b:c\\n" | cut -d: -f2-',
  'printf "abcdef\\n" | cut -c2-4',
  'printf "nodelim\\n" | cut -d: -f1',
  'printf "nodelim\\n" | cut -d: -s -f1; echo \$?',
  'cut -f1 nope; echo \$?',
  'echo hello | tr a-z A-Z',
  'echo hello | tr -d l',
  'echo aabbcc | tr -s ab',
  'echo "a1b2" | tr -cd 0-9',
  'echo hello | tr el ip',
  'echo "a  b" | tr -s " "',
  'echo abc | tr "[:lower:]" "[:upper:]"',
  'printf "a\\tb\\n" | tr "\\t" " "',
  'echo "a-b" | tr -c a-z _',
  // xargs
  'printf "a b c\\n" | xargs echo x',
  'printf "a\\nb\\n" | xargs -n1 echo',
  'printf "" | xargs echo; echo \$?',
  'printf "" | xargs -r echo; echo \$?',
  'printf "x\\n" | xargs cat nope; echo \$?',
  // test and [
  'test -f a.txt && echo y',
  '[ -d sub ] && echo d',
  '[ 1 -eq 1 ] && echo ok',
  '[ abc = abd ]; echo \$?',
  'test -z ""; echo \$?',
  '[ 2 -gt 10 ]; echo \$?',
  '[ ! -e nope ] && echo gone',
  'test; echo \$?',
  '[ -n x -o -z "" ] && echo either',
  '[ x -a "" ]; echo \$?',
  '[ a = b ] || echo differ',
  '[ 1 -eq a ]; echo \$?',
  '[ -s a.txt ] && echo nonempty',
  '[ -s empty.txt ]; echo \$?',
  '[ -f sub ]; echo \$?',
  '[ -e sub -a -d sub ] && echo both',
  '[ ( a = a ) ] && echo grouped',
  // sed
  "sed 's/a/X/' a.txt",
  "sed 's/a/X/g' a.txt",
  "sed -n 's/1/one/p' lines.txt",
  "sed -E 's/([0-9])([0-9])/\\2\\1/' lines.txt",
  "sed 's/\\(1\\)\\(0\\)/\\2\\1/' lines.txt",
  "sed -e 's/a/b/' -e 's/b/c/' a.txt",
  "sed 's/^/> /' a.txt",
  "sed 's/\$/!/' b.txt",
  "sed 's/b*/-/g' b.txt",
  "sed 's/a/b/' < a.txt",
  "sed 's/a/x/' nope; echo \$?",
  "sed -E 's/(/x/' a.txt; echo \$?",
  "sed 's/(/x/' a.txt",
  "sed 's/[[:digit:]]\\+/#/g' lines.txt",
  // diff and cmp
  'diff -u a.txt b.txt | tail -n +3; echo \$?',
  'diff -u lines.txt lines.txt | tail -n +3; echo \$?',
  'diff -u lines.txt sub/inner.txt | tail -n +3; echo \$?',
  'diff -u a.txt nope; echo \$?',
  'cmp a.txt b.txt; echo \$?',
  'cmp a.txt a.txt; echo \$?',
  'cmp -s a.txt b.txt; echo \$?',
  'cmp c.log empty.txt; echo \$?',
  'cmp a.txt nope; echo \$?',
  // base64, md5sum, sha256sum
  'base64 a.txt',
  'cat lines.txt lines.txt lines.txt lines.txt lines.txt | base64',
  'base64 a.txt | base64 -d',
  'printf hi | base64',
  'printf aGk= | base64 -d',
  "printf '!!!' | base64 -d; echo \$?",
  'base64 -w 4 a.txt',
  'base64 nope; echo \$?',
  'md5sum a.txt',
  'sha256sum a.txt b.txt',
  'md5sum < a.txt',
  'printf "" | sha256sum',
  'md5sum nope; echo \$?',
  // chmod, ln, readlink
  'chmod 600 a.txt && stat -c %a a.txt',
  'chmod u+x a.txt && stat -c %a a.txt',
  'chmod a-w,g+r a.txt && stat -c %a a.txt',
  'chmod -R 700 sub && stat -c %a sub sub/inner.txt',
  'chmod u=rw,go= a.txt && stat -c %a a.txt',
  'chmod 999 a.txt; echo \$?',
  'chmod +x nope; echo \$?',
  'ln -s a.txt link && readlink link',
  'ln -s a.txt link && cat link',
  'ln -s nope dangling; cat dangling; echo \$?',
  'ln -s a.txt sub && ls sub',
  'ln -s a.txt sub && readlink sub/a.txt',
  'ln -s a.txt link; ln -s a.txt link; echo \$?',
  'readlink nope; echo \$?',
  'readlink a.txt; echo \$?',
  'readlink -n link; echo',
  // gzip and tar: round trips; the archive bytes themselves differ from GNU, so only the content matters
  'gzip -c a.txt | gzip -dc',
  'gzip -c lines.txt | gzip -dc | tail -n 1',
  'tar -cf out.tar a.txt && tar -tf out.tar',
  'tar -cf out.tar sub && tar -tf out.tar',
  'tar -cf out.tar sub && mkdir d && tar -xf out.tar -C d && cat d/sub/inner.txt',
  'tar -czf out.tgz sub && tar -tzf out.tgz',
];

void main() {
  group(
    'applets: сравнение с настоящими утилитами bash',
    skip: bashParitySkipReason,
    () {
      for (final script in _differential) {
        test(script, () async {
          final ours = await _shell(script);
          final real = await _bash(script);
          expect(ours.stdout, real.stdout, reason: 'stdout');
          expect(ours.exitCode, real.exitCode, reason: 'exit code');
        });
      }
    },
  );

  group('applets: поведение, зависящее от профиля и времени', () {
    test('pwd печатает текущий каталог', () async {
      final result = await _shell('pwd; cd sub && pwd');
      expect(result.stdout, '/work\n/work/sub\n');
    });

    test('whoami, id и hostname берут профиль Host', () async {
      final result = await _shell('whoami; id -un; id -u; id; hostname');
      expect(
        result.stdout,
        'agent\nagent\n1000\nuid=1000(agent) gid=1000(agent) groups=1000(agent)\nprobably\n',
      );
    });

    test('uname печатает ядро и полную строку профиля', () async {
      final result = await _shell('uname; uname -n; uname -m; uname -a');
      expect(
        result.stdout,
        'Linux\nprobably\nx86_64\nLinux probably 6.1.0-virtual #1 SMP x86_64 GNU/Linux\n',
      );
    });

    test('date по умолчанию и с форматом берёт время VFS в UTC', () async {
      final result = await _shell(
        "date; date +'%Y-%m-%d %H:%M:%S'; date +'%A %B %j %s'",
      );
      expect(
        result.stdout,
        'Tue Nov 14 22:13:20 UTC 2023\n2023-11-14 22:13:20\nTuesday November 318 1700000000\n',
      );
    });

    test('date с неверным форматом — код 2 и сообщение', () async {
      final result = await _shell('date 2023; echo \$?');
      expect(result.stdout, '2\n');
      expect(result.stderr, contains('invalid date format'));
    });

    test('env с операндами запускает команду с новым окружением', () async {
      final result = await _shell(
        'env X=1 printenv X; env -i printenv X; echo \$?',
      );
      expect(result.stdout, '1\n1\n');
    });

    test('printenv без аргументов печатает переменные по имени', () async {
      final result = await _shell('X=5 printenv X');
      expect(result.stdout, '5\n');
    });

    test(
      'which находит апплеты по имени и возвращает 1 для неизвестных',
      () async {
        final result = await _shell('which ls cat nope; echo \$?');
        expect(result.stdout, '/bin/ls\n/bin/cat\n1\n');
      },
    );

    test('ls -l показывает права, владельца, размер и дату', () async {
      final result = await _shell('ls -l a.txt c.log empty.txt');
      expect(
        result.stdout,
        '-rw-r--r-- 1 agent agent 6 Nov 14 22:13 a.txt\n'
        '-rw-r--r-- 1 agent agent 5 Nov 14 22:13 c.log\n'
        '-rw-r--r-- 1 agent agent 0 Nov 14 22:13 empty.txt\n',
      );
    });

    test('ls -l каталога начинается с total и показывает d', () async {
      final result = await _shell('ls -l sub');
      expect(
        result.stdout,
        'total 4\n-rw-r--r-- 1 agent agent 5 Nov 14 22:13 inner.txt\n',
      );
    });

    test('ls -la показывает . и .. вместе со скрытыми', () async {
      final result = await _shell('ls -a sub');
      expect(result.stdout, '.\n..\ninner.txt\n');
    });

    test('stat -c %y и %x дают время в формате GNU', () async {
      final result = await _shell("stat -c '%y' a.txt");
      expect(result.stdout, '2023-11-14 22:13:20.000000000 +0000\n');
    });

    test('stat без -c печатает блок с размером и типом', () async {
      final result = await _shell('stat a.txt');
      expect(result.stdout, contains('  File: a.txt'));
      expect(result.stdout, contains('Size: 6'));
      expect(result.stdout, contains('regular file'));
      expect(result.stdout, contains('Access: (0644/-rw-r--r--)'));
    });

    test('stat несуществующего пути — ошибка', () async {
      final result = await _shell('stat nope; echo \$?');
      expect(result.stdout, '1\n');
      expect(result.stderr, contains("cannot statx 'nope'"));
    });

    test('mkdir -v печатает созданные каталоги', () async {
      final result = await _shell('mkdir -v d1 d2');
      expect(
        result.stdout,
        "mkdir: created directory 'd1'\nmkdir: created directory 'd2'\n",
      );
    });

    test('touch создаёт файл и не меняет существующий', () async {
      final result = await _shell('touch new.txt; cat new.txt; cat a.txt');
      expect(result.stdout, 'alpha\n');
    });

    test('cp -r в существующий каталог копирует его с содержимым', () async {
      final result = await _shell(
        'mkdir out && cp -r sub out && cat out/sub/inner.txt',
      );
      expect(result.stdout, 'deep\n');
    });

    test('cp нескольких источников в не-каталог — ошибка', () async {
      final result = await _shell('cp a.txt b.txt c.log; echo \$?');
      expect(result.stdout, '1\n');
      expect(result.stderr, contains("target 'c.log' is not a directory"));
    });

    test('mv в существующий каталог переносит внутрь', () async {
      final result = await _shell('mv a.txt sub && cat sub/a.txt; ls');
      expect(
        result.stdout,
        'alpha\nb.txt\nc.log\nempty.txt\nin.txt\nlines.txt\nsub\n',
      );
    });

    test('rm -f на отсутствующем файле — успех без сообщения', () async {
      final result = await _shell('rm -f nope; echo \$?');
      expect(result.stdout, '0\n');
      expect(result.stderr, isEmpty);
    });

    test('find -exec не поддерживается и даёт ошибку разбора', () async {
      final result = await _shell('find . -exec ls \\; ; echo \$?');
      expect(result.stdout, '1\n');
      expect(result.stderr, contains("unknown predicate '-exec'"));
    });

    test('find -type с неизвестным аргументом — ошибка', () async {
      final result = await _shell('find . -type x; echo \$?');
      expect(result.stdout, '1\n');
      expect(result.stderr, contains('unknown argument to -type'));
    });

    test('find -name без аргумента — ошибка', () async {
      final result = await _shell('find . -name; echo \$?');
      expect(result.stdout, '1\n');
      expect(result.stderr, contains("missing argument to '-name'"));
    });

    test('grep -r без операнда ищет в текущем каталоге без ./', () async {
      final result = await _shell('grep -r deep');
      expect(result.stdout, 'sub/inner.txt:deep\n');
    });

    test('grep с контекстом печатает разрыв групп как --', () async {
      final result = await _shell('grep -B1 -e "^3\$" -e "^9\$" lines.txt');
      expect(result.stdout, '2\n3\n--\n8\n9\n');
    });

    test('grep -A0 без контекста не печатает разделители', () async {
      final result = await _shell('grep -A0 -e 1 -e 9 lines.txt');
      expect(result.stdout, '1\n9\n10\n11\n12\n');
    });

    test('grep -c с несколькими файлами печатает имя и счётчик', () async {
      final result = await _shell('grep -c a a.txt b.txt');
      expect(result.stdout, 'a.txt:1\nb.txt:1\n');
    });

    test('grep -E с некорректным шаблоном — код 2', () async {
      final result = await _shell('grep -E "(" a.txt; echo \$?');
      expect(result.stdout, '2\n');
      expect(result.stderr, startsWith('grep: '));
    });

    test('grep -f читает шаблоны из файла', () async {
      final result = await _shell(
        'printf "beta\\n" > pats; grep -f pats a.txt b.txt',
      );
      expect(result.stdout, 'b.txt:beta\n');
    });

    test('sort -k с неверным номером — ошибка', () async {
      final result = await _shell('printf "a\\n" | sort -k 0; echo \$?');
      expect(result.stdout, '2\n');
      expect(result.stderr, contains('invalid number at field start'));
    });

    test('tr -d с классом [:digit:]', () async {
      final result = await _shell('echo a1b22c | tr -d "[:digit:]"');
      expect(result.stdout, 'abc\n');
    });

    test('tr с неизвестным классом — ошибка', () async {
      final result = await _shell('echo a | tr "[:nope:]" x; echo \$?');
      expect(result.stdout, '2\n');
    });

    test('xargs без команды печатает аргументы через echo', () async {
      final result = await _shell('printf "1 2\\n3\\n" | xargs');
      expect(result.stdout, '1 2 3\n');
    });

    test('xargs -n с неверным числом — ошибка', () async {
      final result = await _shell('echo a | xargs -n 0 echo; echo \$?');
      expect(result.stdout, '2\n');
    });

    test('echo -e с \\c обрывает вывод', () async {
      final result = await _shell('echo -e "a\\cb"');
      expect(result.stdout, 'a');
    });

    test('echo без опций печатает обратные слэши как есть', () async {
      final result = await _shell(r'echo "a\nb"');
      expect(result.stdout, 'a\\nb\n');
    });

    test('printf повторяет формат, пока есть аргументы', () async {
      final result = await _shell('printf "[%s]" a b c; echo');
      expect(result.stdout, '[a][b][c]\n');
    });

    test('printf с неверным числом — код 1 и сообщение', () async {
      final result = await _shell('printf "%d\\n" abc; echo \$?');
      expect(result.stdout, '0\n1\n');
      expect(result.stderr, contains("'abc': expected a numeric value"));
    });

    test('printf %f принимает дробные числа', () async {
      final result = await _shell('printf "%.3f\\n" 2.5');
      expect(result.stdout, '2.500\n');
    });

    test('cat -n нумерует строки сквозь файлы', () async {
      final result = await _shell('cat -n a.txt b.txt');
      expect(result.stdout, '     1\talpha\n     2\tbeta\n');
    });

    test('tee без файлов копирует stdin на stdout', () async {
      final result = await _shell('echo hi | tee');
      expect(result.stdout, 'hi\n');
    });

    test('head -c и tail -c работают в байтах', () async {
      final result = await _shell('head -c 3 a.txt; echo; tail -c 2 a.txt');
      expect(result.stdout, 'alp\na\n');
    });

    test('head с несколькими файлами печатает заголовки', () async {
      final result = await _shell('head -n 1 a.txt b.txt');
      expect(result.stdout, '==> a.txt <==\nalpha\n\n==> b.txt <==\nbeta\n');
    });

    test('tail с отрицательным числом берёт последние строки', () async {
      final result = await _shell('tail -n -2 lines.txt');
      expect(result.stdout, '11\n12\n');
    });

    test('test с одним аргументом проверяет непустоту', () async {
      final result = await _shell('test x && echo a; test "" || echo b');
      expect(result.stdout, 'a\nb\n');
    });

    test('test с целым нечисловым операндом — код 2', () async {
      final result = await _shell('[ x -eq 1 ]; echo \$?');
      expect(result.stdout, '2\n');
      expect(result.stderr, contains('integer expression expected'));
    });

    test('[ без закрывающей скобки — код 2', () async {
      final result = await _shell('[ 1 = 1; echo \$?');
      expect(result.stdout, '2\n');
      expect(result.stderr, contains("missing ']'"));
    });

    test('реестр содержит все стандартные апплеты', () {
      final names = standardApplets.names;
      for (final name in [
        'ls',
        'mkdir',
        'touch',
        'rm',
        'cp',
        'mv',
        'stat',
        'find',
        'echo',
        'printf',
        'cat',
        'head',
        'tail',
        'wc',
        'tee',
        'seq',
        'basename',
        'dirname',
        'grep',
        'sort',
        'uniq',
        'cut',
        'tr',
        'uname',
        'whoami',
        'id',
        'hostname',
        'date',
        'env',
        'printenv',
        'which',
        'true',
        'false',
        'pwd',
        'xargs',
        'test',
        '[',
        'sed',
        'diff',
        'cmp',
        'base64',
        'md5sum',
        'sha256sum',
        'gzip',
        'tar',
        'ln',
        'readlink',
        'realpath',
        'chmod',
        'du',
        'df',
        'uptime',
      ]) {
        expect(names, contains(name));
      }
    });
  });

  group('applets tier 2: явные проверки вне сравнения с bash', () {
    test('du -s суммирует блоки по 4 КиБ, каталог учитывается сам', () async {
      // Корень: каталог (4), семь файлов с данными по 4 КиБ, пустой файл (0), подкаталог sub (4+4).
      final result = await _shell('du -s');
      expect(result.stdout, '36\t.\n');
    });

    test('du -a печатает файлы до каталога, потомки по имени', () async {
      final result = await _shell('du -a sub');
      expect(result.stdout, '4\tsub/inner.txt\n8\tsub\n');
    });

    test('du -h печатает размер в единицах с одним знаком', () async {
      final result = await _shell('du -h sub');
      expect(result.stdout, '8.0K\tsub\n');
    });

    test('du несуществующего пути — код 1 и сообщение', () async {
      final result = await _shell('du nope; echo \$?');
      expect(result.stdout, '1\n');
      expect(result.stderr, contains("cannot access 'nope'"));
    });

    test('df печатает заголовок GNU и строку раздела с процентом', () async {
      final result = await _shell('df');
      final lines = result.stdout.split('\n');
      expect(lines.first, startsWith('Filesystem'));
      expect(lines.first, endsWith('Mounted on'));
      expect(lines[1], matches(RegExp(r'^\S+ +\d+ +\d+ +\d+ +\d+% /$')));
    });

    test('df -h использует заголовок Size', () async {
      final result = await _shell('df -h');
      expect(result.stdout.split('\n').first, contains('Size'));
    });

    test('df несуществующего пути — код 1 и сообщение', () async {
      final result = await _shell('df nope; echo \$?');
      expect(result.stdout, '1\n');
      expect(result.stderr, contains('nope: No such file or directory'));
    });

    test('uptime без запуска (bootedAt 0) показывает 0 min', () async {
      final result = await _shell('uptime');
      expect(
        result.stdout,
        ' 22:13:20 up 0 min,  1 user,  load average: 0.00, 0.00, 0.00\n',
      );
    });

    test('uptime считает время от bootedAt профиля', () async {
      // 2 часа 5 минут назад.
      final result = await _shell(
        'uptime',
        profile: const VirtualProfile(
          home: _workdir,
          bootedAt: _clock - (2 * 3600 + 5 * 60),
        ),
      );
      expect(
        result.stdout,
        ' 22:13:20 up 2:05,  1 user,  load average: 0.00, 0.00, 0.00\n',
      );
    });

    test('uptime больше суток показывает дни', () async {
      // 1 сутки, 1 час, 1 минута.
      final result = await _shell(
        'uptime',
        profile: const VirtualProfile(
          home: _workdir,
          bootedAt: _clock - (86400 + 3600 + 60 + 1),
        ),
      );
      expect(result.stdout, contains('up 1 day,  1:01,  1 user'));
    });

    test('diff -u печатает заголовки с временем VFS и hunk', () async {
      final result = await _shell('diff -u a.txt b.txt');
      expect(
        result.stdout,
        '--- a.txt\t2023-11-14 22:13:20.000000000 +0000\n'
        '+++ b.txt\t2023-11-14 22:13:20.000000000 +0000\n'
        '@@ -1 +1 @@\n'
        '-alpha\n'
        '+beta\n',
      );
    });

    test(
      'sed s///g заменяет все вхождения, без флага — только первое',
      () async {
        final result = await _shell(
          "echo aaa | sed 's/a/b/' && echo aaa | sed 's/a/b/g'",
        );
        expect(result.stdout, 'baa\nbbb\n');
      },
    );

    test('sed -E с обратной ссылкой в замене', () async {
      final result = await _shell("echo abcabc | sed -E 's/(abc)/[\\1]/g'");
      expect(result.stdout, '[abc][abc]\n');
    });

    test('sed с неверной ссылкой в замене — код 1 и сообщение GNU', () async {
      final result = await _shell("echo a | sed 's/a/\\1/'; echo \$?");
      expect(result.stdout, '1\n');
      expect(
        result.stderr,
        contains("invalid reference \\1 on `s' command's RHS"),
      );
    });

    test('realpath выдаёт абсолютный путь без символических ссылок', () async {
      final result = await _shell('ln -s sub link && realpath link/inner.txt');
      expect(result.stdout, '/work/sub/inner.txt\n');
    });

    test('readlink -f раскрывает цепочку ссылок до конца', () async {
      final result = await _shell(
        'ln -s a.txt l1 && ln -s l1 l2 && readlink -f l2',
      );
      expect(result.stdout, '/work/a.txt\n');
    });

    test('ln без -s отказывает в жёсткой ссылке с сообщением', () async {
      final result = await _shell('ln a.txt hard; echo \$?');
      expect(result.stdout, '1\n');
      expect(result.stderr, contains('hard links are not supported'));
    });

    test('chmod -R применяет режим ко всему дереву', () async {
      final result = await _shell(
        'chmod -R 700 sub && stat -c %a sub/inner.txt',
      );
      expect(result.stdout, '700\n');
    });
  });
}
