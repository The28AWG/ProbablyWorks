import 'dart:convert';
import 'dart:typed_data';

import 'package:pw_agent/agent/domain/chat_models.dart';

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
  'mp3': 'audio/mpeg',
  'wav': 'audio/wav',
  'flac': 'audio/flac',
  'ogg': 'audio/ogg',
  'm4a': 'audio/mp4',
  'mp4': 'video/mp4',
  'webm': 'video/webm',
  'mov': 'video/quicktime',
};

/// Классифицирует уже прочитанные байты файла. Не трогает файловую систему.
AttachmentLoadResult classifyAttachmentBytes(String name, Uint8List bytes) {
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
