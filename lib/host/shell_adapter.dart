import 'dart:convert';

import 'package:probably_works/core/domain/host.dart';
import 'package:probably_works/core/util/shell_quote.dart';

/// Командные билдеры host-инструментов по ОС. Файловые операции — это команды,
/// а не методы рантайма.
class ShellAdapter {
  const ShellAdapter(this.os);

  final HostOs os;

  bool get _windows => os == HostOs.windows;

  String hostInfo() => _windows
      ? powershell('$_consoleUtf8$_hostInfoPs')
      : 'uname -a 2>/dev/null; echo "user=\$(id -un 2>/dev/null)"; echo "cwd=\$(pwd)"; echo "shell=\${SHELL:-sh}"';

  static const _hostInfoPs = r'''
'os=' + [Environment]::OSVersion.VersionString
'user=' + [Environment]::UserName
'cwd=' + (Get-Location).Path
''';

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

  /// Список каталога. На Windows через PowerShell: `dir` пишет имена в OEM-кодировке, а не в UTF-8.
  String listDir(String path) => _windows
      ? powershell(
          '$_consoleUtf8${_listDirPs.replaceAll('__PATH__', psQuote(path))}',
        )
      : 'ls -la -- ${quotePath(path)}';

  static const _listDirPs = r'''
Get-ChildItem -Force -LiteralPath __PATH__ -ErrorAction Stop |
  ForEach-Object { '{0} {1,12} {2}' -f $_.LastWriteTime.ToString('yyyy-MM-dd HH:mm'), $(if ($_.PSIsContainer) { '<dir>' } else { $_.Length }), $_.Name }
''';

  /// Чтение текстового файла по строкам. Вывод: заголовок с числом строк и байтов, строки с номерами
  /// и хвост с точными аргументами продолжения. Строки и байты считает сам Host, поэтому файл любого
  /// размера читается без загрузки целиком в модель. Бинарные файлы (есть байт NUL) не читаются.
  ///
  /// Курсор: строка [offset] (с 1), не больше [limit] строк и [chunkBytes] байтов за вызов.
  /// Строка длиннее [lineBytes] режется; продолжение — через [byteOffset] (байт внутри строки [offset]).
  /// Ошибки скрипта read_file. Текст одинаковый на POSIX и Windows, и парсер вывода узнаёт его по этим строкам.
  static const readFileNotReadableMessage = 'not a readable regular file';
  static const readFileBinaryMessage = 'binary file, cannot be read as text';

  /// Границы символов UTF-8 соблюдаются, поэтому курсор всегда указывает на начало символа.
  String readFile(
    String path, {
    required int offset,
    required int byteOffset,
    required int limit,
    required int chunkBytes,
    required int lineBytes,
  }) {
    if (_windows) {
      final script = _readFilePs
          .replaceAll('__PATH__', psQuote(path))
          .replaceAll('__OFFSET__', '$offset')
          .replaceAll('__BYTEOFFSET__', '$byteOffset')
          .replaceAll('__LIMIT__', '$limit')
          .replaceAll('__CHUNKBYTES__', '$chunkBytes')
          .replaceAll('__LINEBYTES__', '$lineBytes')
          .replaceAll('__NOTREADABLE__', readFileNotReadableMessage)
          .replaceAll('__BINARY__', readFileBinaryMessage);
      return powershell(script);
    }
    final p = quotePath(path);
    return 'if [ ! -f $p ] || [ ! -r $p ]; then echo "$readFileNotReadableMessage" >&2; false; '
        "elif LC_ALL=C tr -d '\\000' < $p | cmp -s - $p; then "
        'LC_ALL=C awk -v off=$offset -v boff=$byteOffset -v lim=$limit '
        '-v chunk=$chunkBytes -v lcap=$lineBytes -v size="\$(wc -c < $p)" '
        "'$_readFileAwk' $p; "
        'else echo "$readFileBinaryMessage" >&2; false; fi';
  }

