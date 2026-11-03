import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:probably_works/agent/domain/chat_models.dart';

/// Причина, по которой файл не добавлен в сообщение.
enum AttachmentProblem { tooLarge, unreadable, unsupportedType }

/// Результат чтения файла: либо вложение, либо причина отказа.
final class AttachmentLoadResult {
  const AttachmentLoadResult.ok(AttachmentRef this.ref) : problem = null;
  const AttachmentLoadResult.failed(AttachmentProblem this.problem)
    : ref = null;

  final AttachmentRef? ref;
  final AttachmentProblem? problem;
}

/// Бинарные форматы, которые понимают multimodal-модели (через input_modalities).
const binaryMimeTypes = {
  'pdf': 'application/pdf',
  'png': 'image/png',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'gif': 'image/gif',
  'webp': 'image/webp',
};

/// Читает файл с устройства для вложения. Путь в результате не сохраняется: модели уходит содержимое.
///
/// Тип определяется по расширению для бинарных форматов ([binaryMimeTypes]). Остальные файлы
/// принимаются как текст, если они декодируются как UTF-8 без NUL-байтов. Всё остальное отклоняется.
///
/// [removeAfterReadUnder]: если файл лежит внутри этого каталога (кэш системного пикера
/// на мобильных), он удаляется после чтения. Файлы пользователя вне каталога не трогаются.
Future<AttachmentLoadResult> loadAttachment(
  String path, {
  required int maxBytes,
  String? removeAfterReadUnder,
}) async {
  final file = File(path);
  final name = path.split(RegExp(r'[\\/]')).last;
  try {
    final size = await file.length();
    if (size > maxBytes) {
      return const AttachmentLoadResult.failed(AttachmentProblem.tooLarge);
    }
    return _classify(name, await file.readAsBytes());
  } on FileSystemException {
    return const AttachmentLoadResult.failed(AttachmentProblem.unreadable);
  } finally {
    if (removeAfterReadUnder != null && path.startsWith(removeAfterReadUnder)) {
      await _tryDelete(file);
    }
  }
}

AttachmentLoadResult _classify(String name, Uint8List bytes) {
  final parts = name.split('.');
  final extension = parts.length < 2 ? '' : parts.last.toLowerCase();
  final mime = binaryMimeTypes[extension];
  if (mime != null) {
    return AttachmentLoadResult.ok(
      AttachmentRef(
        name: name,
        mode: AttachmentMode.file,
        mimeType: mime,
        sizeBytes: bytes.length,
        bytes: bytes,
      ),
    );
  }
  final text = _decodeText(bytes);
  if (text == null) {
    return const AttachmentLoadResult.failed(AttachmentProblem.unsupportedType);
  }
  return AttachmentLoadResult.ok(
    AttachmentRef(
      name: name,
      mode: AttachmentMode.attach,
      content: text,
      sizeBytes: bytes.length,
    ),
  );
}

String? _decodeText(Uint8List bytes) {
  if (bytes.contains(0)) return null;
  try {
    return utf8.decode(bytes);
  } on FormatException {
    return null;
  }
}

Future<void> _tryDelete(File file) async {
  try {
    await file.delete();
  } on FileSystemException {
    // Кэш системы очистит сам; ошибка удаления не мешает отправке.
  }
}
