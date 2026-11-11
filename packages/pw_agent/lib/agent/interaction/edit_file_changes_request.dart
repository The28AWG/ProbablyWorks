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

/// Запрос: агент менял файлы в удаляемой или переписываемой части истории.
final class EditFileChangesRequest {
  const EditFileChangesRequest({
    required this.id,
    required this.chatId,
    required this.files,
    required this.shellMayHaveChangedFiles,
  });

  final String id;
  final String chatId;
  final List<EditFileChangesEntry> files;

  /// Был ли хотя бы один [run_command], который мог менять ФС вне списка.
  final bool shellMayHaveChangedFiles;
}
