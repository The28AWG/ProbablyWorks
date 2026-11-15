/// Платформенный загрузчик локальных моделей для Android и iOS.
///
/// Использует `background_downloader`: на iOS — background `URLSession`, на
/// Android — WorkManager/UIDT. Задача переживает сворачивание и завершение
/// приложения, а прогресс и уведомление рисует ОС. Токен Hugging Face уходит
/// в заголовки задачи; после завершения запись задачи удаляется, чтобы он не
/// оставался в базе загрузчика.
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:background_downloader/background_downloader.dart';
import 'package:crypto/crypto.dart';
import 'package:llamadart/llamadart.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pw_agent/core/error/app_failure.dart';
import 'package:pw_agent/core/security/secret_store.dart';
import 'package:pw_agent/core/util/cancel_token.dart';
import 'package:pw_agent/core/util/char_substring.dart';
import 'package:pw_agent/providers/ai/llamadart/local_storage.dart';

/// Группа задач загрузчика, чтобы не смешивать их с чужими.
const _downloadGroup = 'pw_models';

/// Хранилище моделей поверх платформенного загрузчика.
final class BackgroundLocalStorage implements LocalModelStorage {
  BackgroundLocalStorage({
    required this.modelsDirectory,
    required this.secrets,
  });

  /// Абсолютный каталог моделей (`AppPaths.models`).
  final String modelsDirectory;

  /// Токен Hugging Face читается в момент создания задачи.
  final SecretStore secrets;

  Future<void>? _ready;
  String? _relativeDirectory;

  @override
  Future<LocalModelStorageFile> ensure(
    String source, {
    String? key,
    String? displayName,
    String? sha256,
    void Function(int? received, int? total)? onProgress,
    CancelToken? cancel,
  }) async {
    final parsed = ModelSource.parse(source.trim());
    final id = key ?? charPrefix(parsed.cacheKey, 16);
    if (parsed.isLocal) return _localFile(parsed, id, sha256);
    await _ensureReady();

    final url = parsed.resolvedUri;
    if (url == null) {
      throw LlmFailure('Unsupported model source: $source');
    }
    final headers = <String, String>{};
    if (parsed.kind == ModelSourceKind.huggingFace) {
      final token = await secrets.read(huggingFaceTokenKey);
      if (token != null && token.isNotEmpty) {
        headers['Authorization'] = 'Bearer $token';
      }
    }
    final task = DownloadTask(
      taskId: id,
      url: url.toString(),
      filename: '$id.gguf',
      directory: _relativeDirectory ?? '',
      baseDirectory: BaseDirectory.applicationSupport,
      headers: headers,
      group: _downloadGroup,
      retries: 3,
      updates: Updates.statusAndProgress,
      displayName: displayName ?? parsed.fileName,
      transferHints: const {TransferHint.largeFile},
    );
    final transfer = await FileDownloader().transfers.getOrStart(task);
    final progress = FileDownloader().updates.listen((update) {
      if (update is! TaskProgressUpdate) return;
      if (update.task.taskId != id) return;
      final total = update.hasExpectedFileSize ? update.expectedFileSize : null;
      final received = total == null ? null : (update.progress * total).round();
      onProgress?.call(received, total);
    });
    if (cancel != null) unawaited(_forwardCancel(cancel, transfer));
    try {
      final file = await transfer.file;
      await _verify(file, sha256);
      final stat = file.statSync();
      return LocalModelStorageFile(
        cacheKey: id,
        path: file.path,
        sizeBytes: stat.size,
        sha256: sha256,
      );
    } on Object catch (error, stack) {
      Error.throwWithStackTrace(_failureOf(error, cancel), stack);
    } finally {
      await progress.cancel();
      // Удаляем запись задачи: заодно из её JSON уходят заголовки с токеном.
      await _deleteRecord(id);
    }
  }

