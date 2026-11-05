import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:virtual_host/src/shell/applets/applet.dart';
import 'package:virtual_host/src/shell/applets/applet_args.dart';
import 'package:virtual_host/src/shell/shell_io.dart';

/// Кодирование и контрольные суммы: `base64`, `md5sum`, `sha256sum`. Хэши берутся из пакета `crypto`
/// (проверен через Sonatype: без известных уязвимостей), сами алгоритмы здесь не реализованы.
final List<Applet> codecApplets = [
  const _Base64(),
  _Digest('md5sum', (bytes) => md5.convert(bytes)),
  _Digest('sha256sum', (bytes) => sha256.convert(bytes)),
];

/// `base64 [-d] [-w N] [FILE]`: кодирует строками по N символов (76 по умолчанию, 0 — без переносов).
/// `-d` декодирует, пробельные символы игнорируются, как у GNU. Ошибка данных — код 1.
final class _Base64 implements Applet {
  const _Base64();

  static const _defaultWrap = 76;

  @override
  String get name => 'base64';

  @override
  Future<int> run(AppletIo io, List<String> args) async {
    final parsed = parseArgs(args, flags: 'd', valued: 'w');
    if (parsed.error != null) return usageError(io, name, parsed.error!);
    final wrapText = parsed.value('w');
    final wrap = wrapText == null ? _defaultWrap : int.tryParse(wrapText);
    if (wrap == null || wrap < 0) {
      io.stderr.writeText("base64: invalid wrap size: '$wrapText'\n");
      return 1;
    }
    final operand = parsed.operands.isEmpty ? '-' : parsed.operands.first;
    final bytes = await readSource(io, name, operand);
    if (bytes == null) return 1;

    if (parsed.has('d')) {
      final compact = utf8
          .decode(bytes, allowMalformed: true)
          .replaceAll(RegExp(r'\s+'), '');
      try {
        io.stdout.write(Uint8List.fromList(base64.decode(compact)));
      } on FormatException {
        io.stderr.writeText('base64: invalid input\n');
        return 1;
      }
      return 0;
    }

    final encoded = base64.encode(bytes);
    if (encoded.isEmpty) return 0;
    if (wrap == 0) {
      io.stdout.writeText('$encoded\n');
      return 0;
    }
    final buffer = StringBuffer();
    for (var start = 0; start < encoded.length; start += wrap) {
      final end = start + wrap < encoded.length ? start + wrap : encoded.length;
      buffer.write('${sliceText(encoded, start, end)}\n');
    }
    io.stdout.writeText(buffer.toString());
    return 0;
  }
}

/// `md5sum FILE...` и `sha256sum FILE...`: строка `хэш  имя` на каждый файл. Без операндов и для `-`
/// читается stdin, и в выводе он назван `-`, как у GNU. Ошибка чтения — код 1, остальные файлы обрабатываются.
final class _Digest implements Applet {
  const _Digest(this.name, this._digest);

  @override
  final String name;

  final Digest Function(List<int>) _digest;

  @override
  Future<int> run(AppletIo io, List<String> args) async {
    final parsed = parseArgs(args);
    if (parsed.error != null) return usageError(io, name, parsed.error!);
    var status = 0;
    for (final operand
        in parsed.operands.isEmpty ? const ['-'] : parsed.operands) {
      final bytes = await readSource(io, name, operand);
      if (bytes == null) {
        status = 1;
        continue;
      }
      io.stdout.writeText('${_digest(bytes)}  $operand\n');
    }
    return status;
  }
}
