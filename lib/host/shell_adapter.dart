import 'dart:convert';

import 'package:probably_works/core/domain/host.dart';
import 'package:probably_works/core/util/char_substring.dart';
import 'package:probably_works/core/util/shell_quote.dart';

/// Командные билдеры host-инструментов по ОС. Файловые операции — это команды,
/// а не методы рантайма.
class ShellAdapter {
  const ShellAdapter(this.os);

  final HostOs os;

  bool get _windows => os == HostOs.windows;

  String hostInfo() => _windows
      ? 'ver & whoami & cd'
      : 'uname -a 2>/dev/null; echo "user=\$(id -un 2>/dev/null)"; echo "cwd=\$(pwd)"; echo "shell=\${SHELL:-sh}"';

  /// Квотирование пути для posix: `~` и `~/...` раскрываются через `$HOME`, остальное — в одинарных кавычках.
  String quotePath(String value) {
    if (value == '~') return '"\$HOME"';
    if (value.startsWith('~/')) {
      return '"\$HOME"/${shQuote(value.replaceFirst('~', ''))}';
    }
    return shQuote(value);
  }

  /// Смена каталога: `cd /d "..."` в cmd, `cd` с раскрытием `~` в posix.
  String cd(String path) =>
      _windows ? 'cd /d ${_winPath(path)}' : 'cd ${quotePath(path)}';

  String listDir(String path) =>
      _windows ? 'dir ${_winPath(path)}' : 'ls -la -- ${quotePath(path)}';

  String readFile(String path, {required int maxBytes}) => _windows
      ? 'type ${_winPath(path)}'
      : 'head -c $maxBytes -- ${quotePath(path)}';

  String readFileOrEmpty(String path) => _windows
      ? 'type ${_winPath(path)}'
      : 'cat -- ${quotePath(path)} 2>/dev/null';

  String grep(String pattern, String path) => _windows
      ? 'findstr /s /n /i ${_winPath(pattern)} ${_winPath(path)}\\*'
      : 'grep -rIn -m 200 -e ${shQuote(pattern)} -- ${quotePath(path)} 2>/dev/null | head -n 300';

  String which(String name) =>
      _windows ? 'where ${_winPath(name)}' : 'command -v ${shQuote(name)}';

  /// Первые [maxBytes] файла. На Windows читает текст в UTF-8 и обрезает по символам.
  String readHead(String path, {required int maxBytes}) => _windows
      ? powershell(
          '$_consoleUtf8'
          '\$t = [IO.File]::ReadAllText(${psQuote(path)}); '
          'if (\$t.Length -gt $maxBytes) { \$t = \$t.Substring(0, $maxBytes) }; '
          '[Console]::Out.Write(\$t)',
        )
      : 'head -c $maxBytes -- ${quotePath(path)}';

  /// Тела SKILL.md из каталогов skills. Формат вывода: `@@@ <путь>` и затем текст файла.
  String scanSkills(List<String> dirs, {required int maxBytes}) {
    if (_windows) {
      final list = [for (final d in dirs) psQuote(d)].join(',');
      return powershell(
        '$_consoleUtf8'
        'foreach (\$d in @($list)) { '
        'if (Test-Path -LiteralPath \$d -PathType Container) { '
        'Get-ChildItem -LiteralPath \$d -Directory -ErrorAction SilentlyContinue | ForEach-Object { '
        '\$f = Join-Path \$_.FullName "SKILL.md"; '
        'if (Test-Path -LiteralPath \$f -PathType Leaf) { '
        '\$t = [IO.File]::ReadAllText(\$f); '
        'if (\$t.Length -gt $maxBytes) { \$t = \$t.Substring(0, $maxBytes) }; '
        '[Console]::Out.Write("@@@ " + \$f + "`n" + \$t + "`n") } } } }',
      );
    }
    final globs = [for (final dir in dirs) '${quotePath(dir)}/*/SKILL.md']
        .join(' ');
    return 'for f in $globs; do [ -f "\$f" ] && { echo "@@@ \$f"; head -c $maxBytes "\$f"; echo; }; done';
  }

  static const _consoleUtf8 =
      '[Console]::OutputEncoding = [Text.Encoding]::UTF8; ';

  String statMtime(String path) => _windows
      ? powershell(
          '(Get-Item -LiteralPath ${psQuote(path)}).LastWriteTimeUtc.Ticks',
        )
      : 'stat -c %Y -- ${quotePath(path)} 2>/dev/null || stat -f %m -- ${quotePath(path)}';

  /// PowerShell-скрипт в `-EncodedCommand` (UTF-16LE, base64): не зависит от кавычек cmd и shell.
  String powershell(String script) {
    final units = script.codeUnits;
    final bytes = <int>[];
    for (final unit in units) {
      bytes
        ..add(unit & 0xff)
        ..add(unit >> 8);
    }
    return 'powershell -NoProfile -NonInteractive -EncodedCommand ${base64.encode(bytes)}';
  }

  /// Запись файла через base64 (безопасно для любых байтов). Старый файл копируется в backup.
  String writeFile(String path, String content, {required String backupPath}) {
    final encoded = base64.encode(utf8.encode(content));
    if (_windows) {
      final target = path.replaceAll('/', '\\');
      final cut = target.lastIndexOf('\\');
      final dir = cut <= 0 ? '.' : target.replaceRange(cut, null, '');
      return powershell(
        'New-Item -ItemType Directory -Force -Path ${psQuote(dir)} | Out-Null; '
        'if (Test-Path -LiteralPath ${psQuote(target)}) { '
        'Copy-Item -LiteralPath ${psQuote(target)} -Destination ${psQuote(backupPath.replaceAll('/', '\\'))} }; '
        '[IO.File]::WriteAllBytes(${psQuote(target)}, [Convert]::FromBase64String(${psQuote(encoded)}))',
      );
    }
    final dir = _dirname(path);
    return 'mkdir -p -- ${quotePath(dir)} && '
        '{ [ -f ${quotePath(path)} ] && cp -p -- ${quotePath(path)} ${quotePath(backupPath)} || true; } && '
        'printf %s ${shQuote(encoded)} | { base64 -d 2>/dev/null || base64 -D; } > ${quotePath(path)}';
  }

  String _winPath(String value) => '"${value.replaceAll('"', '')}"';

  String _dirname(String path) {
    final index = path.lastIndexOf('/');
    return index <= 0 ? '.' : charRange(path, 0, index);
  }
}
