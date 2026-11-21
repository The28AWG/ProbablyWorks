import 'dart:io';
import 'dart:math' as math;

import 'package:injectable/injectable.dart';
import 'package:path/path.dart' as p;
import 'package:pw_agent/agent/api/data_api.dart';
import 'package:pw_agent/agent/cleanup/chat_deletion_service.dart';
import 'package:pw_agent/agent/domain/chat_models.dart';
import 'package:pw_agent/agent/schedule/scheduled_task.dart';
import 'package:pw_agent/core/config/app_paths.dart';
import 'package:pw_agent/core/data/chat_repository.dart';
import 'package:pw_agent/core/data/settings_repository.dart';
import 'package:pw_agent/core/db/app_database.dart';
import 'package:pw_agent/core/logging/app_log.dart';
import 'package:pw_agent/providers/ai/llm_provider_registry.dart';
import 'package:pw_agent/providers/ai/model_catalog.dart';
import 'package:pw_agent/providers/ai/model_runtime_service.dart';

/// Локальное управление историей и настройками профиля.
///
/// Считает строки прямо в SQLite, а файлы — в каталоге чатов. Очистка идёт
/// через [ChatDeletionService], поэтому удаление из списка чатов и массовая
/// очистка убирают одно и то же.
@LazySingleton(as: DataApi)
final class LocalDataApi implements DataApi {
  LocalDataApi(
    this._db,
    this._paths,
    this._settings,
    this._chats,
    this._deletion,
    this._catalog,
    this._runtime,
    this._registry,
  );

  final AppDatabase _db;
  final AppPaths _paths;
  final SettingsRepository _settings;
  final ChatRepository _chats;
  final ChatDeletionService _deletion;
  final ModelCatalogService _catalog;
  final ModelRuntimeService _runtime;
  final LlmProviderRegistry _registry;

  @override
  Future<DataUsage> usage() async {
    final all = await _chats.allChats();
    final chats = all.where((chat) => !chat.isSubagent).length;
    final tasks = await _taskCounts();
    return DataUsage(
      chats: chats,
      subagentChats: all.length - chats,
      messages: await _countRows('messages'),
      toolRuns: await _countRows('tool_runs'),
      scheduledTasks: tasks[ScheduledTaskStatus.pending.name] ?? 0,
      completedTasks: tasks[ScheduledTaskStatus.dispatched.name] ?? 0,
      failedTasks: tasks[ScheduledTaskStatus.failed.name] ?? 0,
      cancelledTasks: tasks[ScheduledTaskStatus.cancelled.name] ?? 0,
      chatFilesBytes: await _chatFilesBytes(),
      databaseBytes: await _databaseBytes(),
    );
  }

  /// Задачи по статусам. Нужны отдельно, чтобы карточка не смешивала
  /// запланированные и уже отправленные.
  Future<Map<String, int>> _taskCounts() async {
    final rows = await _db
        .customSelect(
          'SELECT status, COUNT(*) AS count FROM scheduled_tasks GROUP BY status',
        )
        .get();
    return {
      for (final row in rows)
        row.read<String>('status'): row.read<int>('count'),
    };
  }

