import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:virtual_host/src/in_memory_vfs_store.dart';
import 'package:virtual_host/src/shell/applets/applet.dart';
import 'package:virtual_host/src/shell/shell_interpreter.dart';
import 'package:virtual_host/src/shell/shell_io.dart';
import 'package:virtual_host/src/vfs_path.dart';
import 'package:virtual_host/src/virtual_fs.dart';
import 'package:virtual_host/src/virtual_limits.dart';
import 'package:virtual_host/src/virtual_profile.dart';

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
  'break; echo after:\$?',
  'continue; echo after:\$?',
  'break abc; echo after:\$?',
  'for i in a b; do echo item:\$i; break 0; echo no; done; echo after:\$?',
  'for i in a b; do for j in 1 2; do echo \$i\$j; break 0; echo no; done; echo mid; done; echo after:\$?',
  'for i in a b; do echo item:\$i; break abc; echo no; done; echo after:\$?',
  'for i in a b; do echo item:\$i; break 2; echo no; done; echo after:\$?',
  'for i in a b; do for j in 1 2; do echo \$i\$j; break 3; echo no; done; echo mid; done; echo after:\$?',
  'for i in a b; do echo item:\$i; continue 0; echo no; done; echo after:\$?',
  'for i in a b; do echo item:\$i; continue abc; echo no; done; echo after:\$?',
  'for i in a b; do echo item:\$i; continue 2; echo no; done; echo after:\$?',
  'for i in a b; do for j in 1 2; do echo \$i\$j; continue 2; echo no; done; echo mid; done; echo after:\$?',
  'while true; do echo once; break; done; echo after:\$?',
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
  // Присваивания, системы счисления, (( )), for (( )), let и массивы.
  r'echo $((10#08)) $((16#ff)) $((010)) $((2#1010))',
  r'x=0; echo $((++x)) $((x++)) $x',
  r'x=4; echo $((x+=3)) $((x*=2)) $x',
  r'x=1 y=$x; echo $y',
  r'((i=2)); echo $? $i',
  r'((0)); echo $?',
  r'((1)); echo $?',
  'for ((i=0; i<3; i++)); do echo \$i; done',
  'let x=3; echo \$? \$x',
  'let 0; echo \$?',
  r'x=(a "b c" d); echo "${x[@]}" ${#x[@]}',
  'x=(a b); x+=(c); echo "\${x[@]}"',
  'x=(a b); x[1]=Z; echo "\${x[@]}"',
  'x=(); echo "[\${x[@]}]" \${#x[@]}',
  'echo \$((1/0)); echo after',
  '((1/0)); echo after \$?',
  'let 1/0; echo after \$?',
  'a[-9]=1; echo after',
  'x=1 >/no/such; echo \$? \$x',
  '( echo \$((1/0)) ); echo after \$?',
  // Условие [[ ]].
  '[[ -f in.txt ]]; echo \$?',
  '[[ -d sub ]]; echo \$?',
  '[[ -s in.txt ]]; echo \$?',
  '[[ -z "" ]]; echo \$?',
  '[[ -n "" ]]; echo \$?',
  '[[ abc == a* ]]; echo \$?',
  "[[ abc == 'a*' ]]; echo \$?",
  '[[ abc != a ]]; echo \$?',
  '[[ 010 -eq 8 ]]; echo \$?',
  '[[ 3 -gt 1 && 0 -eq 1 ]]; echo \$?',
  '[[ a || "" ]]; echo \$?',
  '[[ "" || a ]]; echo \$?',
  '[[ ! -f missing ]]; echo \$?',
  'x=abc; [[ \$x == a* ]]; echo \$?',
  '[[ abc =~ (b)(c) ]]; echo \${BASH_REMATCH[0]}-\${BASH_REMATCH[1]}-\${BASH_REMATCH[2]}',
  '[[ xyz =~ b ]]; echo \$? [\${BASH_REMATCH[0]+no}]',
  '[[ hello < world ]]; echo \$?',
  '[[ world < hello ]]; echo \$?',
  '[[ -f in.txt && -d sub ]]; echo \$?',
  '[[ ( -f missing || -d sub ) ]]; echo \$?',
  '[[ -v HOME ]]; echo \$?',
  '[[ -v NOPE ]]; echo \$?',
  '[[ -o errexit ]]; echo \$?',
  '[[ -r in.txt && -w in.txt && ! -x in.txt ]]; echo \$?',
  // set -e, pipefail, ловушки и $-.
  'echo \$-',
  'set -e; echo \$-',
  'set -e; false; echo after',
  'set -e; false && echo no; echo after',
  'set -e; true && false; echo after',
  'set -e; if false; then echo no; fi; echo after',
  'set -e; if true; then false; fi; echo after',
  'set -e; false || true; echo after',
  'set -e; false | true; echo after',
  'set -eo pipefail; false | true; echo after',
  "trap 'echo ERR' ERR; false; echo after",
  "trap 'echo BYE' EXIT; true",
  "trap 'echo PARENT' EXIT; (trap 'echo SUB' EXIT; true); echo done",
  'set -x; echo hi',
  "f() { false; }; trap 'echo ERR' ERR; f; echo after",
  "set -E; f() { false; }; trap 'echo ERR' ERR; f; echo after",
  "f() { echo in; }; trap 'echo RET' RETURN; f; echo after",
  "set -T; f() { echo in; }; trap 'echo RET' RETURN; f; echo after",
  'set -e; ! false; echo after',
  'echo \$LINENO',
  "echo 'echo sourced' > f.sh; source f.sh; echo after",
  "echo 'echo [\$1]' > f.sh; source f.sh hi; echo \"[\$1]\"",
  "echo 'echo dotted' > f.sh; . ./f.sh",
  "eval 'echo evalled'",
  "eval 'x=4'; echo \$x",
  'declare -i y=010; echo "\$y"; declare -p y',
  'declare -a a; a=(one two); declare -p a',
  'declare -A m; m[k]=v; declare -p m',
  'declare -A b; b=(x); echo \$?; declare -p b',
  'readonly z=3; declare -p z',
  'readonly z=3; z=4; echo after',
  'f() { local -i x=010; echo \$x; }; f',
  "printf -v v '%s-%d' hi 3; echo \"[\$v]\"",
  'hash; echo \$?',
  'command -v cd',
  'f() { echo func; }; command f; echo \$?',
];

