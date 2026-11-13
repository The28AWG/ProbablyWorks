import 'package:pw_agent/agent/attachments/attachment_loader_base.dart';

export 'package:pw_agent/agent/attachments/attachment_loader_base.dart';

/// Web не читает файлы по пути ОС: браузер даёт байты, а не путь.
/// Используйте [classifyAttachmentBytes] после `XFile.readAsBytes`.
Future<AttachmentLoadResult> loadAttachment(
  String path, {
  required int maxBytes,
  String? removeAfterReadUnder,
}) async {
  // Параметры читаются, чтобы сигнатура совпадала с native-версией.
  if (path.isEmpty || maxBytes <= 0 || removeAfterReadUnder != null) {
    return const AttachmentLoadResult.failed(AttachmentProblem.unreadable);
  }
  return const AttachmentLoadResult.failed(AttachmentProblem.unreadable);
}