  @override
  Future<List<LocalModelStorageFile>> list() async {
    final directory = Directory(modelsDirectory);
    if (!directory.existsSync()) return const [];
    final files = <LocalModelStorageFile>[];
    await for (final entity in directory.list()) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (!name.endsWith('.gguf')) continue;
      final id = p.basenameWithoutExtension(name);
      if (id.endsWith('-projector')) continue;
      final stat = entity.statSync();
      files.add(
        LocalModelStorageFile(
          cacheKey: id,
          path: entity.path,
          sizeBytes: stat.size,
        ),
      );
    }
    return files;
  }

  @override
  Future<void> remove(String cacheKey) async {
    await _cancel(cacheKey);
    for (final name in ['$cacheKey.gguf', '$cacheKey-projector.gguf']) {
      final file = File(p.join(modelsDirectory, name));
      if (file.existsSync()) file.deleteSync();
    }
    await _deleteRecord(cacheKey);
    await _deleteRecord('$cacheKey-projector');
  }

  @override
  Future<void> clear() async {
    await FileDownloader().cancelAll(group: _downloadGroup);
    final directory = Directory(modelsDirectory);
    if (directory.existsSync()) {
      for (final entity in directory.listSync()) {
        if (entity is! File) continue;
        final name = p.basename(entity.path);
        if (name.endsWith('.gguf') || name.endsWith('.part')) {
          entity.deleteSync();
        }
      }
    }
    for (final record in await FileDownloader().database.allRecords(
      group: _downloadGroup,
    )) {
      await _deleteRecord(record.taskId);
    }
  }

  /// Поднимает базу задач и просит разрешение на уведомления один раз.
  Future<void> _ensureReady() => _ready ??= () async {
    await FileDownloader().start(autoCleanDatabase: true);
    try {
      await FileDownloader().permissions.request(PermissionType.notifications);
    } on Object {
      // Разрешение не выдали: загрузка идёт, уведомления могут быть скрыты.
    }
    final support = await getApplicationSupportDirectory();
    _relativeDirectory = p.relative(modelsDirectory, from: support.path);
  }();

  Future<LocalModelStorageFile> _localFile(
    ModelSource parsed,
    String id,
    String? sha256,
  ) async {
    final path = parsed.path;
    if (path == null) throw const LlmFailure('Local model path is missing');
    final file = File(path);
    if (!file.existsSync()) {
      throw LlmFailure('Model file not found: $path');
    }
    await _verify(file, sha256);
    final stat = file.statSync();
    return LocalModelStorageFile(
      cacheKey: id,
      path: file.path,
      sizeBytes: stat.size,
      sha256: sha256,
    );
  }

  Future<void> _cancel(String taskId) async {
    try {
      await FileDownloader().cancelTaskWithId(taskId);
    } on Object {
      // Задачи уже нет — не ошибка.
    }
  }

  Future<void> _deleteRecord(String taskId) async {
    try {
      await FileDownloader().database.deleteRecordWithId(taskId);
    } on Object {
      // Записи нет — не ошибка.
    }
  }

  Future<void> _verify(File file, String? sha256) async {
    if (sha256 == null || sha256.isEmpty) return;
    final digest = await Isolate.run(() => _digestOf(file.path));
    if (digest != sha256.toLowerCase()) {
      if (file.existsSync()) file.deleteSync();
      throw const LlmFailure('Downloaded model failed the SHA-256 check');
    }
  }

  static Future<void> _forwardCancel(
    CancelToken cancel,
    Transfer transfer,
  ) async {
    await cancel.whenCancelled;
    await transfer.cancel();
  }

  static LlmFailure _failureOf(Object error, CancelToken? cancel) {
    if (error is LlmFailure) return error;
    if (cancel?.isCancelled ?? false) {
      return const LlmFailure('Download cancelled', retryable: true);
    }
    return LlmFailure('Model download failed: $error', retryable: true);
  }
}

/// SHA-256 файла. Запускается в отдельном изоляте: модели большие.
Future<String> _digestOf(String path) async {
  final digest = await sha256.bind(File(path).openRead()).first;
  return digest.toString();
}
