/// Файловое хранилище среды выполнения поверх кэша llamadart.
///
/// Среда не работает с сетью и файлами напрямую: она просит [LocalModelStorage]
/// скачать источник, перечислить кэш или удалить запись. Тесты подставляют
/// фейк и не трогают ни диск, ни нативные рантаймы.
library;

import 'dart:async';

import 'package:llamadart/llamadart.dart';
import 'package:pw_agent/core/error/app_failure.dart';
import 'package:pw_agent/core/security/secret_store.dart';
import 'package:pw_agent/core/util/cancel_token.dart';

/// Файл, которым управляет кэш среды выполнения.
class LocalModelStorageFile {
  const LocalModelStorageFile({
    required this.cacheKey,
    required this.path,
    this.sizeBytes,
    this.sha256,
  });

  /// Ключ кэша: по нему файл удаляют и находят после перезапуска.
  final String cacheKey;
  final String path;
  final int? sizeBytes;
  final String? sha256;
}

/// Скачивание, инвентарь и удаление файлов моделей.
abstract interface class LocalModelStorage {
  /// Скачивает источник (или проверяет локальный путь) и возвращает файл.
  ///
  /// [key] — стабильный id задания: платформенный загрузчик использует его как
  /// `taskId`, чтобы подхватить задачу после перезапуска. [displayName] идёт в
  /// уведомление. [sha256] проверяется, если задан. [onProgress] получает
  /// байты; null означает «неизвестно». [cancel] останавливает скачивание.
  Future<LocalModelStorageFile> ensure(
    String source, {
    String? key,
    String? displayName,
    String? sha256,
    void Function(int? received, int? total)? onProgress,
    CancelToken? cancel,
  });

  /// Все файлы в кэше.
  Future<List<LocalModelStorageFile>> list();

  /// Удаляет файл по ключу кэша.
  Future<void> remove(String cacheKey);

  /// Удаляет все файлы кэша.
  Future<void> clear();
}

/// Реализация поверх `DefaultModelDownloadManager` из llamadart.
final class LlamadartLocalStorage implements LocalModelStorage {
  LlamadartLocalStorage({required String cacheDirectory, this.secrets})
    : _manager = DefaultModelDownloadManager(
        defaultCacheDirectory: cacheDirectory,
      );

  final DefaultModelDownloadManager _manager;

  /// Нужен для закрытых репозиториев Hugging Face. Токен не попадает в логи.
  final SecretStore? secrets;

  @override
  Future<LocalModelStorageFile> ensure(
    String source, {
    String? key,
    String? displayName,
    String? sha256,
    void Function(int? received, int? total)? onProgress,
    CancelToken? cancel,
  }) async {
    final ModelSource parsed;
    try {
      parsed = ModelSource.parse(source.trim());
    } on Object catch (error, stack) {
      Error.throwWithStackTrace(
        LlmFailure('Invalid model source: $error'),
        stack,
      );
    }
    final token = ModelDownloadCancelToken();
    if (cancel != null) unawaited(_forwardCancel(cancel, token));
    final bearer = parsed.kind == ModelSourceKind.huggingFace
        ? await secrets?.read(huggingFaceTokenKey)
        : null;
    try {
      final entry = await _manager.ensureModel(
        parsed,
        options: ModelLoadOptions(
          sha256: sha256,
          bearerToken: bearer == null || bearer.isEmpty ? null : bearer,
          cancelToken: token,
        ),
        onProgress: onProgress == null
            ? null
            : (progress) =>
                  onProgress(progress.receivedBytes, progress.totalBytes),
      );
      return LocalModelStorageFile(
        cacheKey: entry.cacheKey,
        path: entry.filePath,
        sizeBytes: entry.bytes,
        sha256: entry.sha256,
      );
    } on Object catch (error, stack) {
      Error.throwWithStackTrace(_failureOf(error), stack);
    }
  }

  @override
  Future<List<LocalModelStorageFile>> list() async {
    try {
      final entries = await _manager.list();
      return [
        for (final entry in entries)
          LocalModelStorageFile(
            cacheKey: entry.cacheKey,
            path: entry.filePath,
            sizeBytes: entry.bytes,
            sha256: entry.sha256,
          ),
      ];
    } on Object catch (error, stack) {
      Error.throwWithStackTrace(_failureOf(error), stack);
    }
  }

  @override
  Future<void> remove(String cacheKey) async {
    try {
      await _manager.remove(cacheKey);
    } on Object catch (error, stack) {
      Error.throwWithStackTrace(_failureOf(error), stack);
    }
  }

  @override
  Future<void> clear() async {
    try {
      await _manager.clear();
    } on Object catch (error, stack) {
      Error.throwWithStackTrace(_failureOf(error), stack);
    }
  }

  /// Переносит отмену среды в токен загрузчика.
  static Future<void> _forwardCancel(
    CancelToken cancel,
    ModelDownloadCancelToken token,
  ) async {
    await cancel.whenCancelled;
    token.cancel();
  }

  /// Ошибка llamadart → понятная причина для интерфейса.
  static LlmFailure _failureOf(Object error) {
    if (error is LlmFailure) return error;
    if (error is ModelCacheEntryInUseException) {
      return const LlmFailure(
        'The model is in use. Unload it before deleting the file.',
      );
    }
    if (error is LlamaStateException && '$error'.contains('cancel')) {
      return const LlmFailure('Download cancelled', retryable: true);
    }
    return LlmFailure('Model download failed: $error', retryable: true);
  }
}