  /// Тот же алгоритм, что и в [_readFilePs]: байтовый курсор, режим LC_ALL=C.
  static const _readFileAwk = r'''
BEGIN {
  for (i = 128; i < 192; i++) cont[sprintf("%c", i)] = 1
  nextLine = off; nextByte = boff; nextLen = 0
}
NR < off || stop { next }
{
  line = $0; len = length(line); b = (NR == off) ? boff : 0
  while (b < len && (substr(line, b + 1, 1) in cont)) b++
  rest = len - b; take = 0
  if (rest > 0) {
    take = rest
    if (take > lcap) take = lcap
    if (take > chunk - used) take = chunk - used
    if (b + take < len) {
      while (take > 0 && (substr(line, b + take + 1, 1) in cont)) take--
    }
    if (take <= 0) { stop = 1; next }
  }
  prefix = (b == 0) ? NR ": " : NR " (from byte " b "): "
  out = out prefix substr(line, b + 1, take) "\n"
  used += take; shown++
  if (b + take < len) {
    nextLine = NR; nextByte = b + take; nextLen = len; stop = 1
  } else {
    nextLine = NR + 1; nextByte = 0
    if (shown >= lim || used >= chunk) stop = 1
  }
}
END {
  printf "[file: %d lines, %d bytes]\n", NR, size + 0
  if (off > NR) { printf "[offset %d is beyond the end of the file (%d lines)]\n", off, NR; exit }
  printf "%s", out
  if (nextLine > NR) print "[end of file]"
  else if (nextByte == 0) printf "[more: continue with offset=%d]\n", nextLine
  else printf "[line %d is cut at byte %d of %d bytes: continue with offset=%d byte_offset=%d]\n", nextLine, nextByte, nextLen, nextLine, nextByte
}
''';

  static const _readFilePs = r'''
$p = __PATH__
if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { [Console]::Error.WriteLine('__NOTREADABLE__'); exit 1 }
$d = [IO.File]::ReadAllBytes($p)
if ([Array]::IndexOf($d, [byte]0) -ge 0) { [Console]::Error.WriteLine('__BINARY__'); exit 1 }
$off = __OFFSET__; $boff = __BYTEOFFSET__; $lim = __LIMIT__; $chunk = __CHUNKBYTES__; $lcap = __LINEBYTES__
$n = $d.Length
$enc = [Text.Encoding]::UTF8
$body = New-Object IO.MemoryStream
$lineNo = 0; $pos = 0; $used = 0; $shown = 0; $stop = $false
$nextLine = $off; $nextByte = 0; $nextLen = 0
while ($pos -lt $n) {
  $i = [Array]::IndexOf($d, [byte]10, $pos)
  $e = if ($i -lt 0) { $n } else { $i }
  $s = $pos; $pos = $e + 1; $lineNo++
  if ($lineNo -lt $off -or $stop) { continue }
  $len = $e - $s
  $b = if ($lineNo -eq $off) { $boff } else { 0 }
  if ($b -gt $len) { $b = $len }
  while ($b -lt $len -and (($d[$s + $b] -band 0xC0) -eq 0x80)) { $b++ }
  $rest = $len - $b; $take = 0
  if ($rest -gt 0) {
    $take = [Math]::Min([Math]::Min($rest, $lcap), $chunk - $used)
    if ($b + $take -lt $len) {
      while ($take -gt 0 -and (($d[$s + $b + $take] -band 0xC0) -eq 0x80)) { $take-- }
    }
    if ($take -le 0) { $stop = $true; continue }
  }
  $prefix = if ($b -eq 0) { "$lineNo: " } else { "$lineNo (from byte $b): " }
  $pb = $enc.GetBytes($prefix); $body.Write($pb, 0, $pb.Length)
  $body.Write($d, $s + $b, $take); $body.WriteByte(10)
  $used += $take; $shown++
  if ($b + $take -lt $len) {
    $nextLine = $lineNo; $nextByte = $b + $take; $nextLen = $len; $stop = $true
  } else {
    $nextLine = $lineNo + 1; $nextByte = 0
    if ($shown -ge $lim -or $used -ge $chunk) { $stop = $true }
  }
}
$total = $lineNo
$out = New-Object IO.MemoryStream
function Put([string]$t) { $bytes = $enc.GetBytes($t); $out.Write($bytes, 0, $bytes.Length) }
Put "[file: $total lines, $n bytes]`n"
if ($off -gt $total) {
  Put "[offset $off is beyond the end of the file ($total lines)]`n"
} else {
  $arr = $body.ToArray(); $out.Write($arr, 0, $arr.Length)
  if ($nextLine -gt $total) { Put "[end of file]`n" }
  elseif ($nextByte -eq 0) { Put "[more: continue with offset=$nextLine]`n" }
  else { Put "[line $nextLine is cut at byte $nextByte of $nextLen bytes: continue with offset=$nextLine byte_offset=$nextByte]`n" }
}
$o = [Console]::OpenStandardOutput()
$bytes = $out.ToArray(); $o.Write($bytes, 0, $bytes.Length); $o.Flush()
''';