/// Раскрытие `${...}`: модификаторы, массивы, позиционные параметры, байты под LC_ALL=C, ошибки и
/// nounset. Каждый скрипт сравнивается с bash -c: stdout, stderr и код выхода.
const _expansionDifferential = [
  // Простые ссылки, длина и отличие пустого значения от неустановленного.
  r'x=hello; echo ${x} $x ${x}2 ${#x} ${#y}',
  r'x=; echo "[${x-d}]" "[${x:-d}]" "[${x+a}]" "[${x:+a}]"',
  r'u=; echo "[${u-d}]" "[${u:-d}]" "[${u+a}]" "[${u:+a}]"',
  r'x=v; echo ${x:-d} ${x:+alt} ${x-d} ${x+alt}',
  // Операнды: кавычки, вложенность, экранирование и подстановки.
  r'x=; echo ${x:-a b} "${x:-a b}" ${x:-"a b"} "${x:-"a"}x"',
  'x=; echo \${x:-\'q r\'} "\${x:-\'q\'}" \${x:-a\\"b c\\"d}',
  r'x=; echo "${x:-~}" ${x:-~}',
  r'x=; y=Y; echo ${x:-$y} ${x:-${y}2} ${x:-${y:-deep}}',
  r'x=; echo ${x:-$(echo q r)} "${x:-$(echo q r)}"',
  r'x=; echo ${x:-\}} ${x:-a\}b}',
  r'x=a; echo ${x}} ${x:-}',
  r'echo ${u:-*.txt} "${u:-*.txt}"',
  r'x=; echo "${x:-\"}" ${x:-"}"}',
  r'x=; echo ${x:-$((1+2))} $((${x:-2}+3))',
  r'x=ab; echo ${x:-{}} ${x:-}}',
  // Присваивание и ошибки в операндах.
  r'echo ${u:=v} $u; echo ${u:=w} $u',
  r'x=; echo "[${x:=w}]" "[$x]"; x=q; echo ${x:=w} $x',
  r'x=; echo "[${x=w}]" "[$x]"; echo ${zz=w} $zz',
  r'echo ${u:?oops}; echo after',
  r'x=; echo ${x:?}; echo after',
  r'echo ${x?}; echo after',
  r'x=; echo "[${x?}]"; echo after',
  r'x=; echo ${x?unset-only}; echo after',
  r'x=; echo ${x:?null msg here}; echo after',
  r'echo a; echo ${u:?} ; echo after',
  r'echo ${u:?"a b"}; echo after',
  r'echo ${u:?$HOME}; echo after',
  r'echo $(echo ${u:?sub}); echo after',
  r'(echo ${u:?}); echo "after $?"',
  r'echo ${u:?} | cat; echo "after $?"',
  r'echo ${u:?} $(echo nope); echo after',
  r'x=abc; echo ${!x:?}; echo after',
  // Позиционные параметры задаются аргументами функции: `set --` здесь не реализован.
  r'f() { echo ${@:2:2} ${@: -2} ${@:0:1} ${*:3}; }; f a b c d',
  r'f() { echo "${@:2:2}" "${*:2:1}" ${@:4:5}; }; f a b c d',
  r'f() { echo "[${@:3}]" "[${@:-x}]" ${#@} ${#*}; }; f a b',
  r'f() { echo "[${@:-x}]" "[${@-x}]" "[${*+y}]" "[${#@}]"; }; f',
  r'f() { echo "[${@^^}]" "[${@}]" "[$*]" "[${*}]"; }; f',
  r'f() { echo ${@^^} ${*/b/X} "${@/b/X}"; }; f ab cd',
  r'f() { echo "${@:-q}" "${1:-q}" "${@#x}" ${@%x}; }; f x',
  r'f() { echo ${!#} ${#} ${@:2:1}${@:1:1}; }; f a b c',
  r'f() { echo ${1:=x} $1; }; f',
  r'f() { echo ${1:=x} $1; }; f y',
  r'f() { echo ${*:=x}; echo after; }; f',
  r'f() { echo ${#@} ${#*} ${#1} ${#3} ${#}; }; f a bb ccc',
  r'x=hello; echo ${x@Q}',
  r'x=abc; echo ${x[0]} ${x[1]} ${x[@]} ${x[*]} ${#x[@]} ${x[0]:1}',
  r'x=abc; echo ${x[1]:-d} ${x[1]-d} ${x[5]:-d}',
  r'x=abc; echo ${!x[@]} ${!x[*]} ${#x[@]}',
  // Срезы: строки, отрицательные смещения и длины.
  r'x=abcdef; echo ${x:2} ${x: -2} ${x:1:3} ${x:(-2)} ${x:10} ${x:2:100} ${x: -9}',
  r'x=abcdef; echo ${x:0} ${x:1:0} ${x:6} ${x: -6:2}',
  r'x=abc; echo ${x:1:-1} ${x: -2:-1}',
  r'x=abc; echo ${x:2:-5}; echo after',
  r'x=abc; echo ${x:-2:1}',
  r'x=; echo "[${x:0:-1}]"; echo after',
  r'echo "[${u:2:-5}]"; echo after',
  // Байты под LC_ALL=C: длина, срезы и образцы считают UTF-8 байты.
  r'x=héllo; echo ${#x} ${x:3} ${x:1:2} ${x:3:3}',
  r'x=привет; echo ${#x} ${x:6} ${x: -4}',
  r'x=日本; echo ${#x} ${x:3:3}',
  r'x=привет; echo ${x#п} ${x%т} ${x#*в} ${x##*е}',
  // Удаление префикса и суффикса.
  r'x=hello; echo ${x#he} ${x##*l} ${x%o} ${x%%l*} ${x#*} ${x%?} ${x#[hH]} ${x##h*}',
  r'x=a/b/c.txt; echo ${x##*/} ${x%/*} ${x%.*} ${x#*.} ${x%%/*}',
  r'x=hello; echo ${x#z} ${x%z} ${x#} ${x%}',
  r'f=a.tar.gz; echo ${f%%.*} ${f%.*} ${f#*.} ${f##*.}',
  r'x="a*b"; echo "${x#"*"}" ${x#\*} ${x%"*"b}',
  r'x=aXbX; echo ${x#*X} ${x##*X} ${x%X*} ${x%%X*}',
  r'u=; echo "[${u#a}]" "[${u%%a}]" "[${#u}]"',
  r'x=hello; echo ${x#"he"} ${x%"lo"} ${x##"h"*}',
  r'x=hello; p=h*; echo ${x#$p} ${x#"$p"} ${x#p}',
  r'x=hello; p=l; echo ${x%$p*} ${x%%$p*}',
  // Замена: первое, все, в начале и в конце; пустой образец и экранирование.
  r'x=hello; echo ${x/l/L} ${x//l/L} ${x/#h/H} ${x/%o/O} ${x/xyz/q} ${x//"l"/-} ${x/l*/M} ${x/ll}',
  r'x=hello; echo ${x/l/} ${x//} ${x/}  ${x/#/P} ${x/%/S} ${x//*/Z}',
  r'x="a*b"; echo ${x/\*/S} ${x//"*"/S} ${x/"*"/T}',
  r'x=a/b/c; echo ${x//\//-} ${x/\//+} ${x//\//}',
  r'x=aaa; echo ${x//a/bb} ${x/a/} ${x/#a/}',
  r'x=hello; echo ${x/[lh]/X} ${x//[!e]/_}',
  r'x=привет; echo ${x/р/R} ${x//и/I} ${x/#п/П}',
  r'x=abc; echo ${x//?/_}',
  r'x=abcabc; echo ${x//b*c/Q} ${x/c*/C}',
  r'x=abc; p=b; r=R; echo ${x/$p/$r} "${x/$p/$r}" ${x/b/"$r"}',
  r'x=abc; echo ${x/b/ two words} "${x/b/ two words}"',
  r'u=; echo "[${u/a/b}]" "[${u//a/}]"',
  r'x=ab; echo ${x/a/${x}}',
  // Регистр: только ASCII, образцы и массивы.
  r'x=hello; echo ${x^} ${x^^} ${x^^[aeiou]} ${x,,H} ${x^^h} ${x,}',
  r'x=HeLLo; echo ${x,,} ${x~} ${x~~} ${x,} ${x^}',
  r'x=HeLLo; echo ${x,,[LE]} ${x^^[lo]} ${x~~[el]}',
  r'x=привет; echo ${x^^} ${x^} ${x,,} ${#x}',
  r'x=éa; echo ${x^^} ${x^} ${x,,}',
  r'u=; echo "[${u^^}]" "[${u,}]" "[${u~~}]"',
  r'x=abc; echo ${x^^b} ${x^b}',
  // Преобразования @Q, @E, @U, @u, @L, @l.
  r'x=hello; echo ${x@Q} ${x@U} ${x@u} ${x@L}',
  "x=\"it's\"; echo \${x@Q}",
  r'x=; echo "[${x@Q}]" "[${x@U}]"',
  r'x="a b"; echo ${x@Q}',
  r'x="a\\tb\\x41\\101"; echo ${x@E}',
  r'x="a\\nb\\e"; echo ${x@E}',
  r'x="p\\\\q"; echo ${x@E} ${x@Q}',
  r'x="a\\qb\\x\\u"; echo ${x@E}',
  r'x="a\\01b"; echo ${x@E}',
  r'x=é; echo ${x@Q} ${x@U}',
  // Недопустимые формы: bad substitution, bad array subscript и косвенность.
  r'echo ${}; echo after',
  r'x=a; echo ${x:}; echo after',
  r'echo ${1x}; echo after',
  r'x="a b"; echo ${!x}; echo after',
  r'x=1; echo ${!x}; y=; echo ${!y}; echo after',
  // Косвенность, имена и ключи.
  r'x=y; y=1; echo ${!x} ${!x:-d} ${!x:+alt}',
  r'x=y; echo ${!x:-d} ${!x-q}; y=; echo "[${!x}]" ${!x:-d}',
  r'a1=1; a2=2; b=3; echo ${!a*} "${!a*}" ${!a@} "${!a@}"',
  r'a1=1; a2=2; b=3; for n in "${!a@}"; do echo "<$n>"; done; for n in "${!a*}"; do echo "<$n>"; done',
  r'x=@; echo "[${!x}]"',
  // read, mapfile, getopts, select, printf и shift.
  r'''printf 'a b c\n' | { read -a arr; echo "${arr[0]}|${arr[1]}|${arr[2]}"; }''',
  r'''printf 'ab' | { read -n 1 x; echo "[$x]"; }''',
  r'''printf 'ab' | { read -n 3 x; echo "[$x] $?"; }''',
  r'''printf 'abc' | { read -n 3 x; echo "[$x] $?"; }''',
  r'''printf 'axb\n' | { read -d x v; echo "[$v] $?"; }''',
  r'''printf 'z\n' | { read -p 'Q:' x; echo "[$x]"; }''',
  r'''printf 'a\nb\n' | { mapfile -t a; echo "${a[0]}|${a[1]}"; }''',
  r'''printf 'a\nb\n' | { mapfile a; printf '[%s]' "${a[0]}" "${a[1]}"; echo; }''',
  r'''while getopts 'ab:' opt -a -b val; do echo "[$opt][$OPTARG][$OPTIND]"; done; echo end:$?''',
  r'''getopts 'a' opt -z; echo "[$opt] $?"''',
  r'''getopts 'a:' opt -a; echo "[$opt] $?"''',
  r'''printf '1\n' | { select x in a b; do echo "var=$x reply=$REPLY"; break; done; }''',
  r'''printf '9\n' | { select x in a b; do echo "var=[$x]"; break; done; }''',
  r'''printf '\n1\n' | { select x in a b; do echo "var=$x"; break; done; }''',
  r'''printf '' | { select x in a b; do echo no; done; }''',
  r'''printf '%q\n' 'a b' "a'b" '' ok''',
  r'''printf '%e\n' 12.5 0.0000125 -12.5 0''',
  r'''printf '%g\n' 12.50 0.0000125 1000000 1.23000''',
  r'''printf '%.2e\n' 12.5''',
  'shift 9; echo after:\$?',
  'set -- a b; shift; echo "\$1 \$#"',
  'set -- a; shift -1; echo \$?',
  'set -- a; shift 0; echo "[\$1] \$?"',
  r'''printf '%q\n' "$(printf 'a\nb')"''',
];

