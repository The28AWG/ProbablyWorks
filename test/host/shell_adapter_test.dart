import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:probably_works/core/domain/host.dart';
import 'package:probably_works/host/shell_adapter.dart';

/// Декодирует строку `powershell ... -EncodedCommand <base64>` обратно в текст скрипта (UTF-16LE).
String _decodePowershell(String line) {
  final bytes = base64.decode(line.split(' ').last);
  final units = [
    for (var i = 0; i < bytes.length; i += 2) bytes[i] | (bytes[i + 1] << 8),
  ];
  return String.fromCharCodes(units);
}

void main() {
  group('posix', () {
    const sh = ShellAdapter(HostOs.posix);

    test('~ раскрывается через HOME, а не берётся буквально', () {
      expect(sh.quotePath('~'), '"\$HOME"');
      expect(sh.quotePath('~/my proj'), '"\$HOME"/\'/my proj\'');
    });

    test('обычный путь квотируется одинарными кавычками', () {
      expect(sh.quotePath('/tmp/a b'), "'/tmp/a b'");
    });

    test('cd экранирует апостроф в пути', () {
      expect(sh.cd("/tmp/it's here"), "cd '/tmp/it'\\''s here'");
    });

    test('cd в домашний каталог использует HOME', () {
      expect(sh.cd('~/proj'), 'cd "\$HOME"/\'/proj\'');
    });
  });

  group('windows', () {
    const cmd = ShellAdapter(HostOs.windows);

    test('cd использует синтаксис cmd с /d', () {
      expect(cmd.cd(r'C:\Users\me\proj'), 'cd /d "C:\\Users\\me\\proj"');
    });

    test('PowerShell-скрипт кодируется в UTF-16LE без потерь', () {
      const script = "Write-Output 'привет \$x'";
      final line = cmd.powershell(script);
      expect(
        line,
        startsWith('powershell -NoProfile -NonInteractive -EncodedCommand '),
      );
      expect(_decodePowershell(line), script);
    });

    test('statMtime и writeFile идут через EncodedCommand, а не через POSIX-кавычки', () {
      expect(
        cmd.statMtime(r'C:\proj\AGENTS.md'),
        startsWith('powershell -NoProfile -NonInteractive -EncodedCommand '),
      );
      final write = cmd.writeFile(
        r'C:\proj\a.txt',
        backupPath: r'C:\proj\a.txt.bak',
        expectedMtime: '123',
      );
      final script = _decodePowershell(write);
      expect(script, contains("'C:\\proj\\a.txt'"));
      expect(script, contains("'C:\\proj'"));
      expect(script, contains("'C:\\proj\\a.txt.bak'"));
      expect(script, contains('-ne 123'));
      expect(script, contains('OpenStandardInput'));
    });

    test('scanSkills и readHead читают UTF-8 через PowerShell', () {
      expect(
        _decodePowershell(cmd.readHead(r'C:\x\SKILL.md', maxBytes: 10)),
        contains('UTF8'),
      );
      expect(
        _decodePowershell(cmd.scanSkills([r'C:\x\skills'], maxBytes: 10)),
        contains('@@@ '),
      );
    });
  });
}
