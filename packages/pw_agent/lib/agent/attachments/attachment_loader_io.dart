import 'dart:io';

import 'package:pw_agent/agent/attachments/attachment_loader_base.dart';

export 'package:pw_agent/agent/attachments/attachment_loader_base.dart';

/// Читает файл с устройства для вложения. Путь в результате не сохраняется: модели уходит содержимое.
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
    return classifyAttachmentBytes(name, await file.readAsBytes());
  } on FileSystemException {
    return const AttachmentLoadResult.failed(AttachmentProblem.unreadable);
  } finally {
    if (removeAfterReadUnder != null && path.startsWith(removeAfterReadUnder)) {
      await _tryDelete(file);
    }
  }
}

Future<void> _tryDelete(File file) async {
  try {
    await file.delete();
  } on FileSystemException {
    // Кэш системы очистит сам; ошибка удаления не мешает отправке.
  }
}