/// Конструкции, которые bash выполняет, а виртуальный shell пока нет. Здесь проверяется только отказ:
/// ни одна команда скрипта не должна выполниться, код выхода — 2. Сравнивать с bash нельзя, потому что
/// он выполнит скрипт.
const _rejected = [
  'echo a; echo a & echo b',
  r'echo a; echo ${x@A}',
  r'echo a; echo ${x@a}',
  r'echo a; echo ${x@P}',
  'echo a; echo a |',
  'echo a; shopt -s lastpipe',
  'echo a; set -o posix',
  'echo a; exec > out',
  'echo a; wait',
  'echo a; kill 1',
  'echo a; umask',
  'echo **',
];

void main() {
  final skip = Platform.isLinux ? false : 'сравнение с bash только на Linux';

  group('сравнение с bash -c', () {
    for (final script in _differential) {
      test('совпадает: ${script.replaceAll('\n', r'\n')}', () async {
        final ours = await _shell(script);
        final real = await _bash(script);
        expect(
          ours.stdout,
          real.stdout,
          reason: 'stderr=${ours.stderr} code=${ours.exitCode}',
        );
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

  group('shift', () {
    test('нечисловой аргумент даёт ошибку и код 2', () async {
      final outcome = await _shell('shift abc; echo after:\$?');

      expect(outcome.stdout, 'after:2\n');
      expect(outcome.stderr, contains('numeric argument required'));
      expect(outcome.exitCode, 0);
    });
  });

  group('раскрытие параметров: сравнение с bash -c', () {
    for (final script in _expansionDifferential) {
      test('совпадает: ${script.replaceAll('\n', r'\n')}', () async {
        final ours = await _shell(script);
        final real = await _bash(script);
        expect(
          ours.stdout,
          real.stdout,
          reason: 'stderr=${ours.stderr} code=${ours.exitCode}',
        );
        expect(ours.stderr, real.stderr);
        expect(ours.exitCode, real.exitCode);
      }, skip: skip);
    }
  });

  group('раскрытие параметров: ошибки', () {
    test(
      '`\${x:?}` печатает сообщение и прерывает скрипт с кодом 127',
      () async {
        final outcome = await _shell('echo a; echo \${x:?нужен x}; echo after');
        expect(outcome.stdout, 'a\n');
        expect(outcome.stderr, 'bash: line 1: x: нужен x\n');
        expect(outcome.exitCode, 127);
      },
    );

    test('`\${x:?}` без сообщения называет причину по-английски', () async {
      final outcome = await _shell(r'x=; echo ${x:?}');
      expect(outcome.stderr, 'bash: line 1: x: parameter null or not set\n');
      expect(outcome.exitCode, 127);
    });

    test('`\${x?}` для неустановленной переменной', () async {
      final outcome = await _shell(r'echo ${x?}');
      expect(outcome.stderr, 'bash: line 1: x: parameter not set\n');
      expect(outcome.exitCode, 127);
    });

    test('номер строки в сообщении указывает на место ошибки', () async {
      final outcome = await _shell('echo ok\necho \${x:?}');
      expect(outcome.stdout, 'ok\n');
      expect(outcome.stderr, 'bash: line 2: x: parameter null or not set\n');
    });

    test(
      'ошибка в подоболочке завершает только её, код 1 как в bash',
      () async {
        final outcome = await _shell(r'(echo ${x:?}); echo "after $?"');
        expect(outcome.stdout, 'after 1\n');
        expect(outcome.exitCode, 0);
      },
    );

    test('ошибка в `\$(...)` не прерывает внешнюю команду', () async {
      final outcome = await _shell(r'echo $(echo ${x:?}); echo "after $?"');
      expect(outcome.stdout, '\nafter 0\n');
      expect(outcome.exitCode, 0);
    });

    test('ошибка в функции прерывает весь скрипт с кодом 127', () async {
      final outcome = await _shell(r'f() { echo ${x:?}; }; f; echo after');
      expect(outcome.stdout, isEmpty);
      expect(outcome.exitCode, 127);
    });

    test('недопустимая форма `\${}` прерывает скрипт с кодом 1', () async {
      final outcome = await _shell(r'echo a; echo ${}; echo after');
      expect(outcome.stdout, 'a\n');
      expect(outcome.stderr, 'bash: line 1: \${}: bad substitution\n');
      expect(outcome.exitCode, 1);
    });

    test(
      '`\${x:=v}` сохраняет значение и видно в следующих командах',
      () async {
        final outcome = await _shell(r'echo ${x:=v} $x; echo $x');
        expect(outcome.stdout, 'v v\nv\n');
        expect(outcome.exitCode, 0);
      },
    );

    test('`\${x@l}` — первый символ в строчный: bash 5.3 такого не знает, здесь это задано ТЗ', () async {
      final outcome = await _shell(r'x=HELLO; echo ${x@l}');
      expect(outcome.stdout, 'hELLO\n');
      expect(outcome.exitCode, 0);
    });

    test('`\${1:=v}` не присваивает позиционному параметру', () async {
      final outcome = await _shell(r'f() { echo ${1:=v}; echo after; }; f');
      expect(outcome.stdout, isEmpty);
      expect(outcome.stderr, 'bash: line 1: \$1: cannot assign in this way\n');
      expect(outcome.exitCode, 1);
    });
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

    test('вложенный eval останавливается лимитом глубины', () async {
      var script = 'echo ok';
      for (var i = 0; i < 9; i++) {
        script = "eval '$script'";
      }
      final outcome = await _shell(script);
      expect(outcome.exitCode, 1);
      expect(outcome.stderr, contains('nesting is deeper than 8'));
    });

    test('область и конвейер остаются быстрыми на большом состоянии', () async {
      final assigns = [for (var i = 0; i < 1000; i++) 'v$i=$i'].join('; ');
      final functions = [for (var i = 0; i < 100; i++) 'f$i() { :; }']
          .join('\n');
      final pipe = List.filled(10, 'true').join(' | ');
      final watch = Stopwatch()..start();
      final outcome = await _shell(
        '$assigns\n$functions\n$pipe',
        limits: const VirtualLimits(
          maxCommandLength: 200000,
          maxCommandsPerRun: 5000,
        ),
      );
      watch.stop();
      expect(outcome.exitCode, 0);
      expect(watch.elapsedMilliseconds, lessThan(2000));
    });

    test('fork bomb отвергается до запуска команд', () async {
      final classic = await _shell(':(){ :|:& };:');
      expect(classic.stdout, isEmpty);
      expect(classic.exitCode, 2);
      final background = await _shell('f() { f | f & }; f');
      expect(background.stdout, isEmpty);
      expect(background.exitCode, 2);
      expect(background.stderr, contains('unsupported syntax'));
    });

    test('рекурсия функции останавливается лимитом команд', () async {
      final outcome = await _shell(
        'f() { f; }; f',
        limits: const VirtualLimits(maxCommandsPerRun: 50),
      );
      expect(outcome.exitCode, 1);
      expect(outcome.stderr, contains('too many commands in one run'));
    });

    test('ошибка в `\$((...))` прерывает скрипт, как в bash', () async {
      final outcome = await _shell('echo \$((1/0)); echo ok');
      expect(outcome.stdout, isEmpty);
      expect(outcome.stderr, contains('division by 0'));
      expect(outcome.exitCode, 1);
    });

    test('параметры верхнего уровня пусты', () async {
      final outcome = await _shell(r'echo "[$1][$#]"');
      expect(outcome.stdout, '[][0]\n');
    });

    test('`break` вне цикла предупреждает и не прерывает скрипт', () async {
      final outcome = await _shell('break; echo after');
      expect(outcome.stdout, 'after\n');
      expect(
        outcome.stderr,
        "bash: line 1: break: only meaningful in a `for', `while', or `until' loop\n",
      );
      expect(outcome.exitCode, 0);
    });

    test('`continue` вне цикла предупреждает так же, как `break`', () async {
      final outcome = await _shell('continue; echo after');
      expect(outcome.stdout, 'after\n');
      expect(
        outcome.stderr,
        "bash: line 1: continue: only meaningful in a `for', `while', or `until' loop\n",
      );
      expect(outcome.exitCode, 0);
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

  group('каталоги', () {
    test('pushd и popd печатают стек и возвращают каталог', () async {
      final outcome = await _shell('cd sub; pushd ..; popd');
      expect(outcome.exitCode, 0);
      expect(outcome.stdout, '/work /work/sub\n/work/sub\n');
    });
  });

  group('функции', () {
    test('declare -f печатает тело, которое снова выполняется', () async {
      final printed = await _shell(r'f() { echo "$1"; }; declare -f f');
      expect(printed.exitCode, 0);
      final again = await _shell('${printed.stdout}\nf hi');
      expect(again.stdout, 'hi\n');
      expect(again.exitCode, 0);
    });

    test('declare -F печатает имя, отсутствующая функция даёт код 1', () async {
      final outcome = await _shell(
        'f() { echo a; }; declare -F f; declare -F missing; echo \$?',
      );
      expect(outcome.stdout, 'declare -f f\n1\n');
      expect(outcome.stderr, contains('declare: missing: not found'));
    });

    test('type различает функцию, встроенную команду и апплет', () async {
      final outcome = await _shell(
        'f() { echo a; }; type cd; type echo; type missing; echo \$?',
      );
      expect(outcome.stdout, 'cd is a shell builtin\necho is /bin/echo\n1\n');
      expect(outcome.stderr, contains('type: missing: not found'));
      final typed = await _shell('f() { echo a; }; type f');
      expect(typed.stdout, startsWith('f is a function\n'));
      final rerun = await _shell(
        '${typed.stdout.replaceFirst('f is a function\n', '')}\nf',
      );
      expect(rerun.stdout, 'a\n');
    });
  });

  group('отмена потока', () {
    for (final signal in ['INT', 'TERM']) {
      final code = signal == 'TERM' ? '143' : '130';
      test(
        'отписка запускает $signal и завершает запуск с кодом $code',
        () async {
          final fs = VirtualFs(InMemoryVfsStore(), clock: () => 1700000000);
          await fs.mkdir(_workdir, recursive: true);
          final interpreter = ShellInterpreter(
            fs: fs,
            applets: _registry,
            profile: const VirtualProfile(home: _workdir),
          );
          late final StreamSubscription<ShellEvent> sub;
          sub = interpreter
              .run(
                "trap 'echo HIT > sig' $signal\n"
                "trap 'echo \$? > code' EXIT\n"
                'echo READY\n'
                'while true; do echo x; done\n',
                cwd: _workdir,
                cancelSignal: signal,
              )
              .listen((event) {
                if (event is ShellStdout) sub.cancel();
              });
          String? written;
          for (var i = 0; i < 20 && written == null; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
            try {
              written = utf8.decode(await fs.readBytes('$_workdir/code'));
            } on VfsException {
              written = null;
            }
          }
          await sub.cancel();
          expect(utf8.decode(await fs.readBytes('$_workdir/sig')), 'HIT\n');
          expect(written, '$code\n');
        },
      );
    }
  });
}