  String readFileOrEmpty(String path) => _windows
      ? 'type ${_winPath(path)}'
      : 'cat -- ${quotePath(path)} 2>/dev/null';

  /// Поиск по содержимому: `file:line:text`, не больше 300 строк. Хвост сообщает, что результаты обрезаны.
  /// Каталог `.git` пропускается. Регистр учитывается на обеих ОС; регулярное выражение — грубо
  /// то же (BRE на POSIX, .NET на Windows).
  String grep(String pattern, String path) {
    if (_windows) {
      return powershell(
        '$_consoleUtf8${_grepPs.replaceAll('__PATH__', psQuote(path)).replaceAll('__PATTERN__', psQuote(pattern))}',
      );
    }
    final p = quotePath(path);
    return 'if [ ! -e $p ]; then echo "no such file or directory" >&2; false; else '
        'grep -rIn --exclude-dir=.git -m 200 -e ${shQuote(pattern)} -- $p 2>/dev/null '
        "| awk 'NR <= 300 { print } NR == 301 { print \"[more matches not shown: narrow the pattern or path]\" }'; fi";
  }

  static const _grepPs = r'''
if (-not (Test-Path -LiteralPath __PATH__)) { [Console]::Error.WriteLine('no such file or directory'); exit 1 }
$r = @(Get-ChildItem -LiteralPath __PATH__ -Recurse -File -Force -ErrorAction SilentlyContinue |
  Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' } |
  Select-String -Pattern __PATTERN__ -CaseSensitive -ErrorAction SilentlyContinue |
  Select-Object -First 301)
$r | Select-Object -First 300 | ForEach-Object { '{0}:{1}:{2}' -f $_.Path, $_.LineNumber, $_.Line }
if ($r.Count -gt 300) { '[more matches not shown: narrow the pattern or path]' }
''';

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

  /// mtime: секунды на POSIX, тики на Windows. На POSIX `-L`: для симлинка берётся mtime цели, а не ссылки.
  String statMtime(String path) => _windows
      ? powershell(
          '(Get-Item -LiteralPath ${psQuote(path)}).LastWriteTimeUtc.Ticks',
        )
      : _posixMtime(quotePath(path));

  String _posixMtime(String target) =>
      'stat -L -c %Y -- $target 2>/dev/null || stat -L -f %m -- $target';

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

  /// Запись файла. Содержимое передаётся на stdin процесса (см. `HostRuntime.run`), а не в команде,
  /// поэтому размер файла ограничен только местом на диске и памятью.
  ///
  /// Защиты: [expectedMtime] — значение [statMtime], снятое ДО чтения файла. Если файл изменился
  /// (например, пока пользователь подтверждал правку), запись не выполняется. null означает,
  /// что файла не должно быть. Старая версия копируется в [backupPath]; если копия не создалась,
  /// запись тоже не выполняется.
  String writeFile(
    String path, {
    required String backupPath,
    String? expectedMtime,
  }) {
    if (_windows) {
      final target = path.replaceAll('/', '\\');
      final cut = target.lastIndexOf('\\');
      final dir = cut <= 0 ? '.' : target.replaceRange(cut, null, '');
      final guard = expectedMtime == null
          ? _psAbsentGuard
          : _psMtimeGuard.replaceAll('__MTIME__', expectedMtime);
      return powershell(
        _writeFilePs
            .replaceAll('__GUARD__', guard)
            .replaceAll('__TARGET__', psQuote(target))
            .replaceAll('__DIR__', psQuote(dir))
            .replaceAll(
              '__BACKUP__',
              psQuote(backupPath.replaceAll('/', '\\')),
            ),
      );
    }
    return _posixWrite(
      path,
      backupPath: backupPath,
      expectedMtime: expectedMtime,
    );
  }