  @override
  Future<HistoryClearResult> clearHistory({int? olderThanDays}) async {
    if (olderThanDays != null && olderThanDays <= 0) {
      throw ArgumentError.value(
        olderThanDays,
        'olderThanDays',
        'must be positive',
      );
    }
    final beforeFiles = await _chatFilesBytes();
    final beforeDatabase = await _databaseBytes();
    final all = await _chats.allChats();
    final byId = {for (final chat in all) chat.id: chat};
    final cutoff = olderThanDays == null
        ? null
        : DateTime.now().subtract(Duration(days: olderThanDays));
    final roots = <String>[];
    for (final chat in all) {
      final parentId = chat.parentChatId;
      // Обычный чат или скрытый субагент без родителя. Субагенты с живым
      // родителем уходят вместе с его деревом.
      final orphanSubagent =
          chat.isSubagent && (parentId == null || !byId.containsKey(parentId));
      if (chat.isSubagent && !orphanSubagent) continue;
      if (cutoff != null && !chat.updatedAt.isBefore(cutoff)) continue;
      roots.add(chat.id);
    }
    if (roots.isEmpty) {
      return HistoryClearResult(
        deletedChats: 0,
        freedBytes: math.max(0, beforeFiles - await _chatFilesBytes()),
      );
    }

    // Снимок мог устареть. Читаем текущее дерево один раз: корни берём из
    // снимка, поэтому новый обычный чат под очистку не попадёт, а новые
    // субагенты удаляемого корня и их файлы будут учтены.
    final current = await _chats.allChats();
    final currentById = {for (final chat in current) chat.id: chat};
    final children = <String, List<Chat>>{};
    for (final chat in current) {
      final parentId = chat.parentChatId;
      if (parentId != null) {
        children.putIfAbsent(parentId, () => []).add(chat);
      }
    }
    final seen = <String>{};
    final targets = <Chat>[];
    void visit(Chat chat) {
      if (!seen.add(chat.id)) return;
      targets.add(chat);
      for (final child in children[chat.id] ?? const <Chat>[]) {
        visit(child);
      }
    }

    for (final rootId in roots) {
      final root = currentById[rootId];
      if (root != null) visit(root);
    }
    targets.sort((a, b) => b.depth.compareTo(a.depth));
    await _deletion.deleteTree(targets);
    final compacted = targets.isEmpty || await _vacuumDatabase();
    final afterFiles = await _chatFilesBytes();
    final afterDatabase = await _databaseBytes();
    return HistoryClearResult(
      deletedChats: targets.length,
      freedBytes:
          math.max(0, beforeFiles - afterFiles) +
          math.max(0, beforeDatabase - afterDatabase),
      compacted: compacted,
    );
  }

  /// Возвращает файлу базы место, занятое удалёнными строками.
  ///
  /// SQLite после `DELETE` оставляет страницы в freelist: файл не уменьшается,
  /// пока не выполнить `VACUUM`. Ошибку не пробрасываем — история уже удалена,
  /// и неудачное сжатие не должно выглядеть как провал очистки. Но наружу
  /// возвращаем false, чтобы интерфейс предупредил: место в базе не вернулось.
  Future<bool> _vacuumDatabase() async {
    try {
      await _db.customStatement('VACUUM');
    } on Object catch (error, stack) {
      AppLog.root.warning(
        'database vacuum after history cleanup failed',
        error,
        stack,
      );
      return false;
    }
    try {
      // В WAL-режиме журнал может остаться большим после перестройки базы.
      await _db.customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
    } on Object catch (error, stack) {
      AppLog.root.warning('WAL checkpoint after cleanup failed', error, stack);
    }
    return true;
  }

  @override
  Future<void> resetSettings() async {
    await _settings.resetPreferences();
    // Статусы провайдеров читаются без сети; runtime перезапускается, чтобы
    // выключенный и включённый провайдер сразу дали новое состояние.
    await _catalog.loadProviderConfigs();
    for (final provider in _registry.providers) {
      await _runtime.restartProvider(provider.id);
    }
  }

  Future<int> _countRows(String table) async {
    final row = await _db
        .customSelect('SELECT COUNT(*) AS count FROM $table')
        .getSingle();
    return row.read<int>('count');
  }

  Future<int> _chatFilesBytes() =>
      _directoryBytes(Directory(p.join(_paths.root.path, 'chats')));

  Future<int> _directoryBytes(Directory directory) async {
    if (!directory.existsSync()) return 0;
    var total = 0;
    try {
      await for (final entity in directory.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is File) total += await entity.length();
      }
    } on FileSystemException {
      // Каталог мог исчезнуть между проверкой и обходом: это не мешает очистке.
      return total;
    }
    return total;
  }

  /// Размер базы с журналом WAL: без него карточка показывала бы не всё место.
  Future<int> _databaseBytes() async {
    final db = _paths.database;
    return await _fileBytes(db) +
        await _fileBytes(File('${db.path}-wal')) +
        await _fileBytes(File('${db.path}-journal'));
  }

  Future<int> _fileBytes(File file) async {
    try {
      return file.existsSync() ? file.lengthSync() : 0;
    } on FileSystemException {
      // WAL или journal могли исчезнуть между проверкой и чтением.
      return 0;
    }
  }
}
