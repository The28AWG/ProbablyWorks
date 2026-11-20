import 'package:pw_agent/agent/turn/turn_file_kind.dart';

/// Решение при правке или укорочении истории, если агент менял файлы.
enum EditFileChangesChoice {
  /// Откатить учтённые изменения на Host и продолжить.
  rollbackAndContinue,

  /// Продолжить без отката; снимки больше не предлагаются.
  continueWithoutRollback,

  /// Отменить правку или удаление хвоста.
  cancel,
}

/// Один путь в сводке для диалога (агрегат по нескольким ответам агента).
final class EditFileChangesEntry {
  const EditFileChangesEntry({required this.path, required this.kind});

  final String path;
  final TurnFileKind kind;
}

/// Запрос: в удаляемой или переписываемой части истории есть изменения файлов
/// и/или поставленные напоминания, которые исчезнут вместе с сообщениями.
final class EditFileChangesRequest {
  const EditFileChangesRequest({
    required this.id,
    required this.chatId,
    required this.files,
    required this.shellMayHaveChangedFiles,
    this.scheduledTasks = 0,
  });

  final String id;
  final String chatId;
  final List<EditFileChangesEntry> files;

  /// Был ли хотя бы один [run_command], который мог менять ФС вне списка.
  final bool shellMayHaveChangedFiles;

  /// Сколько несработавших отложенных задач будет удалено вместе с сообщениями.
  ///
  /// Файлов может не быть вовсе: тогда запрос существует только ради задач,
  /// и восстанавливать нечего.
  final int scheduledTasks;
}
