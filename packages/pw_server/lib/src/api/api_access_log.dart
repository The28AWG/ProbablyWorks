import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:pw_agent/core/logging/app_log.dart';
import 'package:pw_agent/core/security/file_permissions.dart';

/// Журнал доступа к HTTP API.
///
/// Пишет только метаданные запроса: метод, путь без query, статус, время,
/// адрес клиента, результат авторизации и fingerprint токена. Тела запросов,
/// заголовки и query сюда не попадают.
final class ApiAccessLog {
  ApiAccessLog(
    Directory directory, {
    this.maxBytes = 5 * 1024 * 1024,
    this.keepFiles = 5,
  }) : _file = File(p.join(directory.path, _fileName));

  static const _fileName = 'api-access.log';
  static var _reportedFailure = false;

  final File _file;
  final int maxBytes;
  final int keepFiles;

  /// Короткий fingerprint токена: его достаточно, чтобы отличить клиентов,
  /// но невозможно восстановить сам токен.
  static String fingerprint(String token) {
    final digest = sha256.convert(utf8.encode(token)).toString();
    return String.fromCharCodes(digest.codeUnits.take(8));
  }

  /// Добавляет одну JSONL-запись. Ошибка записи не должна ломать API.
  void write(Map<String, Object?> entry) {
    try {
      final directory = _file.parent;
      if (!directory.existsSync()) {
        directory.createSync(recursive: true);
        FilePermissions.directory(directory);
      }
      _rotateIfNeeded();
      if (!_file.existsSync()) {
        _file.createSync(recursive: true);
        FilePermissions.file(_file);
      }
      _file.writeAsStringSync(
        '${jsonEncode(entry)}\n',
        mode: FileMode.append,
        flush: true,
      );
    } on Object catch (error) {
      if (_reportedFailure) return;
      _reportedFailure = true;
      AppLog.root.warning('cannot write API access log', error);
    }
  }

  void _rotateIfNeeded() {
    if (!_file.existsSync() || _file.lengthSync() < maxBytes) return;
    for (var i = keepFiles - 1; i >= 1; i--) {
      final from = File('${_file.path}.$i');
      if (from.existsSync()) from.renameSync('${_file.path}.${i + 1}');
    }
    _file.renameSync('${_file.path}.1');
  }
}
