/// Сводка данных профиля, которой управляет экран «Данные».
final class DataUsage {
  const DataUsage({
    required this.chats,
    required this.subagentChats,
    required this.messages,
    required this.toolRuns,
    required this.scheduledTasks,
    required this.completedTasks,
    required this.failedTasks,
    required this.cancelledTasks,
    required this.chatFilesBytes,
    required this.databaseBytes,
  });

  /// Восстанавливает сводку из JSON HTTP API. Отсутствующие числа — ноль.
  factory DataUsage.fromJson(Map<String, dynamic> json) => DataUsage(
    chats: _int(json['chats']),
    subagentChats: _int(json['subagentChats']),
    messages: _int(json['messages']),
    toolRuns: _int(json['toolRuns']),
    scheduledTasks: _int(json['scheduledTasks']),
    completedTasks: _int(json['completedTasks']),
    failedTasks: _int(json['failedTasks']),
    cancelledTasks: _int(json['cancelledTasks']),
    chatFilesBytes: _int(json['chatFilesBytes']),
    databaseBytes: _int(json['databaseBytes']),
  );

  /// Обычные чаты, которые видны пользователю.
  final int chats;

  /// Скрытые чаты субагентов. Удаляются вместе с родителем.
  final int subagentChats;
  final int messages;
  final int toolRuns;

  /// Запланированные, но ещё не отправленные задачи (`pending`).
  final int scheduledTasks;

  /// Задачи, чьё сообщение уже передано сессии (`dispatched`).
  final int completedTasks;

  /// Задачи, которые не удалось отправить.
  final int failedTasks;

  /// Задачи, отменённые пользователем.
  final int cancelledTasks;

  /// Логи запусков и снимки файлов в каталоге чатов.
  final int chatFilesBytes;

  /// Файл SQLite и его журналы. Это не только история: в базе лежат настройки и хосты.
  final int databaseBytes;

  Map<String, Object?> toJson() => {
    'chats': chats,
    'subagentChats': subagentChats,
    'messages': messages,
    'toolRuns': toolRuns,
    'scheduledTasks': scheduledTasks,
    'completedTasks': completedTasks,
    'failedTasks': failedTasks,
    'cancelledTasks': cancelledTasks,
    'chatFilesBytes': chatFilesBytes,
    'databaseBytes': databaseBytes,
  };
}

/// Результат очистки истории.
final class HistoryClearResult {
  const HistoryClearResult({
    required this.deletedChats,
    required this.freedBytes,
    this.compacted = true,
    this.deletedChatIds = const [],
  });

  /// Восстанавливает результат из JSON HTTP API.
  factory HistoryClearResult.fromJson(Map<String, dynamic> json) =>
      HistoryClearResult(
        deletedChats: _int(json['deletedChats']),
        freedBytes: _int(json['freedBytes']),
        compacted: json['compacted'] != false,
        deletedChatIds: [
          for (final id in json['deletedChatIds'] as List? ?? const [])
            if (id is String) id,
        ],
      );

  /// Все удалённые чаты, включая скрытых субагентов.
  final int deletedChats;

  /// Идентификаторы удалённых чатов. Нужны, чтобы клиенты с открытым экраном
  /// получили `chatDeleted` даже при каскадной очистке истории.
  final List<String> deletedChatIds;

  /// Всего освобождено: файлы чатов, логи запусков и сжатие базы.
  final int freedBytes;

  /// Удалось ли выполнить `VACUUM` после очистки. false — история удалена,
  /// но файл базы остался больше, чем мог бы быть.
  final bool compacted;

  Map<String, Object?> toJson() => {
    'deletedChats': deletedChats,
    'freedBytes': freedBytes,
    'compacted': compacted,
    'deletedChatIds': deletedChatIds,
  };
}

/// Управление историей и настройками профиля.
///
/// Локальная реализация чистит базу и файлы приложения напрямую, удалённая
/// вызывает HTTP API профиля. Секреты не входят ни в очистку, ни в сброс:
/// ключи, пароли и токены остаются в защищённом хранилище.
abstract interface class DataApi {
  /// Текущий объём истории и базы. Считается по запросу: цифры нужны перед
  /// необратимой очисткой, а не в каждом кадре интерфейса.
  Future<DataUsage> usage();

  /// Удаляет историю чатов вместе с сообщениями, запусками, запланированными
  /// задачами, логами и снимками файлов.
  ///
  /// [olderThanDays] ограничивает выбор чатами, которые не обновлялись
  /// дольше указанного срока. Null — удалить все основные чаты. Скрытые чаты
  /// субагентов удаляются вместе с родителем. Хосты, настройки, проекты и их
  /// память остаются; опустевшие проекты уходят в архив по обычным правилам.
  Future<HistoryClearResult> clearHistory({int? olderThanDays});

  /// Возвращает предпочтения агента к значениям по умолчанию.
  ///
  /// Меняются модели, политика, лимиты, denylist, шаги журнала, адреса и
  /// включённость провайдеров. Хосты, чаты, MCP-серверы, профили политики,
  /// проекты, локальные модели и секреты не трогаются.
  Future<void> resetSettings();
}

int _int(Object? value) => value is num ? value.toInt() : 0;