  /// Атомарная запись: содержимое пишется во временный файл в каталоге цели, затем `mv` подменяет цель
  /// целиком. Новый inode, и при обрыве записи цель не обрезается. Симлинк разрешается, запись идёт
  /// в его цель, сама ссылка остаётся. Права и владелец переносятся с оригинала. Жёсткие ссылки
  /// не поддерживаются: `mv` отвязал бы их от файла, поэтому запись отказывается.
  /// Проверка mtime выполняется дважды: до бэкапа и непосредственно перед `mv`.
  String _posixWrite(
    String path, {
    required String backupPath,
    String? expectedMtime,
  }) {
    final p = quotePath(path);
    final b = quotePath(backupPath);
    final targetMtime = _posixMtime(r'"$T"');
    final check = expectedMtime == null
        ? r'[ ! -e "$T" ] || fail "file appeared after it was read"'
        : '[ -f "\$T" ] && [ "\$($targetMtime)" = ${shQuote(expectedMtime)} ] || fail "file changed after it was read"';
    return [
      r'fail() { echo "$1; nothing was written" >&2; exit 1; }',
      'meta=',
      'T=$p',
      r'if [ -L "$T" ]; then T=$(readlink -f -- "$T") && [ -n "$T" ] || fail "cannot resolve the symbolic link"; fi',
      r'mkdir -p -- "$(dirname -- "$T")" || fail "cannot create the directory"',
      'check() { $check; }',
      'check',
      r'if [ -f "$T" ]; then',
      r'  [ -w "$T" ] || fail "file is not writable"',
      r'  [ "$(stat -c %h -- "$T" 2>/dev/null || stat -f %l -- "$T")" = 1 ] || fail "file has other hard links, and an atomic write would break them"',
      r'  meta=$(stat -c %a:%u:%g -- "$T" 2>/dev/null || stat -f %Lp:%u:%g -- "$T") || fail "cannot read the file attributes"',
      '  cp -p -- "\$T" $b || fail "backup failed"',
      'fi',
      r'tmp=$(dirname -- "$T")/.$(basename -- "$T").pw-tmp.$$',
      r'''trap 'rm -f -- "$tmp"' EXIT''',
      r'( set -C; cat > "$tmp" ) || fail "cannot create the temporary file (the directory is not writable or the disk is full)"',
      r'if [ -n "$meta" ]; then',
      r'  mode=${meta%%:*}; rest=${meta#*:}; uid=${rest%%:*}; gid=${meta##*:}',
      r'  chmod "$mode" -- "$tmp" || fail "cannot set the file mode"',
      r'  [ "$(stat -c %u:%g -- "$tmp" 2>/dev/null || stat -f %u:%g -- "$tmp")" = "$uid:$gid" ] || chown "$uid:$gid" -- "$tmp" || fail "cannot keep the file owner"',
      'fi',
      'check',
      r'mv -f -- "$tmp" "$T" || fail "cannot replace the file (permissions or sticky directory)"',
    ].join('\n');
  }

  static const _psAbsentGuard =
      r'''if (Test-Path -LiteralPath $p) { [Console]::Error.WriteLine('file appeared after it was read; nothing was written'); exit 1 }''';

  static const _psMtimeGuard =
      r'''if (-not (Test-Path -LiteralPath $p -PathType Leaf) -or (Get-Item -LiteralPath $p).LastWriteTimeUtc.Ticks -ne __MTIME__) { [Console]::Error.WriteLine('file changed after it was read; nothing was written'); exit 1 }''';

  /// Атомарная запись: временный файл в каталоге цели, затем File.Replace (старая версия уходит
  /// в бэкап, права и ACL цели сохраняются) или File.Move для нового файла.
  static const _writeFilePs = r'''
$p = __TARGET__
$dir = __DIR__
$tmp = Join-Path $dir ('.' + [IO.Path]::GetFileName($p) + '.pw-tmp.' + [Guid]::NewGuid().ToString('N'))
__GUARD__
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$in = [Console]::OpenStandardInput()
$ms = New-Object IO.MemoryStream
$in.CopyTo($ms)
try {
  [IO.File]::WriteAllBytes($tmp, $ms.ToArray())
  __GUARD__
  if (Test-Path -LiteralPath $p -PathType Leaf) { [IO.File]::Replace($tmp, $p, __BACKUP__) } else { [IO.File]::Move($tmp, $p) }
} finally {
  if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}
''';

  String _winPath(String value) => '"${value.replaceAll('"', '')}"';
}
