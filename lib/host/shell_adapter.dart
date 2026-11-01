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

  String listDir(String path) =>
      _windows ? 'dir ${_winPath(path)}' : 'ls -la -- ${shQuote(path)}';

  String readFile(String path, {required int maxBytes}) => _windows
      ? 'type ${_winPath(path)}'
      : 'head -c $maxBytes -- ${shQuote(path)}';

  String readFileOrEmpty(String path) => _windows
      ? 'type ${_winPath(path)}'
      : 'cat -- ${shQuote(path)} 2>/dev/null';

  String fileExists(String path) => _windows
      ? 'if exist ${_winPath(path)} echo yes'
      : '[ -f ${shQuote(path)} ] && echo yes';

  String grep(String pattern, String path) => _windows
      ? 'findstr /s /n /i ${_winPath(pattern)} ${_winPath(path)}\\*'
      : 'grep -rIn -m 200 -e ${shQuote(pattern)} -- ${shQuote(path)} 2>/dev/null | head -n 300';

  String which(String name) =>
      _windows ? 'where ${_winPath(name)}' : 'command -v ${shQuote(name)}';

  String statMtime(String path) => _windows
      ? 'powershell -NoProfile -Command ${shQuote('(Get-Item ${psQuoteLocal(path)}).LastWriteTimeUtc.Ticks')}'
      : 'stat -c %Y -- ${shQuote(path)} 2>/dev/null || stat -f %m -- ${shQuote(path)}';

  /// Запись файла через base64 (безопасно для любых байтов). Старый файл копируется в backup.
  String writeFile(String path, String content, {required String backupPath}) {
    final encoded = base64.encode(utf8.encode(content));
    if (_windows) {
      return 'powershell -NoProfile -Command ${shQuote("if (Test-Path ${psQuoteLocal(path)}) { Copy-Item ${psQuoteLocal(path)} ${psQuoteLocal(backupPath)} }; "
      '[IO.File]::WriteAllBytes(${psQuoteLocal(path)}, [Convert]::FromBase64String(${psQuoteLocal(encoded)}))')}';
    }
    final dir = _dirname(path);
    return 'mkdir -p -- ${shQuote(dir)} && '
        '{ [ -f ${shQuote(path)} ] && cp -p -- ${shQuote(path)} ${shQuote(backupPath)} || true; } && '
        'printf %s ${shQuote(encoded)} | { base64 -d 2>/dev/null || base64 -D; } > ${shQuote(path)}';
  }

  String _winPath(String value) => '"${value.replaceAll('"', '')}"';

  String _dirname(String path) {
    final index = path.lastIndexOf('/');
    return index <= 0 ? '.' : charRange(path, 0, index);
  }

  static String psQuoteLocal(String value) => psQuote(value);
}
